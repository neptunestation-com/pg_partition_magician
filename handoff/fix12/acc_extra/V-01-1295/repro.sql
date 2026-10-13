-- V-01: adopt_partition locks its partition BY NAME (`lock table %s`, p_child::text), not by oid. When another
-- session renames the partition away and creates a new table under the old name, committing while the call waits
-- on that name, LOCK TABLE re-resolves the name after the wait and locks the NEW standalone table, not p_child.
-- The re-read under the "lock" is by oid and READ COMMITTED (fresh), so it passes, and the row is recorded with no
-- lock held on the relation it records: a DETACH of it then commits before adopt_partition's transaction does,
-- and pgpm.part records a standalone table as a partition at commit, against the header's "the relation judged
-- attached is still attached when its row commits". All of it in READ COMMITTED, the level #1262's fix requires.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(6);

create table public.v1 (id bigint primary key, payload text);
insert into public.v1 values (150, 'a');
call pgpm.transmute('public.v1', 'id', 100::bigint, p_obtain => 1, p_paused => false);
create table public.v1_x partition of public.v1 for values from (900) to (1000);
insert into public.v1 values (950, 'x');
select 'public.v1_x'::regclass::oid as x_oid \gset
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.v1'::regclass and child_oid = :x_oid)
          and exists (select 1 from pg_inherits where inhparent = 'public.v1'::regclass and inhrelid = :x_oid),
  'LIVENESS: v1_x is attached and untracked');

select format('dbname=%s user=postgres', current_database()) as conn \gset
select dblink_connect('b', :'conn') as b \gset
select dblink_connect('a', :'conn') as a \gset
-- B renames the partition and creates a standalone table under its old name, transaction left open
select dblink_exec('b', 'begin') as x \gset
select dblink_exec('b', 'alter table public.v1_x rename to v1_x_old') as x \gset
select dblink_exec('b', 'create table public.v1_x (id bigint)') as x \gset
-- A (READ COMMITTED) calls adopt_partition on the partition, by oid; it waits on the name's lock
select dblink_exec('a', 'begin isolation level read committed') as x \gset
select dblink_send_query('a', format('select pgpm.adopt_partition(%L, %s::oid::regclass)', 'public.v1', :x_oid)) as sent \gset
select pg_sleep(1.5);
select ok(exists (select 1 from pg_stat_activity where query like 'select pgpm.adopt_partition%' and wait_event_type = 'Lock'),
  'LIVENESS: adopt_partition is waiting on a lock while the rename is uncommitted');
select dblink_exec('b', 'commit') as x \gset
select r as adopt_result from dblink_get_result('a') as t(r text) \gset
select count(*) as drained from dblink_get_result('a') as t(r text) \gset
select ok(:'adopt_result' like '%is a partition of this table%',
  'LIVENESS: adopt_partition recorded the renamed partition (A''s transaction still open)');
select is((select count(*)::int from pg_locks l join pg_stat_activity s on s.pid = l.pid
            where l.relation = :x_oid and s.query like 'select pgpm.adopt_partition%'),
          1, 'adopt_partition''s transaction holds a lock on the relation it recorded');
-- a third session detaches the recorded partition while A's transaction is still open
set lock_timeout = '3s';
do $$ begin
  execute 'alter table public.v1 detach partition public.v1_x_old';
exception when lock_not_available then null;
end $$;
reset lock_timeout;
select dblink_exec('a', 'commit') as x \gset
select ok(exists (select 1 from pgpm.part where parent_table = 'public.v1'::regclass and child_oid = :x_oid),
  'LIVENESS: pgpm.part records the adopted relation after commit');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.v1'::regclass and inhrelid = :x_oid),
  'the relation pgpm.part records as adopted is still a partition of v1 when the row commits');
select dblink_disconnect('a'), dblink_disconnect('b');
select * from finish();
