-- transmute_abort drops the bound on the table its claim names, found by oid, never by a name rendered before
-- its lock wait (issue #1364).
--
-- THE BUG. transmute_abort rendered the table's name and ran ALTER TABLE ... DROP CONSTRAINT IF EXISTS
-- pgpm_monolith_bound, which waits for ACCESS EXCLUSIVE behind any reader and resolves the name again once granted.
-- A schema renamed aside while it waited (ALTER SCHEMA ... RENAME takes no relation lock), with a namesake schema and
-- table committed in its place, was what the DROP reached: the namesake lost a constraint of that name, the abort
-- deleted the claim and logged 'bound dropped, table restored', and the table pgpm had claimed kept its
-- write-rejecting bound with nothing left to record it, out of reach of transmute_abort and the reaper alike.
--
-- THE CONTRACT. The abort locks the table by the claim's oid first (pgpm._lock_oid_or_raise, which follows a
-- rename) and names it under that lock, so the DROP waits for nothing and reaches the table wherever its schema now
-- is: the bound comes off the claimed table, the claim goes, the abort is logged against that table, and the
-- namesake keeps what it had.
--
-- The dead conversion is a real one: transmute parked in phase 2 behind a SHARE UPDATE EXCLUSIVE holder and its
-- session terminated, so the claim and the NOT VALID bound are what a crashed transmute leaves. Every concurrent
-- order is set by a lock queue and a server-side poll of pg_locks, one statement per sample, its snapshot cleared.
--
-- ASYMMETRIC FIXTURES: the claimed table holds ids 1, 2, 3 and takes id 4 once the bound is off; the namesake holds
-- ids 7, 8 and its own CHECK named pgpm_monolith_bound. Every check names a relation by oid.
-- transmute_abort is a function, not a committing procedure; no throws_* here.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(15);

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

-- p_pid has left
create function pg_temp.gone(p_pid int) returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if not exists (select 1 from pg_stat_activity where pid = p_pid) then return true; end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

-- the ids a relation holds, read by its oid
create function pg_temp.ids_of(p_oid oid) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if not exists (select 1 from pg_class where oid = p_oid) then return null; end if;
  execute format('select array_agg(id order by id) from only %s', p_oid::regclass) into v;
  return v;
end $$;

select dblink_connect('h351', format('dbname=%s user=postgres', current_database())) as h \gset
select dblink_connect('g351', format('dbname=%s user=postgres', current_database())) as g \gset
select dblink_connect('c351', format('dbname=%s user=postgres options=-ctimezone=UTC', current_database())) as c \gset
select dblink_connect('a351', format('dbname=%s user=postgres', current_database())) as a \gset
select pid as c_pid from dblink('c351', 'select pg_backend_pid()') as t(pid int) \gset
select pid as a_pid from dblink('a351', 'select pg_backend_pid()') as t(pid int) \gset

create schema s351;
create table s351.t (id bigint, ts timestamptz not null, primary key (id, ts));
insert into s351.t values (1, now() - interval '3 days'), (2, now() - interval '2 days'), (3, now() - interval '1 day');
select 's351.t'::regclass::oid as t_oid \gset

-- ======================= the dead conversion: transmute's session terminated in phase 2 =======================
select dblink_exec('h351', 'begin') as h1 \gset
select count(*) as h_rows from dblink('h351', 'select count(*) from s351.t') as t(n bigint) \gset
select dblink_send_query('c351',
  $q$call pgpm.transmute('s351.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as c1 \gset
select ok(pg_temp.waits_for(:c_pid, :'t_oid'::oid, 'AccessExclusiveLock'),
  'LIVENESS: transmute''s phase 1 waits for the table''s ACCESS EXCLUSIVE behind a reader');
select dblink_exec('g351', 'begin') as g1 \gset
select dblink_send_query('g351', 'lock table s351.t in share update exclusive mode') as g2 \gset
select ok(pg_temp.waiters(:'t_oid'::oid, 2), 'fixture: a SHARE UPDATE EXCLUSIVE holder is queued behind phase 1');
select dblink_exec('h351', 'commit') as h2 \gset
select ok(pg_temp.waits_for(:c_pid, :'t_oid'::oid, 'ShareUpdateExclusiveLock'),
  'LIVENESS: phase 1 committed and phase 2 waits behind the holder');
select pg_terminate_backend(:c_pid) as killed \gset
select ok(pg_temp.gone(:c_pid), 'fixture: the transmuting session is gone');
select count(*) as g_rows from dblink_get_result('g351', false) as t(x text) \gset
select count(*) as g_drained from dblink_get_result('g351', false) as t(x text) \gset
select dblink_exec('g351', 'commit') as g3 \gset
select dblink_disconnect('c351') as c2 \gset
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table::oid = :'t_oid'::oid)
          and exists (select 1 from pg_constraint where conrelid = :'t_oid'::oid and conname = 'pgpm_monolith_bound'),
  'LIVENESS: the dead conversion''s claim and its bound are on the table, the state transmute_abort undoes');

-- ======================= the abort, waiting behind a reader while the schema is swapped =======================
select dblink_exec('h351', 'begin') as h3 \gset
select count(*) as h_rows2 from dblink('h351', 'select count(*) from s351.t') as t(n bigint) \gset
select dblink_send_query('a351', $q$select pgpm.transmute_abort('s351.t'::regclass, '60s')$q$) as a1 \gset
select ok(pg_temp.waits_for(:a_pid, :'t_oid'::oid, 'AccessExclusiveLock'),
  'LIVENESS: transmute_abort waits for ACCESS EXCLUSIVE on the claimed table''s oid, behind the reader');
select dblink_exec('g351', 'alter schema s351 rename to s351_aside') as g4 \gset
select dblink_exec('g351', 'create schema s351') as g5 \gset
select dblink_exec('g351', $q$create table s351.t (id bigint, ts timestamptz not null,
                                 constraint pgpm_monolith_bound check (ts < '2100-01-01'))$q$) as g6 \gset
select dblink_exec('g351', $q$insert into s351.t values (7, '2001-01-01'), (8, '2002-01-01')$q$) as g7 \gset
select 's351.t'::regclass::oid as squat_oid \gset
select dblink_exec('h351', 'commit') as h4 \gset
select coalesce((select bool_or(r.aborted) from dblink_get_result('a351', false) as r(aborted boolean))::text, 'none') as aborted \gset
select dblink_error_message('a351') as abort_msg \gset
select count(*) as a_drained from dblink_get_result('a351', false) as t(x text) \gset

select ok(:'squat_oid'::oid <> :'t_oid'::oid, 'LIVENESS: the table''s old name denotes the namesake now');
select is(:'abort_msg'::text, 'OK', 'transmute_abort completed');
select is(:'aborted'::text, 'true', 'and reported the conversion aborted');
select ok(not exists (select 1 from pg_constraint where conrelid = :'t_oid'::oid and conname = 'pgpm_monolith_bound'),
  'the bound is off the claimed table, which the abort followed into its renamed schema');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table::oid = :'t_oid'::oid),
  'its claim is gone');
select is((select array_agg(action order by id) from pgpm.log where parent_table::oid = :'t_oid'::oid and action = 'transmute_abort'),
  array['transmute_abort']::text[], 'the abort is logged once, against the claimed table');
select ok(exists (select 1 from pg_constraint where conrelid = :'squat_oid'::oid and conname = 'pgpm_monolith_bound'),
  'the namesake keeps its own constraint of the bound''s name');
select lives_ok($$insert into s351_aside.t values (4, now() + interval '1 year')$$,
  'the claimed table takes a write past the old bound');
select is(pg_temp.ids_of(:'t_oid'::oid) || pg_temp.ids_of(:'squat_oid'::oid), array[1, 2, 3, 4, 7, 8]::bigint[],
  'the claimed table takes a row past the old bound (ids 1..4), the namesake keeps ids 7 and 8');

select dblink_disconnect(n) from unnest(array['h351', 'g351', 'a351']) n;
select * from finish();
