-- The regrain swap waits for every snapshot that cannot see its copies, so a REPEATABLE READ reader whose snapshot
-- predates the copies never reads the regrained range empty (issue #1241).
--
-- THE BUG. regrain_step's swap detaches and drops the coarse source and attaches fine children whose rows were
-- written by copy transactions that committed after the reader's snapshot was taken. No snapshot can see rows
-- written after it, so a reader whose transaction spans the swap, and whose first touch of the table comes after
-- it (it held no lock, so nothing made the DETACH wait for it), read the fine children and found the range
-- empty: 1 row of 501 in the reproduction, with no error. docs/guide.md promised the opposite.
--
-- THE CONTRACT.
--   PART A  the issue's own path, auto-regrain through maintain(): with the reader open, the tick that reaches
--           the swap defers it, logged skip_regrain naming the reader by pid, and leaves the same source attached;
--           the reader reads exactly the rows it should; once it commits, the next tick swaps.
--   PART B  the hand driver, pgpm.regrain(), which copies in the swap's own transaction: it waits for a reader
--           whose transaction began before the call, under its caller's lock_timeout, and raises when the reader
--           outlasts it, the copies rolled back with it; once the reader commits it regrains.
--   PART C  the one exemption: a session waiting on a lock the regrain holds (a READ COMMITTED write queued behind
--           regrain()'s SHARE lock, #580) can never release its snapshot while the regrain waits for it, so the
--           wait passes it, naming it, and regrain() completes; the write lands in the fine children after.
--   PART D  the snapshots waited for are those older than the run's LAST write into its fine children, not its
--           first: a reader opened between the first copy and the last sees some copies and not the others, and
--           is waited for the same way.
--   PART E  the wait sees what any caller sees: maintain run by the table's non-superuser owner, without
--           pg_read_all_stats, against a reader in another role, whose backend_type and xact_start read NULL to the
--           owner. The reader is waited for exactly as in part A.
--   PART F  under regrain(), which copies in the swap's own transaction, a REPEATABLE READ reader that opened during
--           the call (before its copies committed) is waited for too, not only one older than the call, and stays
--           waited for when it starts its next statement during the wait (its snapshot is the same).
--   PART G  no exemption by state: under maintain, a reader in the middle of a statement when the budget runs out
--           defers the swap exactly as an idle one does; the swap never goes ahead under it.
--   PART H  the hand driver regrain() run by the table's non-superuser owner, without pg_read_all_stats, against a
--           reader in another role opened before the call, whose state and xact_start read NULL to the owner: the
--           reader is waited for as in part B.
--   PART I  the wait reads the sessions afresh on every poll: a REPEATABLE READ transaction that IMPORTS a snapshot
--           older than the copies (SET TRANSACTION SNAPSHOT of one another transaction exported) after the wait began
--           is waited for once the exporter has gone, and the hand regrain_step refuses rather than swap under it.
--   PART J  the same against the caller's own xid (regrain()), with a writer idle in its transaction since before the
--           exporter's snapshot: the importer's xmin EQUALS that writer's xid, the oldest still running, and it is
--           waited for all the same (at or before the newest snapshot open when the wait began).
--   PART K  the same for a run in flight across the upgrade that added config.regrain_written_xid (no recorded last
--           write, so the own-xid rule), driven by a hand regrain_step.
--
-- Every negative is paired with its premise: the copies ran, the reader's snapshot cannot see them (it does not
-- even see their log rows), the reader holds no lock on the table, and the run is at the swap (the cursor at hi).
-- regrain() is a function, not a committing procedure, so its refusals are pinned by message.
-- ASYMMETRIC FIXTURES. A holds 1..500 without the multiples of 7, B the multiples of 3 to 297, C the even ids to
-- 400, D the multiples of 5 to 495, E the multiples of 6 to 498, F the multiples of 4 to 400, G the multiples of 8
-- to 496, H the multiples of 9 to 495, I the multiples of 11 to 495, J the multiples of 12 to 492, K the multiples of
-- 13 to 494, each with its own frontier row, so an assertion aimed at the wrong table or
-- the wrong rows cannot pass; every row check names the ids.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(92);

-- ============================================ PART A ============================================
create table public.t328a (id bigint generated by default as identity primary key, payload text);
insert into public.t328a (id, payload) select g, 'a' || g from generate_series(1, 500) g where g % 7 <> 0;
call pgpm.transmute('public.t328a', 'id', 100, p_paused => false);                  -- monolith [0, 600)
insert into public.t328a (id, payload) values (2000, 'frontier');                    -- freezes the monolith
select pgpm.set_regrain('public.t328a', '100');
create temp table t328a_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328a'::regclass and p.attached and p.lo = '0';

-- the reader: REPEATABLE READ, its snapshot taken now, before any copy, and holding no lock on the table
select dblink_connect('r328a', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328a', 'begin isolation level repeatable read');
create temp table t328a_reader as
  select pid from dblink('r328a', 'select pg_backend_pid() from pgpm.config limit 1') as t(pid int);

do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328a', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328a'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;

select bag_eq(
  $$ select lo::bigint from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain_copy' $$,
  $$ values (0::bigint), (100), (200), (300), (400), (500) $$,
  'LIVENESS: the copies ran, one batch for each of the six sub-ranges of [0, 600)');
select is((select n from dblink('r328a', $q$select count(*) from pgpm.log where action = 'regrain_copy'$q$) as t(n bigint)),
  0::bigint, 'LIVENESS: the reader''s snapshot predates every copy (it cannot see even their log rows)');
select is((select count(*) from pg_locks l, t328a_reader r
            where l.pid = r.pid and l.locktype = 'relation'
              and l.relation in (select 'public.t328a'::regclass::oid
                                 union all select i.inhrelid from pg_inherits i where i.inhparent = 'public.t328a'::regclass
                                 union all select p.child_oid from pgpm.part p where p.parent_table = 'public.t328a'::regclass)),
  0::bigint, 'LIVENESS: the reader holds no lock on the table or any of its partitions, so no lock made the swap wait');
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328a'::regclass) = '600'
          or exists (select 1 from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain'),
  'LIVENESS: the run reached the swap (every sub-range copied and the cursor at hi, or the swap made)');
select is((select count(*) from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain'), 0::bigint,
  'the swap did not run while the reader was open');
select ok(exists (select 1 from pgpm.log l, t328a_reader r
                   where l.parent_table = 'public.t328a'::regclass and l.action = 'skip_regrain'
                     and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%'),
  'the tick deferred it, logged skip_regrain naming the reader by pid');
select is((select p.child_oid from pgpm.part p join t328a_src s using (child_name)
            where p.parent_table = 'public.t328a'::regclass and p.attached
              and exists (select 1 from pg_inherits i where i.inhparent = 'public.t328a'::regclass and i.inhrelid = p.child_oid)),
  (select child_oid from t328a_src),
  'the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('r328a', 'select id from public.t328a') as t(id bigint) $$,
  $$ select g::bigint from generate_series(1, 500) g where g % 7 <> 0 union all select 2000 $$,
  'the reader reads exactly the rows its snapshot holds: 1..500 without the multiples of 7, and 2000');
select dblink_exec('r328a', 'commit');

do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328a', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain'), 1::bigint,
  'once the reader committed, the next tick swapped');
select bag_eq(
  $$ select lo::bigint, hi::bigint from pgpm.part where parent_table = 'public.t328a'::regclass and attached and hi::bigint <= 600 $$,
  $$ values (0::bigint, 100::bigint), (100, 200), (200, 300), (300, 400), (400, 500), (500, 600) $$,
  'the six fine children are attached in the source''s place');
select ok(not exists (select 1 from pg_class c, t328a_src s where c.oid = s.child_oid), 'and the source is dropped');
select bag_eq(
  $$ select id from public.t328a $$,
  $$ select g::bigint from generate_series(1, 500) g where g % 7 <> 0 union all select 2000 $$,
  'a fresh read after the swap holds exactly the same rows');

-- ============================================ PART B ============================================
create table public.t328b (id bigint generated by default as identity primary key, payload text);
insert into public.t328b (id, payload) select g, 'b' || g from generate_series(3, 297, 3) g;
call pgpm.transmute('public.t328b', 'id', 100, p_paused => false);                  -- monolith [0, 300)
insert into public.t328b (id, payload) values (1500, 'frontier');
create temp table t328b_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328b'::regclass and p.attached and p.lo = '0';
select is((select count(*) from t328b_src), 1::bigint, 'LIVENESS: B has a monolith at lo 0 to regrain');

select dblink_connect('r328b', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328b', 'begin isolation level repeatable read');
create temp table t328b_reader as
  select pid from dblink('r328b', 'select pg_backend_pid() from pgpm.config limit 1') as t(pid int);

set lock_timeout = '300ms';
select throws_like(
  format($$ select pgpm.regrain('public.t328b', %L, '100') $$, (select child_name from t328b_src)),
  'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select pid from t328b_reader) || ',%',
  'regrain() waits for the reader under its lock_timeout and refuses the swap when the reader outlasts it');
reset lock_timeout;
select is((select count(*) from pgpm.part where parent_table = 'public.t328b'::regclass and not attached), 0::bigint,
  'the refusal rolled the copies back with it');
select is((select p.child_oid from pgpm.part p join t328b_src s using (child_name)
            where p.parent_table = 'public.t328b'::regclass and p.attached),
  (select child_oid from t328b_src), 'and the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('r328b', 'select id from public.t328b') as t(id bigint) $$,
  $$ select g::bigint from generate_series(3, 297, 3) g union all select 1500 $$,
  'the reader reads exactly its rows: the multiples of 3 to 297, and 1500');
select dblink_exec('r328b', 'commit');
select is(pgpm.regrain('public.t328b', (select child_name from t328b_src), '100'), 3,
  'LIVENESS: once the reader committed, regrain() splits the monolith into its three fine children');
select bag_eq(
  $$ select id from public.t328b $$,
  $$ select g::bigint from generate_series(3, 297, 3) g union all select 1500 $$,
  'and every row is read after it');

-- ============================================ PART C ============================================
create table public.t328c (id bigint generated by default as identity primary key, payload text);
insert into public.t328c (id, payload) select g, 'c' || g from generate_series(2, 400, 2) g;
call pgpm.transmute('public.t328c', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328c (id, payload) values (1700, 'frontier');
create temp table t328c_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328c'::regclass and p.attached and p.lo = '0';
select is((select count(*) from t328c_src), 1::bigint, 'LIVENESS: C has a monolith at lo 0 to regrain');

select dblink_connect('r328c', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328c', 'begin');
create temp table t328c_reader as
  select pid from dblink('r328c', 'select pg_backend_pid() from pgpm.config limit 1') as t(pid int);
create temp table t328c_passed (passed int[], err text);

-- this session drives the regrain and holds regrain()'s SHARE lock first; the writer's INSERT queues behind it
begin;
lock table public.t328c in share mode;
select dblink_send_query('r328c', $q$insert into public.t328c (id, payload) values (1601, 'queued')$q$);
do $$
begin
  for i in 1..200 loop
    exit when pg_backend_pid() = any(pg_blocking_pids((select pid from t328c_reader)));
    perform pg_sleep(0.025);
  end loop;
end $$;
select ok(pg_backend_pid() = any(pg_blocking_pids((select pid from t328c_reader)))
          and (select backend_xmin is not null from pg_stat_activity where pid = (select pid from t328c_reader)),
  'LIVENESS: the writer, its statement''s snapshot held, is waiting on a lock this session holds');
-- a budget of 3 s: a wait that did not pass it would spend the budget on it and refuse
set local lock_timeout = '3s';
do $$
begin
  insert into t328c_passed (passed) values (pgpm._snapshot_wait(null, 'probe swap', 'the probe range', 'Probe'));
exception when others then
  insert into t328c_passed (err) values (sqlerrm);
end $$;
select is((select coalesce(passed::text, err) from t328c_passed), array[(select pid from t328c_reader)]::text,
  'the wait passes the session that waits on a lock of this one, and names it');
select lives_ok(
  format($$ select pgpm.regrain('public.t328c', %L, '100') $$, (select child_name from t328c_src)),
  'so regrain() completes inside its budget rather than waiting for a snapshot that cannot be released first');
commit;
select is((select r from dblink_get_result('r328c') as t(r text)), 'INSERT 0 1',
  'LIVENESS: the queued write went through once this session let go');
select count(*) from dblink_get_result('r328c') as t(r text);   -- drains the connection for the next command
select dblink_exec('r328c', 'commit');
select bag_eq(
  $$ select lo::bigint, hi::bigint from pgpm.part where parent_table = 'public.t328c'::regclass and attached and hi::bigint <= 500 $$,
  $$ values (0::bigint, 100::bigint), (100, 200), (200, 300), (300, 400), (400, 500) $$,
  'the five fine children are attached in the source''s place');
select ok(not exists (select 1 from pg_class c, t328c_src s where c.oid = s.child_oid), 'and the source is dropped');
select bag_eq(
  $$ select id from public.t328c $$,
  $$ select g::bigint from generate_series(2, 400, 2) g union all values (1601::bigint), (1700) $$,
  'and every row is read after it, the queued write included');

-- ============================================ PART D ============================================
create table public.t328d (id bigint generated by default as identity primary key, payload text);
insert into public.t328d (id, payload) select g, 'd' || g from generate_series(5, 495, 5) g;
call pgpm.transmute('public.t328d', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328d (id, payload) values (2500, 'frontier');
select pgpm.set_regrain('public.t328d', '100');

-- the first copy batch, and only it, before the reader opens
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328d', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain_copy');
  end loop;
end $$;
select dblink_connect('r328d', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328d', 'begin isolation level repeatable read');
create temp table t328d_reader as
  select pid from dblink('r328d', 'select pg_backend_pid() from pgpm.config limit 1') as t(pid int);
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328d', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328d'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;

select bag_eq(
  $$ select lo::bigint from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain_copy' $$,
  $$ values (0::bigint), (100), (200), (300), (400) $$,
  'LIVENESS: the copies ran, one batch for each of the five sub-ranges of [0, 500)');
select bag_eq(
  $$ select lo from dblink('r328d', $q$select lo::bigint from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain_copy'$q$) as t(lo bigint) $$,
  $$ values (0::bigint) $$,
  'LIVENESS: the reader opened between the first copy and the rest: it sees the [0, 100) batch and no other');
select is((select count(*) from pg_locks l, t328d_reader r
            where l.pid = r.pid and l.locktype = 'relation'
              and l.relation in (select 'public.t328d'::regclass::oid
                                 union all select i.inhrelid from pg_inherits i where i.inhparent = 'public.t328d'::regclass
                                 union all select p.child_oid from pgpm.part p where p.parent_table = 'public.t328d'::regclass)),
  0::bigint, 'LIVENESS: that reader holds no lock on the table or any of its partitions');
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328d'::regclass) = '500'
          or exists (select 1 from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain'),
  'LIVENESS: the run reached the swap (every sub-range copied and the cursor at hi, or the swap made)');
select is((select count(*) from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain'), 0::bigint,
  'the swap did not run while a reader that misses the later copies was open');
select ok(exists (select 1 from pgpm.log l, t328d_reader r
                   where l.parent_table = 'public.t328d'::regclass and l.action = 'skip_regrain'
                     and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%'),
  'the tick deferred it, logged skip_regrain naming that reader by pid');
select bag_eq(
  $$ select id from dblink('r328d', 'select id from public.t328d') as t(id bigint) $$,
  $$ select g::bigint from generate_series(5, 495, 5) g union all select 2500 $$,
  'that reader reads exactly its rows: the multiples of 5 to 495, and 2500');
select dblink_exec('r328d', 'commit');
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328d', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain'), 1::bigint,
  'once it committed, the next tick swapped');
select bag_eq(
  $$ select id from public.t328d $$,
  $$ select g::bigint from generate_series(5, 495, 5) g union all select 2500 $$,
  'and a fresh read after the swap holds exactly the same rows');

-- ============================================ PART E ============================================
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't328_owner') then create role t328_owner login; end if;
  if not exists (select 1 from pg_roles where rolname = 't328_reporter') then create role t328_reporter login; end if;
end $$;
grant usage, create on schema pgpm to t328_owner;
grant all on all tables in schema pgpm to t328_owner;
grant all on all sequences in schema pgpm to t328_owner;
grant execute on all functions in schema pgpm to t328_owner;
grant execute on all procedures in schema pgpm to t328_owner;
grant create, usage on schema public to t328_owner;
grant usage on schema pgpm to t328_reporter;
grant select on pgpm.log to t328_reporter;

set role t328_owner;
create table public.t328e (id bigint generated by default as identity primary key, payload text);
insert into public.t328e (id, payload) select g, 'e' || g from generate_series(6, 498, 6) g;
grant select on public.t328e to t328_reporter;
call pgpm.transmute('public.t328e', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328e (id, payload) values (1800, 'frontier');
select pgpm.set_regrain('public.t328e', '100');
reset role;

select dblink_connect('r328e', 'dbname=' || current_database() || ' user=t328_reporter');
select dblink_exec('r328e', 'begin isolation level repeatable read');
create temp table t328e_reader as
  select pid from dblink('r328e', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
grant select on t328e_reader to t328_owner;

select ok(not (select rolsuper from pg_roles where rolname = 't328_owner')
          and not pg_has_role('t328_owner', 'pg_read_all_stats', 'usage')
          and (select relowner::regrole::text from pg_class where oid = 'public.t328e'::regclass) = 't328_owner',
  'GUARD: the table''s owner, which runs maintain here, is no superuser and lacks pg_read_all_stats');
set role t328_owner;
select ok((select backend_xmin is not null and backend_type is null and xact_start is null
             from pg_stat_activity where pid = (select pid from t328e_reader)),
  'LIVENESS: to the owner the reader shows its snapshot (backend_xmin) but not its backend_type or xact_start');
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328e', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328e'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
reset role;

select bag_eq(
  $$ select lo::bigint from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain_copy' $$,
  $$ values (0::bigint), (100), (200), (300), (400) $$,
  'LIVENESS: the owner''s ticks ran the copies, one batch for each of the five sub-ranges of [0, 500)');
select is((select n from dblink('r328e', $q$select count(*) from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain_copy'$q$) as t(n bigint)),
  0::bigint, 'LIVENESS: the reader''s snapshot predates every copy');
select is((select count(*) from pg_locks l, t328e_reader r
            where l.pid = r.pid and l.locktype = 'relation'
              and l.relation in (select 'public.t328e'::regclass::oid
                                 union all select i.inhrelid from pg_inherits i where i.inhparent = 'public.t328e'::regclass
                                 union all select p.child_oid from pgpm.part p where p.parent_table = 'public.t328e'::regclass)),
  0::bigint, 'LIVENESS: the reader holds no lock on the table or any of its partitions');
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328e'::regclass) = '500'
          or exists (select 1 from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain'),
  'LIVENESS: the run reached the swap (every sub-range copied and the cursor at hi, or the swap made)');
select is((select count(*) from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain'), 0::bigint,
  'the owner''s tick did not swap under the other role''s reader');
select ok(exists (select 1 from pgpm.log l, t328e_reader r
                   where l.parent_table = 'public.t328e'::regclass and l.action = 'skip_regrain'
                     and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%'),
  'it deferred the swap, logged skip_regrain naming the reader by pid');
select bag_eq(
  $$ select id from dblink('r328e', 'select id from public.t328e') as t(id bigint) $$,
  $$ select g::bigint from generate_series(6, 498, 6) g union all select 1800 $$,
  'the reader reads exactly its rows: the multiples of 6 to 498, and 1800');
select dblink_exec('r328e', 'commit');
set role t328_owner;
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328e', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain');
  end loop;
end $$;
reset role;
select is((select count(*) from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain'), 1::bigint,
  'once the reader committed, the owner''s next tick swapped');
select bag_eq(
  $$ select id from public.t328e $$,
  $$ select g::bigint from generate_series(6, 498, 6) g union all select 1800 $$,
  'and a fresh read after the swap holds exactly the same rows');

-- ============================================ PART F ============================================
create table public.t328f (id bigint generated by default as identity primary key, payload text);
insert into public.t328f (id, payload) select g, 'f' || g from generate_series(4, 400, 4) g;
call pgpm.transmute('public.t328f', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328f (id, payload) values (1900, 'frontier');
create temp table t328f_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328f'::regclass and p.attached and p.lo = '0';

-- W holds ROW EXCLUSIVE, so the driver's regrain() opens its transaction and then waits for its SHARE lock
select dblink_connect('w328f', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('w328f', 'begin');
select dblink_exec('w328f', 'lock table public.t328f in row exclusive mode');
select dblink_connect('d328f', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('d328f', 'set lock_timeout = ''3s''');
create temp table t328f_driver as select pid from dblink('d328f', 'select pg_backend_pid()') as t(pid int);
select dblink_send_query('d328f', format('select pgpm.regrain(''public.t328f'', %L, ''100'')', (select child_name from t328f_src)));
do $$
begin
  for i in 1..400 loop
    exit when exists (select 1 from pg_locks where pid = (select pid from t328f_driver) and not granted);
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from pg_locks where pid = (select pid from t328f_driver) and not granted),
  'LIVENESS: the regrain() call has opened its transaction (it waits for its SHARE lock)');
-- the reader opens DURING the call, before any copy is made
select dblink_connect('r328f', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328f', 'begin isolation level repeatable read');
create temp table t328f_reader as
  select pid from dblink('r328f', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
select ok((select r.xact_start > d.xact_start and r.backend_xmin is not null
             from pg_stat_activity r, pg_stat_activity d
            where r.pid = (select pid from t328f_reader) and d.pid = (select pid from t328f_driver)),
  'LIVENESS: the reader''s transaction began after the call''s, and holds a snapshot');
select dblink_exec('w328f', 'commit');
-- the driver copies and reaches its wait; the reader, idle there, then runs its next statement in the same snapshot
do $$
begin
  for i in 1..600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where pid = (select pid from t328f_driver) and wait_event = 'PgSleep');
    perform pg_sleep(0.01);
  end loop;
end $$;
select dblink_send_query('r328f', 'select pg_sleep(1.5)');
select pg_sleep(0.2);
select ok((select state = 'active' and backend_xmin is not null from pg_stat_activity where pid = (select pid from t328f_reader)),
  'LIVENESS: the reader is running its next statement, its snapshot still held');
select is(dblink_is_busy('d328f'), 1, 'LIVENESS: while regrain() is still in its wait (no swap yet)');
create temp table t328f_result as select r from dblink_get_result('d328f', false) as t(r text);
select count(*) from dblink_get_result('r328f') as t(r text);
select count(*) from dblink_get_result('r328f') as t(r text);
select alike(dblink_error_message('d328f'),
  'ERROR:  pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select pid from t328f_reader) || ',%',
  'regrain() waited for the reader opened during the call, through its next statement, and refused the swap when it outlasted the budget');
select is((select count(*) from t328f_result), 0::bigint, 'and returned no result');
select is((select count(*) from pgpm.part where parent_table = 'public.t328f'::regclass and not attached), 0::bigint,
  'the refusal rolled the copies back with it');
select is((select n from dblink('r328f',
  'select count(*) from pg_locks where locktype = ''relation'' and relation = ''public.t328f''::regclass and pid = pg_backend_pid()') as t(n bigint)),
  0::bigint, 'LIVENESS: the reader held no lock on the table through the call');
select bag_eq(
  $$ select id from dblink('r328f', 'select id from public.t328f') as t(id bigint) $$,
  $$ select g::bigint from generate_series(4, 400, 4) g union all select 1900 $$,
  'the reader reads exactly its rows: the multiples of 4 to 400, and 1900');
select dblink_exec('r328f', 'commit');
select is(pgpm.regrain('public.t328f', (select child_name from t328f_src), '100'), 5,
  'LIVENESS: once the reader committed, regrain() splits the monolith into its five fine children');
select bag_eq(
  $$ select id from public.t328f $$,
  $$ select g::bigint from generate_series(4, 400, 4) g union all select 1900 $$,
  'and every row is read after it');

-- ============================================ PART G ============================================
create table public.t328g (id bigint generated by default as identity primary key, payload text);
insert into public.t328g (id, payload) select g, 'g' || g from generate_series(8, 496, 8) g;
call pgpm.transmute('public.t328g', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328g (id, payload) values (2600, 'frontier');
select pgpm.set_regrain('public.t328g', '100');
select dblink_connect('r328g', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328g', 'begin isolation level repeatable read');
create temp table t328g_reader as select pid from dblink('r328g', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328g', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328g'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
create temp table t328g_skips as
  select count(*) as n from pgpm.log l, t328g_reader r
   where l.parent_table = 'public.t328g'::regclass and l.action = 'skip_regrain'
     and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%';
select ok((select n from t328g_skips) = 1
          and (select regrain_cursor from pgpm.config where parent_table = 'public.t328g'::regclass) = '500',
  'LIVENESS: the run is at the swap and one tick has deferred it for the idle reader');
-- the reader starts a statement that does not touch the table and outlasts the next tick's budget
select dblink_send_query('r328g', 'select pg_sleep(1.5)');
select pg_sleep(0.2);
select ok((select state = 'active' and backend_xmin is not null from pg_stat_activity where pid = (select pid from t328g_reader)),
  'LIVENESS: the reader is in the middle of a statement, its snapshot still held');
do $$
declare v_status text;
begin
  call pgpm.maintain('public.t328g', v_status);
end $$;
select is((select count(*) from pgpm.log l, t328g_reader r
            where l.parent_table = 'public.t328g'::regclass and l.action = 'skip_regrain'
              and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%'),
  2::bigint, 'the tick deferred the swap again, naming the reader mid-statement');
select is((select count(*) from pgpm.log where parent_table = 'public.t328g'::regclass and action = 'regrain'), 0::bigint,
  'and did not swap under it');
select count(*) from dblink_get_result('r328g') as t(r text);
select count(*) from dblink_get_result('r328g') as t(r text);
select bag_eq(
  $$ select id from dblink('r328g', 'select id from public.t328g') as t(id bigint) $$,
  $$ select g::bigint from generate_series(8, 496, 8) g union all select 2600 $$,
  'the reader reads exactly its rows: the multiples of 8 to 496, and 2600');
select dblink_exec('r328g', 'commit');
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328g', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328g'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328g'::regclass and action = 'regrain'), 1::bigint,
  'LIVENESS: once the reader committed, the next tick swapped');

-- ============================================ PART H ============================================
set role t328_owner;
create table public.t328h (id bigint generated by default as identity primary key, payload text);
insert into public.t328h (id, payload) select g, 'h' || g from generate_series(9, 495, 9) g;
grant select on public.t328h to t328_reporter;
call pgpm.transmute('public.t328h', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328h (id, payload) values (2700, 'frontier');
reset role;
create temp table t328h_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328h'::regclass and p.attached and p.lo = '0';
grant select on t328h_src to t328_owner;
select dblink_connect('r328h', 'dbname=' || current_database() || ' user=t328_reporter');
select dblink_exec('r328h', 'begin isolation level repeatable read');
create temp table t328h_reader as select pid from dblink('r328h', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
grant select on t328h_reader to t328_owner;
set role t328_owner;
select ok((select backend_xmin is not null and state is null and xact_start is null and backend_type is null
             from pg_stat_activity where pid = (select pid from t328h_reader)),
  'LIVENESS: to the owner the reader shows its snapshot (backend_xmin) and nothing else: state, xact_start, backend_type NULL');
set lock_timeout = '500ms';
select throws_like(
  format($$ select pgpm.regrain('public.t328h', %L, '100') $$, (select child_name from t328h_src)),
  'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select pid from t328h_reader) || ',%',
  'regrain() run by the owner waits for the other role''s reader and refuses the swap when it outlasts the budget');
reset lock_timeout;
reset role;
select is((select p.child_oid from pgpm.part p join t328h_src s using (child_name)
            where p.parent_table = 'public.t328h'::regclass and p.attached),
  (select child_oid from t328h_src), 'the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('r328h', 'select id from public.t328h') as t(id bigint) $$,
  $$ select g::bigint from generate_series(9, 495, 9) g union all select 2700 $$,
  'the reader reads exactly its rows: the multiples of 9 to 495, and 2700');
select dblink_exec('r328h', 'commit');
set role t328_owner;
select is(pgpm.regrain('public.t328h', (select child_name from t328h_src), '100'), 5,
  'LIVENESS: once the reader committed, the owner''s regrain() splits the monolith into its five fine children');
reset role;

select dblink_disconnect('r328h');

-- ============================================ PART I ============================================
create table public.t328i (id bigint generated by default as identity primary key, payload text);
insert into public.t328i (id, payload) select g, 'i' || g from generate_series(11, 495, 11) g;
call pgpm.transmute('public.t328i', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328i (id, payload) values (2800, 'frontier');
select pgpm.set_regrain('public.t328i', '100');
create temp table t328i_state (k text primary key, v text);
-- A: REPEATABLE READ, its snapshot taken before the copies and exported, no lock on the table
select dblink_connect('a328i', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('a328i', 'begin isolation level repeatable read');
insert into t328i_state select 'snap', s from dblink('a328i', 'select pg_export_snapshot()') as t(s text);
insert into t328i_state select 'apid', p::text from dblink('a328i', 'select pg_backend_pid()') as t(p int);
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328i', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328i'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328i'::regclass) = '500'
          and exists (select 1 from pgpm.log l where l.parent_table = 'public.t328i'::regclass and l.action = 'skip_regrain'
                       and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
                                          || (select v from t328i_state where k = 'apid') || ',%'),
  'LIVENESS: the run is at the swap, and the tick deferred it for the exporter A');
-- M: the swap by hand, one regrain_step in its own transaction, against the run's recorded last write
select dblink_connect('m328i', 'dbname=' || current_database() || ' user=postgres');
insert into t328i_state select 'mpid', p::text from dblink('m328i', 'select pg_backend_pid()') as t(p int);
select dblink_exec('m328i', 'set lock_timeout = ''3s''');
select dblink_send_query('m328i', format('select pgpm.regrain_step(%L, %L, %L)', 'public.t328i',
  (select child_name from pgpm.part where parent_table = 'public.t328i'::regclass and attached and lo = '0'), '100'));
do $$
begin
  for i in 1..400 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where pid = (select v::int from t328i_state where k = 'mpid')
                        and wait_event = 'PgSleep');
    perform pg_sleep(0.01);
  end loop;
end $$;
insert into t328i_state select 'm_waiting_at', clock_timestamp()::text
  where exists (select 1 from pg_stat_activity where pid = (select v::int from t328i_state where k = 'mpid') and wait_event = 'PgSleep');
select ok(exists (select 1 from t328i_state where k = 'm_waiting_at'), 'LIVENESS: M is in its snapshot wait (waiting for A)');
-- B: opened NOW, after the wait began, importing A's snapshot
select dblink_connect('b328i', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('b328i', 'begin isolation level repeatable read');
select dblink_exec('b328i', format('set transaction snapshot %L', (select v from t328i_state where k = 'snap')));
insert into t328i_state select 'bpid', p::text from dblink('b328i', 'select pg_backend_pid()') as t(p int);
select ok((select b.backend_xmin = a.backend_xmin and b.xact_start > (select v::timestamptz from t328i_state where k = 'm_waiting_at')
             from pg_stat_activity a, pg_stat_activity b
            where a.pid = (select v::int from t328i_state where k = 'apid') and b.pid = (select v::int from t328i_state where k = 'bpid')),
  'LIVENESS: B began after M''s wait did, and holds A''s snapshot (the same backend_xmin)');
select is((select n from dblink('b328i', $q$select count(*) from pgpm.log where parent_table = 'public.t328i'::regclass and action = 'regrain_copy'$q$) as t(n bigint)),
  0::bigint, 'LIVENESS: B''s snapshot predates every copy');
-- A ends; B, imported after the wait began, must still be waited for
select dblink_exec('a328i', 'commit');
create temp table t328i_result as select r from dblink_get_result('m328i', false) as t(r text);
select alike(dblink_error_message('m328i'),
  'ERROR:  pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select v from t328i_state where k = 'bpid') || ',%',
  'once A committed, M waited for B, the importer, and refused the swap when B outlasted the budget');
select is((select count(*) from pgpm.log where parent_table = 'public.t328i'::regclass and action = 'regrain'), 0::bigint,
  'and nothing swapped under B');
select bag_eq(
  $$ select id from dblink('b328i', 'select id from public.t328i') as t(id bigint) $$,
  $$ select g::bigint from generate_series(11, 495, 11) g union all select 2800 $$,
  'B reads exactly its rows: the multiples of 11 to 495, and 2800');
select dblink_exec('b328i', 'commit');
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328i', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328i'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328i'::regclass and action = 'regrain'), 1::bigint,
  'LIVENESS: once B committed, the next tick swapped');
select dblink_disconnect('a328i');
select dblink_disconnect('b328i');
select dblink_disconnect('m328i');

-- ============================================ PART J ============================================
create table public.t328j (id bigint generated by default as identity primary key, payload text);
insert into public.t328j (id, payload) select g, 'j' || g from generate_series(12, 492, 12) g;
call pgpm.transmute('public.t328j', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328j (id, payload) values (2900, 'frontier');
create temp table t328j_src as
  select p.child_name, p.child_oid from pgpm.part p where p.parent_table = 'public.t328j'::regclass and p.attached and p.lo = '0';
create temp table t328j_state (k text primary key, v text);
create table public.t328j_w (x int);
-- W: a writer idle in its transaction from here on, holding the oldest running xid
select dblink_connect('w328j', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('w328j', 'begin');
select dblink_exec('w328j', 'insert into public.t328j_w values (1)');
insert into t328j_state select 'wpid', p::text from dblink('w328j', 'select pg_backend_pid()') as t(p int);
-- A: REPEATABLE READ, its snapshot taken now, before the copies, and exported
select dblink_connect('a328j', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('a328j', 'begin isolation level repeatable read');
insert into t328j_state select 'snap', s from dblink('a328j', 'select pg_export_snapshot()') as t(s text);
insert into t328j_state select 'apid', p::text from dblink('a328j', 'select pg_backend_pid()') as t(p int);
-- (at or before, not equal: the suite runs other files' transactions beside this one, cluster-wide xids)
select ok((select w.backend_xid is not null and age(a.backend_xmin) >= age(w.backend_xid) from pg_stat_activity a, pg_stat_activity w
            where a.pid = (select v::int from t328j_state where k = 'apid') and w.pid = (select v::int from t328j_state where k = 'wpid')),
  'LIVENESS: (J) A''s snapshot cannot see W, idle in its transaction: its xmin is at or before W''s xid');

-- M: the swap's wait, in its own session
select dblink_connect('m328j', 'dbname=' || current_database() || ' user=postgres');
insert into t328j_state select 'mpid', p::text from dblink('m328j', 'select pg_backend_pid()') as t(p int);
select dblink_exec('m328j', 'set lock_timeout = ''3s''');
select dblink_send_query('m328j', format('select pgpm.regrain(%L, %L, ''100'')', 'public.t328j', (select child_name from t328j_src)));
do $$
begin
  for i in 1..800 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where pid = (select v::int from t328j_state where k = 'mpid')
                        and wait_event = 'PgSleep');
    perform pg_sleep(0.01);
  end loop;
end $$;
insert into t328j_state select 'm_waiting_at', clock_timestamp()::text
  where exists (select 1 from pg_stat_activity where pid = (select v::int from t328j_state where k = 'mpid') and wait_event = 'PgSleep');
select ok(exists (select 1 from t328j_state where k = 'm_waiting_at'), 'LIVENESS: (J) M is in its snapshot wait');
-- B: opened after the wait began, importing A's snapshot
select dblink_connect('b328j', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('b328j', 'begin isolation level repeatable read');
select dblink_exec('b328j', format('set transaction snapshot %L', (select v from t328j_state where k = 'snap')));
insert into t328j_state select 'bpid', p::text from dblink('b328j', 'select pg_backend_pid()') as t(p int);
select ok((select b.xact_start > (select v::timestamptz from t328j_state where k = 'm_waiting_at')
                  and b.backend_xmin = a.backend_xmin and w.backend_xid is not null and age(b.backend_xmin) >= age(w.backend_xid)
             from pg_stat_activity b, pg_stat_activity w, pg_stat_activity a
            where b.pid = (select v::int from t328j_state where k = 'bpid') and w.pid = (select v::int from t328j_state where k = 'wpid')
              and a.pid = (select v::int from t328j_state where k = 'apid')),
  'LIVENESS: (J) B began after M''s wait did, holds A''s snapshot (the same xmin), at or before W''s xid (equal to it when no other transaction runs)');
select dblink_exec('a328j', 'commit');
create temp table t328j_result as select r from dblink_get_result('m328j', false) as t(r text);
select ok(dblink_error_message('m328j') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred: [0-9]+ snapshot\(s\) older than the copies still open \(oldest: pid [0-9]+, open [^;]*; pids ([0-9]+, )*'
                                              || (select v from t328j_state where k = 'bpid') || '(, [0-9]+)*\)'),
  '(J) once A committed, M waited for B, the importer, and refused the swap, naming it');
select ok((select count(*) from pgpm.log where parent_table = 'public.t328j'::regclass and action = 'regrain') = 0
          and exists (select 1 from pgpm.part p, t328j_src s where p.parent_table = 'public.t328j'::regclass and p.attached and p.child_oid = s.child_oid),
  '(J) nothing swapped: the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('b328j', 'select id from public.t328j') as t(id bigint) $$,
  $$ select g::bigint from generate_series(12, 492, 12) g union all select 2900 $$,
  '(J) B reads exactly its rows: the multiples of 12 to 492, and 2900');
select dblink_exec('b328j', 'commit');
select dblink_exec('w328j', 'rollback');
select is(pgpm.regrain('public.t328j', (select child_name from t328j_src), '100'), 5,
  'LIVENESS: (J) with B and W gone, regrain() splits the monolith into its five fine children');
select dblink_disconnect('a328j');
select dblink_disconnect('b328j');
select dblink_disconnect('m328j');
select dblink_disconnect('w328j');

-- ============================================ PART K ============================================
create table public.t328k (id bigint generated by default as identity primary key, payload text);
insert into public.t328k (id, payload) select g, 'k' || g from generate_series(13, 494, 13) g;
call pgpm.transmute('public.t328k', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328k (id, payload) values (3000, 'frontier');
create temp table t328k_src as
  select p.child_name, p.child_oid from pgpm.part p where p.parent_table = 'public.t328k'::regclass and p.attached and p.lo = '0';
create temp table t328k_state (k text primary key, v text);
create table public.t328k_w (x int);
-- W: a writer idle in its transaction from here on, holding the oldest running xid
select dblink_connect('w328k', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('w328k', 'begin');
select dblink_exec('w328k', 'insert into public.t328k_w values (1)');
insert into t328k_state select 'wpid', p::text from dblink('w328k', 'select pg_backend_pid()') as t(p int);
-- A: REPEATABLE READ, its snapshot taken now, before the copies, and exported
select dblink_connect('a328k', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('a328k', 'begin isolation level repeatable read');
insert into t328k_state select 'snap', s from dblink('a328k', 'select pg_export_snapshot()') as t(s text);
insert into t328k_state select 'apid', p::text from dblink('a328k', 'select pg_backend_pid()') as t(p int);
-- (at or before, not equal: the suite runs other files' transactions beside this one, cluster-wide xids)
select ok((select w.backend_xid is not null and age(a.backend_xmin) >= age(w.backend_xid) from pg_stat_activity a, pg_stat_activity w
            where a.pid = (select v::int from t328k_state where k = 'apid') and w.pid = (select v::int from t328k_state where k = 'wpid')),
  'LIVENESS: (K) A''s snapshot cannot see W, idle in its transaction: its xmin is at or before W''s xid');
select pgpm.set_regrain('public.t328k', '100');
do $$
declare v_status text;
begin
  for i in 1..40 loop
    exit when (select regrain_cursor from pgpm.config where parent_table = 'public.t328k'::regclass) = '500';
    call pgpm.maintain('public.t328k', v_status);
  end loop;
end $$;
-- the state an install from before regrain_written_xid leaves an in-flight run in: no recorded last write (no
-- maintain tick runs on this table from here on, so the run stays in flight until the hand regrain_step below)
update pgpm.config set regrain_written_xid = null where parent_table = 'public.t328k'::regclass;
select ok((select regrain_cursor = '500' and regrain_written_xid is null from pgpm.config where parent_table = 'public.t328k'::regclass)
          and (select count(*) from pgpm.log where parent_table = 'public.t328k'::regclass and action = 'regrain_copy') = 5,
  'LIVENESS: (K) the run''s five copies are made, the cursor at hi, and no last write recorded (as across the upgrade)');
-- M: the swap's wait, in its own session
select dblink_connect('m328k', 'dbname=' || current_database() || ' user=postgres');
insert into t328k_state select 'mpid', p::text from dblink('m328k', 'select pg_backend_pid()') as t(p int);
select dblink_exec('m328k', 'set lock_timeout = ''3s''');
select dblink_send_query('m328k', format('select pgpm.regrain_step(%L, %L, ''100'')', 'public.t328k', (select child_name from t328k_src)));
do $$
begin
  for i in 1..800 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where pid = (select v::int from t328k_state where k = 'mpid')
                        and wait_event = 'PgSleep');
    perform pg_sleep(0.01);
  end loop;
end $$;
insert into t328k_state select 'm_waiting_at', clock_timestamp()::text
  where exists (select 1 from pg_stat_activity where pid = (select v::int from t328k_state where k = 'mpid') and wait_event = 'PgSleep');
select ok(exists (select 1 from t328k_state where k = 'm_waiting_at'), 'LIVENESS: (K) M is in its snapshot wait');
-- B: opened after the wait began, importing A's snapshot
select dblink_connect('b328k', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('b328k', 'begin isolation level repeatable read');
select dblink_exec('b328k', format('set transaction snapshot %L', (select v from t328k_state where k = 'snap')));
insert into t328k_state select 'bpid', p::text from dblink('b328k', 'select pg_backend_pid()') as t(p int);
select ok((select b.xact_start > (select v::timestamptz from t328k_state where k = 'm_waiting_at')
                  and b.backend_xmin = a.backend_xmin and w.backend_xid is not null and age(b.backend_xmin) >= age(w.backend_xid)
             from pg_stat_activity b, pg_stat_activity w, pg_stat_activity a
            where b.pid = (select v::int from t328k_state where k = 'bpid') and w.pid = (select v::int from t328k_state where k = 'wpid')
              and a.pid = (select v::int from t328k_state where k = 'apid')),
  'LIVENESS: (K) B began after M''s wait did, holds A''s snapshot (the same xmin), at or before W''s xid (equal to it when no other transaction runs)');
select dblink_exec('a328k', 'commit');
create temp table t328k_result as select r from dblink_get_result('m328k', false) as t(r text);
select ok(dblink_error_message('m328k') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred: [0-9]+ snapshot\(s\) older than the copies still open \(oldest: pid [0-9]+, open [^;]*; pids ([0-9]+, )*'
                                              || (select v from t328k_state where k = 'bpid') || '(, [0-9]+)*\)'),
  '(K) once A committed, M waited for B, the importer, and refused the swap, naming it');
select ok((select count(*) from pgpm.log where parent_table = 'public.t328k'::regclass and action = 'regrain') = 0
          and exists (select 1 from pgpm.part p, t328k_src s where p.parent_table = 'public.t328k'::regclass and p.attached and p.child_oid = s.child_oid),
  '(K) nothing swapped: the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('b328k', 'select id from public.t328k') as t(id bigint) $$,
  $$ select g::bigint from generate_series(13, 494, 13) g union all select 3000 $$,
  '(K) B reads exactly its rows: the multiples of 13 to 494, and 3000');
select dblink_exec('b328k', 'commit');
select dblink_exec('w328k', 'rollback');
select is((select r from (select pgpm.regrain_step('public.t328k', (select child_name from t328k_src), '100') as r) x), 'swapped:5',
  'LIVENESS: (K) with B and W gone, the hand regrain_step swaps in the five fine children');
select dblink_disconnect('a328k');
select dblink_disconnect('b328k');
select dblink_disconnect('m328k');
select dblink_disconnect('w328k');
select dblink_disconnect('r328g');
select dblink_disconnect('r328a');
select dblink_disconnect('r328b');
select dblink_disconnect('r328c');
select dblink_disconnect('r328d');
select dblink_disconnect('r328e');
select dblink_disconnect('r328f');
select dblink_disconnect('d328f');
select dblink_disconnect('w328f');
drop table public.t328e;
drop table public.t328h;
reassign owned by t328_owner, t328_reporter to current_user;
drop owned by t328_owner, t328_reporter;
drop role t328_owner;
drop role t328_reporter;
select * from finish();
