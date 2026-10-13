-- F11-03: adopt_partition judges "attached" under the caller's snapshot. Called in a REPEATABLE READ
-- transaction whose snapshot predates a DETACH that another session committed, both its catalog reads (the one
-- before the lock and the re-read under SHARE UPDATE EXCLUSIVE) see the partition still attached, so it records
-- in pgpm.part a relation that is not a partition of the parent when its row commits, against its header's
-- "the relation judged attached is still attached when its row commits". The same call in READ COMMITTED
-- refuses (the control). The archive hold was fixed for exactly this (archive_hold_recheck_by_snapshot); this is
-- the sibling.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(6);

create table public.f11a (id bigint primary key, payload text);
insert into public.f11a values (3, 'a'), (4, 'b'), (16, 'c');
call pgpm.transmute('public.f11a', 'id', 10::bigint);
select pgpm.extend_to('public.f11a', '60') is not null as extended \gset
insert into public.f11a values (27, 'd'), (52, 'frontier');
select child_name as p0 from pgpm.part where parent_table = 'public.f11a'::regclass and lo = '0' \gset
-- the stale-row repair state adopt_partition exists for: the partition attached, its pgpm.part row deleted
delete from pgpm.part where parent_table = 'public.f11a'::regclass and child_name = :'p0';
select to_regclass('public.' || :'p0')::oid as p_oid \gset
select pgpm._regrain_lock('public.f11a'::regclass);   -- the lock row exists, committed

select is((select count(*)::int from pg_inherits where inhparent = 'public.f11a'::regclass and inhrelid = :p_oid),
          1, 'LIVENESS: the partition is attached and pgpm.part has no row for it');
select dblink_connect('d', 'dbname=' || current_database()) as d \gset

begin isolation level repeatable read;
select count(*) as snap from pgpm.config \gset
-- another session detaches the partition and commits, after this transaction's snapshot was taken
select dblink_exec('d', format('alter table public.f11a detach partition public.%I', :'p0')) as detached \gset
select is((select x from dblink('d', format('select count(*)::int from pg_inherits where inhrelid = %s', :p_oid)) as t(x int)),
          0, 'LIVENESS: the detach committed before adopt_partition is called (seen from a fresh session)');
create temporary table rr_result as
  select (select pgpm.adopt_partition('public.f11a', ('public.' || :'p0')::regclass)) as r;
commit;

select is((select count(*)::int from pg_inherits where inhparent = 'public.f11a'::regclass and inhrelid = :p_oid),
          0, 'LIVENESS: at commit the relation is not a partition of public.f11a');
select is((select coalesce(string_agg(child_name || ' attached=' || attached, ','), 'none') from pgpm.part
            where parent_table = 'public.f11a'::regclass and child_oid = :p_oid),
          'none',
          'adopt_partition records nothing for a relation that is not a partition of the parent when its row commits');

-- control: the same call on the same state, in READ COMMITTED, refuses
delete from pgpm.part where parent_table = 'public.f11a'::regclass and child_oid = :p_oid;
select throws_like(format('select pgpm.adopt_partition(%L, %L)', 'public.f11a', 'public.' || :'p0'),
                   '%is not a partition of%',
                   'LIVENESS: in READ COMMITTED the same call on the same state refuses');
select is((select count(*)::int from pgpm.part where parent_table = 'public.f11a'::regclass and child_oid = :p_oid),
          0, 'LIVENESS: and records nothing');
select dblink_disconnect('d') as gone \gset
select * from finish();
