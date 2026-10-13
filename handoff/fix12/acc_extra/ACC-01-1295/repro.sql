-- F4-03 (rebuilt by the PR #1295 claims verifier: assertion 3 pins pgpm's refusal, not one message's spelling).
-- F4-03: adopt_partition judges "attached, not pending" through the TRANSACTION snapshot, before and after its lock.
-- Under REPEATABLE READ a caller whose snapshot predates a DETACH that has since committed reads the partition as
-- still attached at both checks (the second, after SHARE UPDATE EXCLUSIVE on the partition, reads pg_inherits
-- through the same old snapshot), so adopt_partition records a table that is no longer a partition of the parent.
-- retire() and _archive_hold_partition ask pg_partition_ancestors (the catalog as of the lock) for exactly this.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(5);

create table public.f4a (id bigint primary key, payload text);
insert into public.f4a values (150, 'a');
call pgpm.transmute('public.f4a', 'id', 100::bigint, p_obtain => 1, p_paused => false);
-- an attached partition pgpm.part has no row for: what adopt_partition exists to record
create table public.f4a_extra partition of public.f4a for values from (900) to (1000);
insert into public.f4a values (950, 'kept by the operator');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.f4a'::regclass and lo = '900')
          and exists (select 1 from pg_inherits where inhparent = 'public.f4a'::regclass
                        and inhrelid = 'public.f4a_extra'::regclass),
  'LIVENESS: f4a_extra is attached and untracked');
select format('dbname=%s user=postgres', current_database()) as conn \gset

begin isolation level repeatable read;
select 1;   -- the transaction snapshot is taken here
-- another session detaches the partition and commits, before adopt_partition is called
select dblink_exec(:'conn', 'alter table public.f4a detach partition public.f4a_extra');
select ok(not exists (select 1 from pg_partition_ancestors('public.f4a_extra'::regclass) a
                       where a.relid = 'public.f4a'::regclass),
  'LIVENESS: as of the catalog, f4a_extra is no longer a partition of f4a when adopt_partition is called');
-- verifier (PR #1295): the contract is that the call REFUSES (pgpm's own refusal, whichever one: the
-- membership refusal or, since #1262, the isolation refusal before it) and records nothing. The pattern still
-- excludes a foreign error (it must be pgpm's raise), and assertion 5 pins that nothing was recorded.
select throws_like($$ select pgpm.adopt_partition('public.f4a', 'public.f4a_extra') $$,
  'pg_partition_magician: %',
  'adopt_partition refuses a table the parent no longer holds');
commit;

select ok(not exists (select 1 from pg_inherits where inhrelid = 'public.f4a_extra'::regclass),
  'LIVENESS: the detach committed: f4a_extra is a standalone table');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.f4a'::regclass and child_name = 'f4a_extra'),
  'pgpm.part records no row for a table that is not a partition of f4a');
select * from finish();
