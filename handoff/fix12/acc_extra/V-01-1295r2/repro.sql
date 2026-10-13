-- V-01 (round 2 of PR #1295): adopt_partition's round-2 check ("asked again under the lock: it must still denote
-- p_child's oid ... Under the lock the answer is stable, because a rename takes ACCESS EXCLUSIVE") is defeated by a
-- SCHEMA rename, which takes no lock on any relation in the schema. LOCK TABLE resolves the schema-qualified name
-- once the lock is granted; when the name then denotes another relation S (the partition's schema renamed away and
-- another schema renamed into its name), the lock lands on S. LOCK TABLE then recurses into S's partitions and waits
-- on one of them, and while it waits the two schemas are renamed back, so by the time the check runs the name
-- denotes p_child again: the check passes with NO lock on p_child. The re-read by oid (READ COMMITTED, fresh)
-- finds it attached, the row is recorded, a DETACH of p_child commits before the call's transaction does, and
-- pgpm.part records a standalone table as a partition of the parent at commit: #1262's consequence, in READ
-- COMMITTED, against the header's "the relation judged attached is still attached when its row commits" and the
-- PR body's guarantee (2) "the lock it holds when it records a row is on the relation whose oid it records".
-- Deterministic: every step's order is set by a lock queue and witnessed in pg_locks, no sleeps.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(8);

create table public.v1 (id bigint primary key, payload text);
insert into public.v1 values (150, 'a');
call pgpm.transmute('public.v1', 'id', 100::bigint, p_obtain => 1, p_paused => false);
create schema s1;
create table s1.v1_x partition of public.v1 for values from (900) to (1000);
insert into public.v1 values (950, 'x'), (960, 'xx');
-- another schema holding a partitioned table of the same name, with one partition
create schema tmp;
create table tmp.v1_x (id bigint) partition by range (id);
create table tmp.v1_x_c partition of tmp.v1_x for values from (0) to (10);
select 's1.v1_x'::regclass::oid as x_oid, 'tmp.v1_x'::regclass::oid as s_oid, 'tmp.v1_x_c'::regclass::oid as c_oid \gset
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.v1'::regclass and child_oid = :x_oid)
          and exists (select 1 from pg_inherits where inhparent = 'public.v1'::regclass and inhrelid = :x_oid),
  'LIVENESS: s1.v1_x is attached and untracked');

create function pg_temp.waits(p_pid int, p_rel oid) returns boolean language plpgsql as $f$
begin
  for i in 1..500 loop
    if exists (select 1 from pg_locks where pid = p_pid and relation = p_rel and not granted) then return true; end if;
    perform pg_sleep(0.02);
  end loop;
  return false;
end $f$;

select format('dbname=%s user=postgres', current_database()) as conn \gset
select dblink_connect('a', :'conn') as a \gset
select dblink_connect('b', :'conn') as b \gset
select dblink_connect('c', :'conn') as c \gset
select x as a_pid from dblink('a', 'select pg_backend_pid()') as t(x int) \gset
-- c holds S's partition
select dblink_exec('c', 'begin') as x \gset
select dblink_exec('c', 'lock table tmp.v1_x_c in access exclusive mode') as x \gset
-- b holds the partition and swaps the schemas, uncommitted
select dblink_exec('b', 'begin') as x \gset
select dblink_exec('b', 'lock table s1.v1_x in access exclusive mode') as x \gset
select dblink_exec('b', 'alter schema s1 rename to s1_old') as x \gset
select dblink_exec('b', 'alter schema tmp rename to s1') as x \gset
-- a (READ COMMITTED) calls adopt_partition on the partition, by oid; it waits for the partition's lock
select dblink_exec('a', 'begin isolation level read committed') as x \gset
select dblink_send_query('a', format('select pgpm.adopt_partition(%L, %s::oid::regclass)', 'public.v1', :x_oid)) as sent \gset
select ok(pg_temp.waits(:a_pid, :x_oid), 'LIVENESS: the call waits for the partition''s lock');
select dblink_exec('b', 'commit') as x \gset
-- the name s1.v1_x now denotes S: the lock lands on S, and LOCK TABLE recurses into S's partition, held by c
select ok(pg_temp.waits(:a_pid, :c_oid)
          and exists (select 1 from pg_locks where pid = :a_pid and relation = :s_oid and granted)
          and not exists (select 1 from pg_locks where pid = :a_pid and relation = :x_oid),
  'LIVENESS: the call holds S''s lock, none on the partition, and waits for S''s partition');
-- the schemas are renamed back (no relation lock needed), so the name denotes the partition again
select dblink_exec('b', 'begin') as x \gset
select dblink_exec('b', 'alter schema s1 rename to tmp') as x \gset
select dblink_exec('b', 'alter schema s1_old rename to s1') as x \gset
select dblink_exec('b', 'commit') as x \gset
select ok(to_regclass('s1.v1_x') = :x_oid::regclass, 'LIVENESS: s1.v1_x denotes the partition again');
select dblink_exec('c', 'commit') as x \gset
create temporary table call1 as
  select coalesce((select r from dblink_get_result('a', false) as t(r text)), '') || '|' || dblink_error_message('a') as r;
select count(*) as drained from dblink_get_result('a', false) as t(r text) \gset
select diag((select r from call1));
select ok((select r from call1) like '%is a partition of this table that pgpm.part had no row for%',
  'LIVENESS: adopt_partition recorded the partition (its transaction still open)');
select is((select count(*)::int from pg_locks where pid = :a_pid and relation = :x_oid),
          1, 'adopt_partition''s transaction holds a lock on the relation it recorded');
-- another session detaches the recorded partition while a's transaction is open
create temporary table det as select 'not tried'::text as outcome;
set lock_timeout = '2s';
do $$ begin
  execute 'alter table public.v1 detach partition s1.v1_x';
  update det set outcome = 'detached';
exception when lock_not_available then
  update det set outcome = '55P03';
end $$;
reset lock_timeout;
select dblink_exec('a', 'commit') as x \gset
select ok(exists (select 1 from pgpm.part where parent_table = 'public.v1'::regclass and child_oid = :x_oid),
  'LIVENESS: pgpm.part records the adopted relation after commit');
select is((select p.child_name || ' attached=' ||
                  exists (select 1 from pg_inherits i where i.inhparent = 'public.v1'::regclass and i.inhrelid = :x_oid)::text
             from pgpm.part p where p.parent_table = 'public.v1'::regclass and p.child_oid = :x_oid),
  'v1_x attached=true',
  'the relation pgpm.part records as adopted is still a partition of v1 when the row commits (detach: ' || (select outcome from det) || ')');
select dblink_disconnect('a'), dblink_disconnect('b'), dblink_disconnect('c');
select * from finish();
