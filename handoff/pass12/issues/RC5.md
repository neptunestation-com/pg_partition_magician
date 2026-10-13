title: adopt_partition judges attachment and the pending flag through the caller's transaction snapshot, before and after its lock, and does not refuse a stricter isolation level (pass 12 RC5)

Tier: 3

Age: old | Lens: fresh surface

Found in adversarial review pass 12 at `bd55f84021fc4173034d156a41bc91a3f882560d`, root-cause group RC5: F4-03, F11-03.

## F4-03

- finder: F4
- location: `pgpm_core/install.sql:14025`
- lens: fresh surface
- tier: 3
- scenario: adopt_partition's attached/not-pending checks (before and after its SHARE UPDATE EXCLUSIVE on the partition) read pg_inherits through the transaction snapshot, so a REPEATABLE READ caller whose snapshot predates a committed DETACH records the detached table in pgpm.part as an attached partition; the header promises 'the relation judged attached is still attached when its row commits' and retire()/_archive_hold_partition ask pg_partition_ancestors (the catalog as of the lock) for this reason
- root cause (verifier): adopt_partition judges 'attached, not pending' from pg_inherits through the transaction snapshot, before and after its SHARE UPDATE EXCLUSIVE lock, so a REPEATABLE READ caller whose snapshot predates a committed DETACH records the detached table in pgpm.part; its header promises 'the relation judged attached is still attached when its row commits', and retire() (install.sql ~3726) asks pg_partition_ancestors as of the lock for exactly this case. Tier 3: acts when it should refuse, bookkeeping only, no rows lost (retire leaves an operator-detached child alone). Reproduced on both trees with the finder's repro unchanged; no open issue shares the mechanism.

Reproduction: `repro.sql`, the finder's, run unchanged by the verifier.

```sql
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
select throws_like($$ select pgpm.adopt_partition('public.f4a', 'public.f4a_extra') $$,
  '%is not a partition of%',
  'adopt_partition refuses a table the parent no longer holds');
commit;

select ok(not exists (select 1 from pg_inherits where inhrelid = 'public.f4a_extra'::regclass),
  'LIVENESS: the detach committed: f4a_extra is a standalone table');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.f4a'::regclass and child_name = 'f4a_extra'),
  'pgpm.part records no row for a table that is not a partition of f4a');
select * from finish();
```

## F11-03

- finder: F11
- location: `pgpm_core/install.sql:14023`
- lens: fresh surface
- tier: 3
- scenario: adopt_partition's attached check and its re-read under SHARE UPDATE EXCLUSIVE both read pg_inherits under the caller's snapshot, so in a REPEATABLE READ transaction whose snapshot predates another session's committed DETACH it records the detached table in pgpm.part as attached (the READ COMMITTED call on the same state refuses); it should re-read the catalog fresh after the lock, as the archive hold was fixed to (archive_hold_recheck_by_snapshot), or refuse a non-READ COMMITTED caller
- root cause (verifier): adopt_partition judges attachment (both the pre-lock check and the re-read under SHARE UPDATE EXCLUSIVE) through the caller's transaction snapshot and does not refuse a non-READ COMMITTED caller, so a REPEATABLE READ call whose snapshot predates a committed DETACH records the detached table in pgpm.part as attached, breaking the documented refusal of 'a p_child that is not attached to it' and the reference's 'the partition cannot be detached or dropped between the check and the row'; no isolation requirement is documented for adopt_partition while untransmute and transmute refuse stricter isolation and retire's docs promise the catalog as of its lock 'a caller in REPEATABLE READ included'. Reproduced on both trees by the finder's repro.sql unchanged (READ COMMITTED control refuses on the same state); the resulting row is the hand-detached state pgpm's #705 handling already leaves standing, so no loss: Tier 3. Not a re-find of any open issue.

Reproduction: `repro.sql`, the finder's, run unchanged by the verifier.

```sql
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
```

Acceptance: the reproduction(s) above fail on bd55f84021fc4173034d156a41bc91a3f882560d and must pass on the fixing commit; the fix carries a bench/ guard and a bench/mutations entry proven by ./test.sh discriminate.
