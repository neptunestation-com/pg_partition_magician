-- transmute's bound goes on the table it identified, by oid, whatever a schema swap does to the name while a phase
-- waits for its lock (issue #1355, and its re-find F1-05 in pass 13).
--
-- THE BUG. Phase 1 ran ALTER TABLE <name> ADD CONSTRAINT pgpm_monolith_bound ... NOT VALID with the name rendered
-- before the ADD waited for ACCESS EXCLUSIVE behind a reader. A schema renamed aside while it waited (ALTER SCHEMA
-- ... RENAME takes no relation lock), with a namesake schema and table committed in its place, was what the ADD
-- reached once granted: phase 1 committed the write-rejecting CHECK on a table pgpm never identified, which refused
-- every write outside [lo, hi) from then on, while the table it was converting went on without its bound. Phase 2's
-- VALIDATE was named the same way, and validated a namesake's constraint of that name.
--
-- THE CONTRACT. Each phase takes its lock on the table by oid before its statement and names the table under that
-- lock (pgpm._lock_oid_or_raise), so the statement waits for nothing and reaches the table wherever its schema now
-- is; the preflight takes the table's first lock through the name it read (pgpm._lock_named_or_raise) and refuses a
-- name that stopped denoting the table before anything is committed; and the cutover, which makes every name it
-- creates from the preflight's, refuses a table moved since (#1367, tests/353). The documented remedy, re-running
-- transmute on the table's name now, is typed here and completes the conversion.
--   PART A  phase 1's ADD waits behind a reader and the schema is swapped: the bound goes on the table pgpm
--           identified, the namesake carries none and takes its writes, the cutover refuses the moved table, and
--           the re-run on the table's new name resumes from the recorded bound and converts it.
--   PART B  phase 2's VALIDATE waits behind a SHARE UPDATE EXCLUSIVE holder and the schema is swapped to a namesake
--           carrying a NOT VALID constraint of the bound's name: the table's bound is validated, the namesake's is
--           left NOT VALID, and the re-run converts the table.
--   PART C  the preflight's first lock waits behind an ACCESS EXCLUSIVE holder and the schema is swapped: refused in
--           pgpm's words with nothing committed (no claim, no bound anywhere), and the re-run converts the table.
-- Every concurrent order is set by a lock queue and a server-side poll of pg_locks, one statement per sample, its
-- snapshot cleared. transmute runs in its own dblink session ('c352'), which holds a claim it can resume.
--
-- ASYMMETRIC FIXTURES: A's table holds ids 1, 2, 3 and its namesake 7, 8 (then 9); B's table ids 1..4 and its
-- namesake 7, which satisfies the namesake's own constraint, so a VALIDATE that reached it would succeed; C's table
-- ids 1, 2 dated two months back and its namesake 7, 8, 9 dated this hour, so a bound read from the namesake would
-- exclude the table's rows. Every check names a relation by oid.
-- No throws_* here: every call to the committing procedure runs in the dblink session and its error is read there.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(30);

-- p_pid is waiting, ungranted, for p_mode on p_oid
create function pg_temp.waits_for(p_pid int, p_oid oid, p_mode text) returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'relation' and l.relation = p_oid and l.mode = p_mode
                  and l.pid = p_pid) then
      return true;
    end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

-- n sessions are waiting, ungranted, for a lock on p_oid
create function pg_temp.waiters(p_oid oid, p_n int) returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if (select count(*) from pg_locks l where not l.granted and l.locktype = 'relation' and l.relation = p_oid) >= p_n then
      return true;
    end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

-- the ids a relation holds, read by its oid
create function pg_temp.ids_of(p_oid oid) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if not exists (select 1 from pg_class where oid = p_oid) then return null; end if;
  execute format('select array_agg(id order by id) from %s', p_oid::regclass) into v;
  return v;
end $$;

-- the outcome of the call c352 is running: 'OK', or its error message
create function pg_temp.outcome() returns text language plpgsql as $$
declare v text;
begin
  perform count(*) from dblink_get_result('c352', false) as t(x text);
  v := dblink_error_message('c352');
  perform count(*) from dblink_get_result('c352', false) as t(x text);
  return v;
end $$;

select dblink_connect('h352', format('dbname=%s user=postgres', current_database())) as h \gset
select dblink_connect('g352', format('dbname=%s user=postgres', current_database())) as g \gset
select dblink_connect('c352', format('dbname=%s user=postgres options=-ctimezone=UTC', current_database())) as c \gset
select pid as c_pid from dblink('c352', 'select pg_backend_pid()') as t(pid int) \gset

-- ======================= (A) phase 1's ADD waits behind a reader; the schema is swapped =======================
create schema a352;
create table a352.t (id bigint, ts timestamptz not null, primary key (id, ts));
insert into a352.t values (1, now() - interval '3 days'), (2, now() - interval '2 days'), (3, now() - interval '1 day');
select 'a352.t'::regclass::oid as a_oid \gset
select dblink_exec('h352', 'begin') as a1 \gset
select count(*) as a_rows from dblink('h352', 'select count(*) from a352.t') as t(n bigint) \gset
select dblink_send_query('c352', $q$call pgpm.transmute('a352.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as a2 \gset
select ok(pg_temp.waits_for(:c_pid, :'a_oid'::oid, 'AccessExclusiveLock'),
  'LIVENESS: A: phase 1 waits for the table''s ACCESS EXCLUSIVE behind a reader');
select ok(not exists (select 1 from pg_constraint where conrelid = :'a_oid'::oid and conname = 'pgpm_monolith_bound'),
  'LIVENESS: A: the bound is not added yet, so the ADD is what waits');
select dblink_exec('g352', 'alter schema a352 rename to a352_aside') as a3 \gset
select dblink_exec('g352', 'create schema a352') as a4 \gset
select dblink_exec('g352', 'create table a352.t (id bigint, ts timestamptz not null, primary key (id, ts))') as a5 \gset
select dblink_exec('g352', $q$insert into a352.t values (7, '2030-01-01'), (8, '2030-01-02')$q$) as a6 \gset
select 'a352.t'::regclass::oid as a_squat \gset
select dblink_exec('h352', 'commit') as a7 \gset
select pg_temp.outcome() as a_msg \gset

select ok(:'a_squat'::oid <> :'a_oid'::oid, 'LIVENESS: A: the table''s old name denotes the namesake now');
select ok(not exists (select 1 from pg_constraint where conrelid = :'a_squat'::oid and conname = 'pgpm_monolith_bound'),
  'A: the namesake carries no pgpm_monolith_bound');
select lives_ok($$insert into a352.t values (9, '2031-01-01')$$, 'A: and takes a write far outside the bound');
select ok(exists (select 1 from pg_constraint where conrelid = :'a_oid'::oid and conname = 'pgpm_monolith_bound' and convalidated),
  'A: the bound is on the table pgpm identified, validated: phases 1 and 2 followed it into its renamed schema');
select ok(:'a_msg' like '%transmute could not take its access share lock on a352_aside.t (oid %) under the name a352.t it read before%',
  'A: the cutover refused the moved table, naming the name it read and the table''s name now');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table::oid = :'a_oid'::oid),
  'A: the claim stands, so the conversion can be resumed');
select dblink_send_query('c352', $q$call pgpm.transmute('a352_aside.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as a8 \gset
select is(pg_temp.outcome(), 'OK', 'A: the remedy, re-running transmute on the table''s name now, completes');
select is((select parent_table::text from pgpm.config where monolith_oid = :'a_oid'::oid), 'a352_aside.t',
  'A: the table is converted under its name now, the original its monolith');
select is((select array_agg(action order by id) from pgpm.log l join pgpm.config c on c.parent_table = l.parent_table
            where c.monolith_oid = :'a_oid'::oid and l.action in ('transmute', 'transmute_resume')),
  array['transmute', 'transmute_resume']::text[], 'A: from the bound phase 1 recorded');
select is(pg_temp.ids_of(to_regclass('a352_aside.t')::oid) || pg_temp.ids_of(:'a_squat'::oid), array[1, 2, 3, 7, 8, 9]::bigint[],
  'A: the table holds ids 1..3, the namesake 7, 8, 9');

-- ======================= (B) phase 2's VALIDATE waits behind a holder; the schema is swapped =======================
create schema b352;
create table b352.t (id bigint, ts timestamptz not null, primary key (id, ts));
insert into b352.t select g, now() - make_interval(days => g) from generate_series(1, 4) g;
select 'b352.t'::regclass::oid as b_oid \gset
select dblink_exec('h352', 'begin') as b1 \gset
select count(*) as b_rows from dblink('h352', 'select count(*) from b352.t') as t(n bigint) \gset
select dblink_send_query('c352', $q$call pgpm.transmute('b352.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as b2 \gset
select ok(pg_temp.waits_for(:c_pid, :'b_oid'::oid, 'AccessExclusiveLock'), 'fixture: B: phase 1 waits behind a reader');
select dblink_exec('g352', 'begin') as b3 \gset
select dblink_send_query('g352', 'lock table b352.t in share update exclusive mode') as b4 \gset
select ok(pg_temp.waiters(:'b_oid'::oid, 2), 'fixture: B: a SHARE UPDATE EXCLUSIVE holder is queued behind phase 1');
select dblink_exec('h352', 'commit') as b5 \gset
select ok(pg_temp.waits_for(:c_pid, :'b_oid'::oid, 'ShareUpdateExclusiveLock'),
  'LIVENESS: B: phase 2 waits behind the holder');
select is((select convalidated from pg_constraint where conrelid = :'b_oid'::oid and conname = 'pgpm_monolith_bound'), false,
  'LIVENESS: B: phase 1 committed its NOT VALID bound, so the VALIDATE is what waits');
select count(*) as b_g1 from dblink_get_result('g352', false) as t(x text) \gset
select count(*) as b_g2 from dblink_get_result('g352', false) as t(x text) \gset
select dblink_exec('g352', 'alter schema b352 rename to b352_aside') as b6 \gset
select dblink_exec('g352', 'create schema b352') as b7 \gset
select dblink_exec('g352', 'create table b352.t (id bigint, ts timestamptz not null)') as b8 \gset
select dblink_exec('g352', $q$insert into b352.t values (7, '2001-01-01')$q$) as b9 \gset
select dblink_exec('g352', $q$alter table b352.t add constraint pgpm_monolith_bound check (ts > '2000-01-01') not valid$q$) as b10 \gset
select dblink_exec('g352', 'commit') as b11 \gset
select 'b352.t'::regclass::oid as b_squat \gset
select pg_temp.outcome() as b_msg \gset

select ok(:'b_squat'::oid <> :'b_oid'::oid, 'LIVENESS: B: the table''s old name denotes the namesake now');
select is((select convalidated from pg_constraint where conrelid = :'b_squat'::oid and conname = 'pgpm_monolith_bound'), false,
  'B: the namesake''s constraint of the bound''s name is left NOT VALID');
select is((select convalidated from pg_constraint where conrelid = :'b_oid'::oid and conname = 'pgpm_monolith_bound'), true,
  'B: the bound of the table pgpm identified is validated');
select ok(:'b_msg' like '%transmute could not take its access share lock on b352_aside.t (oid %) under the name b352.t it read before%',
  'B: the cutover refused the moved table');
select dblink_send_query('c352', $q$call pgpm.transmute('b352_aside.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as b12 \gset
select is(pg_temp.outcome(), 'OK', 'B: the re-run on the table''s name now completes');
select is((select parent_table::text from pgpm.config where monolith_oid = :'b_oid'::oid), 'b352_aside.t',
  'B: the table is converted under its name now');
select is(pg_temp.ids_of(to_regclass('b352_aside.t')::oid) || pg_temp.ids_of(:'b_squat'::oid), array[1, 2, 3, 4, 7]::bigint[],
  'B: the table holds ids 1..4, the namesake 7');

-- ======================= (C) the preflight's first lock waits; the schema is swapped =======================
create schema c352x;
create table c352x.t (id bigint, ts timestamptz not null, primary key (id, ts));
insert into c352x.t values (1, now() - interval '70 days'), (2, now() - interval '65 days');
select 'c352x.t'::regclass::oid as c_oid \gset
select dblink_exec('h352', 'begin') as c1 \gset
select dblink_exec('h352', 'lock table c352x.t in access exclusive mode') as c2 \gset
select dblink_send_query('c352', $q$call pgpm.transmute('c352x.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as c3 \gset
select ok(pg_temp.waits_for(:c_pid, :'c_oid'::oid, 'AccessShareLock'),
  'LIVENESS: C: transmute''s first lock on the table waits behind an ACCESS EXCLUSIVE holder');
select dblink_exec('h352', 'alter schema c352x rename to c352x_aside') as c4 \gset
select dblink_exec('h352', 'create schema c352x') as c5 \gset
select dblink_exec('h352', 'create table c352x.t (id bigint, ts timestamptz not null, primary key (id, ts))') as c6 \gset
select dblink_exec('h352', $q$insert into c352x.t values (7, now() - interval '3 hours'), (8, now() - interval '2 hours'),
                                                     (9, now() - interval '1 hour')$q$) as c7 \gset
select dblink_exec('h352', 'commit') as c8 \gset
select 'c352x.t'::regclass::oid as c_squat \gset
select pg_temp.outcome() as c_msg \gset

select ok(:'c_squat'::oid <> :'c_oid'::oid, 'LIVENESS: C: the table''s old name denotes the namesake now');
select ok(:'c_msg' like '%transmute could not take its access share lock on c352x_aside.t (oid %) under the name c352x.t it read before%',
  'C: transmute refused before anything was committed, naming the name it read');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table::oid in (:'c_oid'::oid, :'c_squat'::oid)),
  'C: no claim was recorded');
select ok(not exists (select 1 from pg_constraint where conrelid in (:'c_oid'::oid, :'c_squat'::oid) and conname = 'pgpm_monolith_bound'),
  'C: no bound is on the table or on the namesake');
select dblink_send_query('c352', $q$call pgpm.transmute('c352x_aside.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as c9 \gset
select is(pg_temp.outcome(), 'OK', 'C: the re-run on the table''s name now completes');
select is(pg_temp.ids_of(to_regclass('c352x_aside.t')::oid) || pg_temp.ids_of(:'c_squat'::oid), array[1, 2, 7, 8, 9]::bigint[],
  'C: the converted table holds ids 1 and 2, the namesake 7, 8, 9');

select dblink_disconnect(n) from unnest(array['h352', 'g352', 'c352']) n;
select * from finish();
