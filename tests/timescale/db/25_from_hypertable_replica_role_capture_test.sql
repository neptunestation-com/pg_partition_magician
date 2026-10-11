-- A replica-role write during the online window was silently reverted by the tracking cutover (issue #654).
--
-- from_hypertable_copy(p_track_changes => true) captures changes with an ordinary row trigger, and an
-- ordinary trigger does not fire under session_replication_role = replica (a logical-replication apply
-- worker, a loader silencing triggers). The core closes the same gap for regrain's capture trigger with
-- ENABLE ALWAYS (#450), but TimescaleDB refuses ENABLE ALWAYS on a hypertable ("hypertables do not
-- support enabling or disabling triggers") and on each chunk ("operation not supported on chunk tables"),
-- so that lever does not exist here. The conservation check (#460) sees an INSERT or DELETE that bypassed
-- the trigger, because the counts differ; an UPDATE changes no count, so the swap installed the copy's
-- stale row and the committed update was gone, with no error and no log row.
--
-- The fix is a refusal, anchored on MVCC rather than on the trigger: the copy records the xmin horizon of a
-- snapshot taken before any chunk is read, so a source row version older than it was necessarily copied,
-- and under the lock the cutover requires every row version at or past it to be present, identically, in
-- the reconciled destination. One that is not was written without firing the trigger, and the swap is
-- refused, naming how many and the first key.
--
-- WHAT THE HARNESS ALLOWS, same constraint as tests/timescale/db/17 and 20: a refusing cutover must be
-- wrapped by throws_like, and a cutover that WRONGLY proceeds dies at its own COMMIT inside the wrapper and
-- rolls back into the state a refusal leaves. The discriminator is the refusal's message (the count of
-- unmatched rows AND the key of the one it names), and the state assertions after it are invariants and
-- marked so. p_predrain => false in the refusing parts so no per-batch COMMIT is reached inside throws_like.
--
-- LIVENESS: every refusing part first proves the conditions for the defect were present. The copy holds
-- the stale value, the source holds the replica-role one, the delta holds the ORIGIN write's key and not
-- the replica write's (so the trigger is alive and the replica write evaded it), and the two sides hold the
-- same number of rows (so the count check is blind to it and cannot be what refuses). Part C is the
-- positive side: rows written during the window by origin writes, including ones the online drain has
-- already reconciled and deleted from the delta, must NOT trip the new check.
select plan(29);

-- A keyed hypertable of 72 rows over three daily chunks, v = 'r' || dev. Deterministic values, so a
-- reverted row reads as exactly its copied value.
create or replace function mk_rr(p_name text) returns void language plpgsql as $$
begin
  execute format('drop table if exists %I cascade', p_name);
  execute format('create table %I (ts timestamptz not null, dev int not null, v text, primary key (dev, ts))', p_name);
  perform create_hypertable(p_name, 'ts', chunk_time_interval => interval '1 day');
  execute format($i$insert into %I select timestamptz '2026-09-01 00:00+00' + g * interval '1 hour', g, 'r' || g
                    from generate_series(0, 71) g$i$, p_name);
end $$;

-- ================= PART A: one replica-role UPDATE of a copied row; the cutover refuses =================

select mk_rr('rr_a');
call pgpm.from_hypertable_copy('rr_a', 'ts', true);

-- the online window: an ordinary update (dev 7) and one under replica role (dev 8)
update rr_a set v = 'origin-update' where dev = 7;
set session_replication_role = replica;
update rr_a set v = 'replica-update' where dev = 8;
reset session_replication_role;

select is((select v from rr_a_pgpm_dest where dev = 8), 'r8',
  'LIVENESS: (A) the copy holds dev 8 at its copied value');
select is((select v from rr_a where dev = 8), 'replica-update',
  'LIVENESS: (A) the source holds the replica-role update of dev 8');
select is((select array_agg(distinct dev) from rr_a_pgpm_delta), array[7],
  'LIVENESS: (A) the delta logged the origin update (dev 7) and never saw the replica-role one (dev 8)');
select is((select count(*) from rr_a), (select count(*) from rr_a_pgpm_dest),
  'LIVENESS: (A) both sides hold the same number of rows, so the count check alone cannot see the update');

select throws_like(
  $$ call pgpm.from_hypertable_cutover('rr_a', 'ts', interval '1 day', p_predrain => false) $$,
  'pg_partition_magician: from_hypertable_cutover(rr_a) refusing to swap: 1 source row%changed during the online window without firing the change-capture trigger%first key (8,%',
  'A: the cutover refuses the swap, naming one unmatched row and its key (dev 8)');

-- invariants of the rolled-back cutover (a mutant that ran on to its COMMIT would leave the same state)
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'rr_a'), 1,
  'A invariant: the source is still a hypertable');
select is((select string_agg(dev || '=' || v, ',' order by dev) from rr_a where dev in (7, 8)),
  '7=origin-update,8=replica-update',
  'A invariant: the source still holds both updates');
select ok(to_regclass('public.rr_a_pgpm_delta') is not null and to_regclass('public.rr_a_pgpm_dest') is not null,
  'A invariant: the tracking apparatus and the copy are intact for a re-run');

-- ================= PART B: the same, with no horizon recorded; every row is verified =================
--
-- A delta built by a release before this fix carries no horizon. The cutover then verifies EVERY source
-- row rather than trusting an anchor it does not have, so the refusal is the same.

select mk_rr('rr_b');
call pgpm.from_hypertable_copy('rr_b', 'ts', true);
select ok(obj_description('public.rr_b_pgpm_delta'::regclass, 'pg_class') like 'pgpm from_hypertable horizon %',
  'LIVENESS: (B) the copy recorded its horizon on the delta');
comment on table rr_b_pgpm_delta is null;
select is(obj_description('public.rr_b_pgpm_delta'::regclass, 'pg_class'), null,
  'LIVENESS: (B) the horizon is gone, as on a delta an older release built');

set session_replication_role = replica;
update rr_b set v = 'replica-update' where dev = 50;
reset session_replication_role;

select is((select v from rr_b_pgpm_dest where dev = 50), 'r50', 'LIVENESS: (B) the copy holds dev 50 at its copied value');
select is((select count(*)::int from rr_b_pgpm_delta), 0, 'LIVENESS: (B) the delta never saw the replica-role update');

select throws_like(
  $$ call pgpm.from_hypertable_cutover('rr_b', 'ts', interval '1 day', p_predrain => false) $$,
  'pg_partition_magician: from_hypertable_cutover(rr_b) refusing to swap: 1 source row%first key (50,%',
  'B: without a horizon the cutover still refuses, naming dev 50');
select is((select v from rr_b where dev = 50), 'replica-update', 'B invariant: the source still holds the update');

-- ================= PART C: origin writes, drained or not, and a replica write the delta covers =================
--
-- Every row written during the window has an xmin past the horizon, so every one of them is checked. The
-- check must pass them all: the ones the online drain reconciled and then DELETED from the delta (a check
-- that asked "is this key in the delta" would refuse those), the residual the lock reconciles, and a
-- replica-role update of a key an origin write had already dirtied, which the reconcile re-reads from the
-- source and so carries forward. Asymmetric: 2 inserted, 1 deleted, 3 updated.

select mk_rr('rr_c');
call pgpm.from_hypertable_copy('rr_c', 'ts', true);

-- first wave, drained online
update rr_c set v = 'drained-update' where dev = 3;
insert into rr_c values (timestamptz '2026-09-03 23:30+00', 1001, 'drained-insert');
call pgpm.from_hypertable_drain_delta('rr_c', 'ts');
select is((select count(*)::int from rr_c_pgpm_delta), 0,
  'LIVENESS: (C) the online drain reconciled the first wave and emptied the delta');
select is((select v from rr_c_pgpm_dest where dev = 3), 'drained-update',
  'LIVENESS: (C) the drain carried dev 3''s update into the copy');

-- second wave, left for the lock
update rr_c set v = 'origin-update' where dev = 20;
delete from rr_c where dev = 40;
insert into rr_c values (timestamptz '2026-09-02 12:30+00', 1002, 'late-insert');
set session_replication_role = replica;
update rr_c set v = 'replica-after-origin' where dev = 20;
reset session_replication_role;
select is((select array_agg(distinct dev order by dev) from rr_c_pgpm_delta), array[20, 40, 1002],
  'LIVENESS: (C) the delta holds the second wave''s origin keys (20, 40, 1002) for the lock to reconcile');

call pgpm.from_hypertable_cutover('rr_c', 'ts', interval '1 day', p_paused => false);

select is((select relkind::text from pg_class where oid = 'rr_c'::regclass), 'p',
  'C: the cutover completed and the table is partitioned');
select is((select v from rr_c where dev = 3), 'drained-update', 'C: the drained update survived');
select is((select v from rr_c where dev = 1001), 'drained-insert', 'C: the drained insert survived');
select is((select v from rr_c where dev = 20), 'replica-after-origin',
  'C: the replica-role update of a key the delta held survived the reconcile');
select is((select count(*)::int from rr_c where dev = 40), 0, 'C: the deleted row stayed deleted');
select is((select v from rr_c where dev = 1002), 'late-insert', 'C: the late insert survived');
select is((select v from rr_c where dev = 8), 'r8', 'C: an untouched row kept its copied value');
select is((select count(*)::int from rr_c), 73, 'C: 72 copied + 2 inserted - 1 deleted');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'rr_c'), 0,
  'C: the hypertable was torn down');
select ok(to_regclass('public.rr_c_pgpm_delta') is null, 'C: the tracking apparatus was cleaned up');

-- ================= PART D: the append-only path is untouched =================
--
-- Without tracking there is no horizon and no delta; the cutover is exactly the #460 one.
select mk_rr('rr_d');
call pgpm.from_hypertable_copy('rr_d', 'ts');
select is(to_regclass('public.rr_d_pgpm_delta'), null, 'LIVENESS: (D) no tracking apparatus');
call pgpm.from_hypertable_cutover('rr_d', 'ts', interval '1 day', p_paused => false);
select is((select count(*)::int from rr_d), 72, 'D: the append-only cutover conserved all 72 rows');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
