-- The relation statements the schema-swap families left reach what pgpm identified by oid (the schema-swap class:
-- #1335 bullet 10, #1358, #1362, #1366; the pass-13 record's call for one lever with a static exhaustiveness check,
-- scripts/check_by_name_after_wait.py).
--
-- THE BUG. A statement that names a relation pgpm identified by oid renders the name before it waits for its lock,
-- and resolves the NAME again once granted. A lock pins a relation's own name, never its schema's (ALTER SCHEMA ...
-- RENAME takes no relation lock), so a schema renamed aside during the wait, with a namesake schema and relation
-- committed in its place, is what the statement reaches. Three statements the per-family fixes (#1399, #1400,
-- #1402) did not own still did that:
--   PART A  _frontier_native's read of the parent (the shared frontier of obtain, extend_to, progress and an id
--           grid's retention horizon): a reader of the namesake's maximum made it the frontier.
--   PART B  _create_partition's CREATE TABLE ... PARTITION OF (obtain, extend_to): the operator's partitioned table
--           took the new partition, pgpm.part recorded it under the namesake's oid, and the managed table had no
--           partition for the range.
--   PART F  _detach_reap's FINALIZE, by names read before its wait for ACCESS EXCLUSIVE on the partition: it
--           reached the namesakes and left the abandoned detach it identified pending.
--
-- THE CONTRACT. Each locks the relation by oid first (pgpm._lock_oid_or_raise, in the statement's own mode) and
-- names it as it is under that lock, so the statement waits for nothing of it and reaches the relation wherever its
-- schema has gone; the namesake is left as it was.
--
-- Every concurrent order is set by a lock queue: a second session ('h359') holds a conflicting lock, a third
-- ('r359') makes the call, a server-side poll (snapshot cleared every iteration) sees the call waiting on the oid,
-- and only then does the holder rename, create and commit. ASYMMETRIC FIXTURES: each managed table holds ids 10..N
-- 'real' and each namesake holds its own distinct values, so every check names rows and relations by value or oid.
-- No throws_* here.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(23);

-- the call in session r359 is waiting, ungranted, for p_mode on p_oid: one statement per sample, snapshot cleared
create function pg_temp.waits_for(p_oid oid, p_mode text) returns boolean language plpgsql as $$
begin
  for i in 1 .. 800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'relation' and l.relation = p_oid and l.mode = p_mode
                  and l.pid = current_setting('pgpm359.r_pid')::int) then
      return true;
    end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

-- p_parent has a pending detach and session p_pid is parked in its wait phase (tests/198's poll)
create function pg_temp.parked(p_parent regclass, p_pid int) returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_inherits where inhparent = p_parent and inhdetachpending)
       and exists (select 1 from pg_locks where pid = p_pid and locktype = 'virtualxid' and not granted)
    then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

-- wait for the call in session r359 to finish WITHOUT holding a snapshot across the wait: a FINALIZE waits for every
-- transaction whose snapshot is older than its own (WaitForOlderSnapshots), and a dblink_get_result issued at once
-- would be one, waiting in its turn for the FINALIZE until the reap's lock_timeout. A procedure that commits each turn
create procedure pg_temp.await_r() language plpgsql as $$
begin
  for i in 1 .. 2400 loop
    commit;
    exit when dblink_is_busy('r359') = 0;
    perform pg_sleep(0.025);
  end loop;
end $$;

create function pg_temp.gone(p_pid int) returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if not exists (select 1 from pg_stat_activity where pid = p_pid) then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

select dblink_connect('h359', format('dbname=%s user=postgres', current_database())) as h \gset
select dblink_connect('r359', format('dbname=%s user=postgres', current_database())) as r \gset
select set_config('pgpm359.r_pid', (select pid::text from dblink('r359', 'select pg_backend_pid()') as t(pid int)), false) as r_pid \gset
select dblink_exec('r359', 'set lock_timeout = ''60s''') as r_lt \gset
select dblink_exec('r359', 'set statement_timeout = ''120s''') as r_st \gset

-- ======================= (A) _frontier_native reads the parent it identified ===================================
create schema a359s;
create table a359s.t (id bigint primary key, payload text);
insert into a359s.t select g * 10, 'real' from generate_series(1, 199) g;
call pgpm.transmute('a359s.t', 'id', 1000, p_paused => true);
select 'a359s.t'::regclass::oid as a_parent \gset
select is(pgpm._frontier_native(:'a_parent'::oid::regclass), '1990',
  'LIVENESS: A: the frontier is the managed table''s largest id, 1990');

select dblink_exec('h359', 'begin') as a1 \gset
select dblink_exec('h359', 'lock table a359s.t in access exclusive mode') as a2 \gset
select dblink_send_query('r359', format('select pgpm._frontier_native(%s::oid::regclass)', :'a_parent')) as a3 \gset
select ok(pg_temp.waits_for(:'a_parent'::oid, 'AccessShareLock'),
  'LIVENESS: A: the read waits for ACCESS SHARE on the parent''s oid, behind the holder');
select dblink_exec('h359', 'alter schema a359s rename to a359s_aside') as a4 \gset
select dblink_exec('h359', 'create schema a359s') as a5 \gset
select dblink_exec('h359', 'create table a359s.t (id bigint, payload text)') as a6 \gset
select dblink_exec('h359', $$insert into a359s.t values (999999, 'stranger')$$) as a7 \gset
select o as a_squat from dblink('h359', $$select 'a359s.t'::regclass::oid$$) as t(o oid) \gset
select dblink_exec('h359', 'commit') as a8 \gset
select coalesce(string_agg(x, ','), 'no row') as a_ret from dblink_get_result('r359', false) as t(x text) \gset
select dblink_error_message('r359') as a_err \gset
select count(*) as a_drained from dblink_get_result('r359', false) as t(x text) \gset
select ok(:'a_squat'::oid <> :'a_parent'::oid,
  'LIVENESS: A: the parent''s name denotes the stranger once the holder commits');

select is(:'a_ret'::text, '1990',
  format('A: the frontier read once the holder committed is still the managed table''s 1990, never the stranger''s 999999 (%s)', :'a_err'));
select is((select array_agg(id order by id) from a359s.t), array[999999::bigint],
  'A: and the stranger still holds its own row 999999 alone');

-- ======================= (B) obtain creates the partition under the parent it identified =========================
create schema b359s;
create table b359s.t (id bigint primary key, payload text);
insert into b359s.t select g * 10, 'real' from generate_series(1, 99) g;
call pgpm.transmute('b359s.t', 'id', 1000, p_paused => true, p_obtain => 1);
insert into b359s.t values (1500, 'frontier');
select 'b359s.t'::regclass::oid as b_parent \gset
select is((select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = :'b_parent'::oid),
  array['0', '1000'], 'LIVENESS: B: the table has its monolith and [1000, 2000), and obtain owes it [2000, 3000)');

select dblink_exec('h359', 'begin') as b1 \gset
select x as b_seen from dblink('h359', 'select count(*)::text from b359s.t') as t(x text) \gset
select dblink_send_query('r359', format('select pgpm.obtain(%s::oid::regclass)', :'b_parent')) as b2 \gset
select ok(pg_temp.waits_for(:'b_parent'::oid, 'AccessExclusiveLock'),
  'LIVENESS: B: obtain waits for ACCESS EXCLUSIVE on the parent''s oid to create the partition, behind the reader');
select dblink_exec('h359', 'alter schema b359s rename to b359s_aside') as b3 \gset
select dblink_exec('h359', 'create schema b359s') as b4 \gset
select dblink_exec('h359', 'create table b359s.t (id bigint, payload text) partition by range (id)') as b5 \gset
select o as b_squat from dblink('h359', $$select 'b359s.t'::regclass::oid$$) as t(o oid) \gset
select dblink_exec('h359', 'commit') as b6 \gset
select coalesce(string_agg(x, ','), 'no row') as b_ret from dblink_get_result('r359', false) as t(x text) \gset
select dblink_error_message('r359') as b_err \gset
select count(*) as b_drained from dblink_get_result('r359', false) as t(x text) \gset
select ok(:'b_squat'::oid <> :'b_parent'::oid,
  'LIVENESS: B: the parent''s name denotes the stranger''s partitioned table once the reader commits');

select is(:'b_ret'::text, '1', format('B: obtain created one partition (%s)', :'b_err'));
select is((select count(*)::int from pg_inherits where inhparent = :'b_squat'::oid), 0,
  'B: the stranger''s partitioned table took no partition');
select is((select array_agg(p.lo || ':' || (i.inhparent = :'b_parent'::oid) order by p.lo::numeric)
             from pgpm.part p left join pg_inherits i on i.inhrelid = p.child_oid
            where p.parent_table = :'b_parent'::oid),
  array['0:true', '1000:true', '2000:true'],
  'B: the managed table''s new [2000, 3000) is recorded with the oid of a partition of the managed table');
select is((select count(*)::int from pgpm.part where parent_table = :'b_squat'::oid), 0,
  'B: and nothing is recorded under the stranger''s oid');
select is((select array_agg(id order by id) from b359s_aside.t where id >= 1000), array[1500::bigint],
  'B: the managed table still serves its row 1500');

-- ======================= (F) _detach_reap finalizes the abandoned detach it identified ===========================
create schema f359s;
create table f359s.t (id bigint primary key, payload text);
insert into f359s.t select g * 10, 'real' from generate_series(1, 50) g;
call pgpm.transmute('f359s.t', 'id', 1000, p_obtain => 3);
select 'f359s.t'::regclass::oid as f_parent \gset
select child_name as f_child, child_oid as f_child_oid from pgpm.part where parent_table = :'f_parent'::oid and lo = '2000' \gset

-- tests/198's recipe: a holder on the parent (pruned to its monolith) parks a concurrent detach in its wait phase,
-- and the detacher's session dies there, which leaves the partition pending, abandoned
select dblink_exec('h359', 'begin') as f1 \gset
select x as f_held from dblink('h359', 'select count(*)::text from f359s.t where id < 1000') as t(x text) \gset
select dblink_connect('x359', format('dbname=%s user=postgres', current_database())) as x \gset
select pid as x_pid from dblink('x359', 'select pg_backend_pid()') as t(pid int) \gset
select dblink_send_query('x359', format('alter table f359s.t detach partition f359s.%I concurrently', :'f_child')) as f2 \gset
select ok(pg_temp.parked(:'f_parent'::oid::regclass, :x_pid), 'LIVENESS: F: the detach set its pending flag and parked');
select pg_terminate_backend(:x_pid) as f_term \gset
select ok(pg_temp.gone(:x_pid), 'LIVENESS: F: the detacher''s session has died');
select dblink_exec('h359', 'commit') as f3 \gset
select dblink_disconnect('x359') as f4 \gset
select is((select array_agg(i.inhrelid) from pg_inherits i where i.inhparent = :'f_parent'::oid and i.inhdetachpending),
  array[:'f_child_oid'::oid], 'LIVENESS: F: exactly the [2000, 3000) partition is left pending detach, abandoned');
select max(id) as f_mark from pgpm.log \gset

-- the reader of the pending partition: FINALIZE's ACCESS EXCLUSIVE waits behind it
select dblink_exec('h359', 'begin') as f5 \gset
select x as f_read from dblink('h359', format('select count(*)::text from f359s.%I', :'f_child')) as t(x text) \gset
select dblink_send_query('r359', 'select pgpm._detach_reap()') as f6 \gset
select ok(pg_temp.waits_for(:'f_child_oid'::oid, 'AccessExclusiveLock'),
  'LIVENESS: F: the reap waits for ACCESS EXCLUSIVE on the pending partition''s oid, behind the reader');
select dblink_exec('h359', 'alter schema f359s rename to f359s_aside') as f7 \gset
select dblink_exec('h359', 'create schema f359s') as f8 \gset
select dblink_exec('h359', 'create table f359s.t (id bigint, payload text) partition by range (id)') as f9 \gset
select dblink_exec('h359', format('create table f359s.%I partition of f359s.t for values from (2000) to (3000)', :'f_child')) as f10 \gset
select dblink_exec('h359', $$insert into f359s.t values (2222, 'stranger')$$) as f11 \gset
select o as f_squat from dblink('h359', $$select 'f359s.t'::regclass::oid$$) as t(o oid) \gset
select o as f_squat_child from dblink('h359', format('select %L::regclass::oid', 'f359s.' || quote_ident(:'f_child'))) as t(o oid) \gset
select dblink_exec('h359', 'commit') as f12 \gset
call pg_temp.await_r();
select coalesce(string_agg(x, ','), 'no row') as f_ret from dblink_get_result('r359', false) as t(x text) \gset
select dblink_error_message('r359') as f_err \gset
select count(*) as f_drained from dblink_get_result('r359', false) as t(x text) \gset
select ok(:'f_squat_child'::oid <> :'f_child_oid'::oid,
  'LIVENESS: F: the partition''s name denotes the stranger''s partition once the reader commits');

select is(:'f_ret'::text, '1', format('F: the reap finalized one detach (%s)', :'f_err'));
select ok(not exists (select 1 from pg_inherits where inhrelid = :'f_child_oid'::oid),
  'F: the abandoned detach it identified is finalized: the partition is no longer the managed table''s');
select ok(exists (select 1 from pg_inherits where inhrelid = :'f_squat_child'::oid and inhparent = :'f_squat'::oid
                                              and not inhdetachpending),
  'F: the stranger''s partition is still attached to the stranger''s table');
select is((select array_agg(id order by id) from f359s.t), array[2222::bigint],
  'F: and the stranger''s table still serves its row 2222');
select is((select array_agg(action order by id) from pgpm.log where id > :f_mark and parent_table = :'f_parent'::oid),
  array['detach_reap'], 'F: logged detach_reap for the managed table, and no fail_detach_reap');

select dblink_disconnect('h359') as d1 \gset
select dblink_disconnect('r359') as d2 \gset
select * from finish();
