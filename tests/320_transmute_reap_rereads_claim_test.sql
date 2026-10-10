-- _transmute_reap re-reads each claim under the table's lock, so a conversion taken over while the sweep
-- waited is left alone (issue #1166).
--
-- THE BUG. The reaper judged each claim by the row its FOR cursor read when the sweep began, and never
-- looked at it again. Its lock wait on one abandoned table (up to its 5 s lock_timeout, #657) is a window
-- in which an operator re-runs transmute on another abandoned table: the documented resume, which takes
-- the dead claim over (ON CONFLICT records the live session as its owner) and goes on into phase 2. The
-- sweep then reached that table with the stale, dead owner, waited for ACCESS EXCLUSIVE behind the live
-- conversion, and when it got it dropped the live conversion's validated bound and deleted its claim,
-- logged as transmute_reap: the cutover failed ("constraint pgpm_monolith_bound ... does not exist") and
-- the table was left plain. The fix takes the table's lock first and re-reads the claim FOR UPDATE under
-- it, and a claim that is gone or whose owner is alive by then is left as it is, with the lock released at
-- once rather than held to the end of the sweep's transaction.
--
-- ORDERING BY HELD LOCKS ONLY. A reader holds ACCESS SHARE on rr320a (the reaper's pause on the first
-- claim) and a gate holds SHARE UPDATE EXCLUSIVE on rr320t (the take-over's phase-2 wait). Nothing below
-- waits for a timeout: the reader commits once the take-over is parked, which sends the reaper on to t.
--
-- ASYMMETRIC FIXTURE. Three claims, all with a dead owner when the sweep starts, in the order the sweep
-- reads them: a (30 rows), t (60 rows), c (20 rows). Exactly a and c are reaped; t is taken over during
-- the sweep and must come out converted, with all 60 rows. A reaper that never re-reads reaps all three;
-- one that stops at t reaps only a; each is a different set of names.
--
-- The sweep runs inside an open transaction in its own session, as maintain_all runs it (the commit after
-- _detach_reap), so the take-over's cutover completing BEFORE that transaction ends is what shows the
-- lock the re-read took on t was given back, and not held until the sweep commits.
create extension if not exists pgtap;
create extension if not exists dblink;
set timezone = 'UTC';

select plan(16);

create schema pgpm_test320;
-- Poll until p_pid waits for a relation lock on p_rel (pg_locks is live), or until p_pid has gone. Each
-- turn clears the pg_stat_activity snapshot, which a function otherwise reads once (#713).
create function pgpm_test320.waits_on(p_pid int, p_rel regclass)
returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    if exists (select 1 from pg_locks where pid = p_pid and locktype = 'relation'
                                        and relation = p_rel and not granted) then
      return true;
    end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;
create function pgpm_test320.gone(p_pid int)
returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if not exists (select 1 from pg_stat_activity where pid = p_pid) then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

create table public.rr320a (id bigint not null, ts timestamptz not null, primary key (id, ts));
create table public.rr320t (id bigint not null, ts timestamptz not null, primary key (id, ts));
create table public.rr320c (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.rr320a select i, now() - i * interval '1 minute' from generate_series(1, 30) i;
insert into public.rr320t select i, now() - i * interval '1 minute' from generate_series(1, 60) i;
insert into public.rr320c select i, now() - i * interval '1 minute' from generate_series(1, 20) i;
-- t's oid before the cutover, which renames it to the monolith and puts a partitioned table in its name
select 'public.rr320a'::regclass::oid as a_oid, 'public.rr320t'::regclass::oid as t_oid,
       'public.rr320c'::regclass::oid as c_oid \gset

-- A dead owner: a real session's identity, recorded, and then the session ended.
select dblink_connect('ghost', 'dbname=' || current_database());
select * from dblink('ghost', 'select pid, backend_start from pg_stat_activity where pid = pg_backend_pid()')
  as z(pid int, backend_start timestamptz) \gset ghost_
select dblink_disconnect('ghost');
select ok(pgpm_test320.gone(:ghost_pid), 'LIVENESS: the session recorded as the claims'' owner has ended');

-- Three conversions that died after phase 1: the claim (owner dead) and the NOT VALID bound, on a 1-day
-- grid in UTC, recorded a, t, c (the sweep's read order).
select pgpm._ts_text(date_trunc('day', now() at time zone 'UTC' - interval '2 hours') at time zone 'UTC') as lo,
       pgpm._ts_text((date_trunc('day', now() at time zone 'UTC') + interval '1 day') at time zone 'UTC') as hi \gset
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz, control_attnum,
                                     owner_pid, owner_backend_start)
select v.t::regclass, 'public', v.r, 'time', :'lo', :'hi', 'UTC', 2, :ghost_pid, :'ghost_backend_start'
  from (values (1, 'public.rr320a', 'rr320a'), (2, 'public.rr320t', 'rr320t'), (3, 'public.rr320c', 'rr320c')) v(o, t, r)
 order by v.o;
alter table public.rr320a add constraint pgpm_monolith_bound check (ts >= :'lo'::timestamptz and ts < :'hi'::timestamptz) not valid;
alter table public.rr320t add constraint pgpm_monolith_bound check (ts >= :'lo'::timestamptz and ts < :'hi'::timestamptz) not valid;
alter table public.rr320c add constraint pgpm_monolith_bound check (ts >= :'lo'::timestamptz and ts < :'hi'::timestamptz) not valid;
select is(
  (select string_agg(rel || ':' || (not pgpm._session_alive(owner_pid, owner_backend_start))::text, ',' order by rel)
     from pgpm.transmute_inflight),
  'rr320a:true,rr320c:true,rr320t:true',
  'LIVENESS: three claims, every owner dead, so the sweep reads each one as abandoned');

-- The locks that order everything below.
select dblink_connect('hold_a', 'dbname=' || current_database());
select dblink_exec('hold_a', 'begin');
select * from dblink('hold_a', 'select count(*) from public.rr320a') as z(n bigint);
select dblink_connect('gate_t', 'dbname=' || current_database());
select dblink_exec('gate_t', 'begin');
select dblink_exec('gate_t', 'lock table public.rr320t in share update exclusive mode');

select dblink_connect('reap', 'dbname=' || current_database());
select dblink_connect('conv', 'dbname=' || current_database());
select dblink_exec('conv', 'set timezone = ''UTC''');
select * from dblink('reap', 'select pg_backend_pid()') as z(pid int) \gset reap_
select * from dblink('conv', 'select pg_backend_pid()') as z(pid int) \gset conv_

-- The sweep: it reads all three claims and waits on a, behind the reader.
select dblink_exec('reap', 'begin');
select dblink_send_query('reap', 'select pgpm._transmute_reap()');
select ok(pgpm_test320.waits_on(:reap_pid, 'public.rr320a'),
  'LIVENESS: the sweep has read the claims and is waiting for its lock on a');

-- The operator re-runs transmute on t: it takes the dead claim over and parks in phase 2, behind the gate.
select dblink_send_query('conv', $$call pgpm.transmute('public.rr320t', 'ts', interval '1 day',
                                                         p_obtain => 2, p_lock_timeout => '10s')$$);
select ok(pgpm_test320.waits_on(:conv_pid, 'public.rr320t'),
  'LIVENESS: the re-run transmute is waiting on t, in phase 2');
select is(
  (select owner_pid from pgpm.transmute_inflight where parent_table = :t_oid::regclass), :conv_pid,
  'LIVENESS: and t''s claim is now that live session''s, taken over after the sweep read it as dead');

-- The reader goes: the sweep reaps a and reaches t with the row it read before the take-over.
select dblink_exec('hold_a', 'commit');
select ok(pgpm_test320.waits_on(:reap_pid, :t_oid::regclass),
  'LIVENESS: the sweep is queued for its lock on t while the live session owns t''s claim');

-- The gate goes: phase 2 validates and commits, the sweep gets its lock on t, the cutover follows.
select dblink_exec('gate_t', 'commit');
select is((select n from dblink_get_result('reap') as z(n int)), 2,
  'the sweep undid exactly two conversions');
select * from dblink_get_result('reap') as z(n int);
select is((select r from dblink_get_result('conv', false) as z(r text)), 'CALL',
  'the taken-over transmute of t completed while the sweep''s transaction was still open');
select * from dblink_get_result('conv', false) as z(r text);
select is((select state from pg_stat_activity where pid = :reap_pid), 'idle in transaction',
  'LIVENESS: the sweep''s transaction was still open when the cutover finished');
select dblink_exec('reap', 'commit');

select is(
  (select string_agg(case parent_table::oid when :a_oid then 'a' when :t_oid then 't' when :c_oid then 'c'
                                            else parent_table::text end, ',' order by id)
     from pgpm.log where action = 'transmute_reap'),
  'a,c', 'transmute_reap is logged for a and c, and not for t, whose claim a live session held');
select is((select relkind::text from pg_class where oid = 'public.rr320t'::regclass), 'p',
  't is now partitioned');
select is((select count(*)::int from pgpm.config where parent_table = 'public.rr320t'::regclass), 1,
  'and registered with pgpm');
select ok(
  (select string_agg(id::text, ',' order by id) from public.rr320t)
    = (select string_agg(g::text, ',' order by g) from generate_series(1, 60) g),
  'every one of t''s 60 rows is there through the new parent, by identity');
select is(
  (select string_agg(conrelid::regclass::text, ',' order by conrelid::regclass::text)
     from pg_constraint where conname = 'pgpm_monolith_bound' and conrelid in (:a_oid, :c_oid)),
  null, 'a and c have their bounds dropped');
select is((select relkind::text from pg_class where oid = :a_oid) || (select relkind::text from pg_class where oid = :c_oid),
  'rr', 'and are still the plain tables they were');
select is((select count(*)::int from pgpm.transmute_inflight), 0,
  'no claim is left: a and c reaped, t''s deleted by its own cutover');

select dblink_disconnect('hold_a');
select dblink_disconnect('gate_t');
select dblink_disconnect('reap');
select dblink_disconnect('conv');

select * from finish();
