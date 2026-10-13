# F6 null results (pass 12, slice S6)

Claims: F6-01 (Tier 1, scripts/archive_partition_whole.sql), F6-02 (Tier 3, from_hypertable_copy key conname).

## fresh surface

- #1158 copy lock: read every drain and drain step and the cutover for lock order. Each drain transaction takes
  ROW EXCLUSIVE on the copy before it reads the delta or the source (drain_delta locks in the loop before the
  residual EXISTS, the step locks again; drain_appends locks before its watermark read and again after every
  COMMIT; the steps lock before reading the source). What precedes the lock (_from_hypertable_check_names,
  _refuse_filtered_reads = row_security_active, _from_hypertable_scratch_follow = catalog reads plus a GRANT only
  when a writer changed) takes no lock on the source or delta, so a drain blocked behind the cutover's SHARE holds
  nothing the ACCESS EXCLUSIVE wants. The "neither can deadlock" text held on reading. After the swap a waiting
  drain's `lock table <rel>_pgpm_dest` re-resolves the name and fails 42P01, as documented.
- #1241 snapshot wait in the cutover: written_xid is set by every chunk batch and drain step (pure delete
  included), reset to null by _scratch_record on a re-run copy (so a re-run copy over an emptied hypertable waits
  for every older snapshot, conservative), and null for an upgraded copy (every snapshot older than the swap
  transaction waited for). The wait sits after the SHARE on the copy and the baseline read, before the index
  pre-builds and the source lock. A drain blocked behind the SHARE takes its snapshot after the last write, so it
  is not listed (it is listed and refused at once only if an unrelated transaction older than written_xid is
  running, which is a refusal, not a pass). Held.
- #1057 delta by record anywhere: drains, cutover, uninstall all use _scratch_rel; capture writes by oid. Held.
- #1118/#1138 _from_hypertable_check_arguments: ran from_hypertable on a timestamp(0) dimension with anchor
  '2000-01-01 00:00:00.5+00': refused before the copy (no m3_pgpm_dest). Held.
- Install head: scratch.written_xid, part.detach_dispatched_oid, config.regrain_written_xid add-columns, the
  upgrade_adopted_anchor block, child_oid / monolith_oid backfills, the scratch backfill from comments
  (copy and delta, '_pgpm_delta' = 11 chars, fn by derived name), the dropped_fk backfills, the
  warn_grid_off_unit block at line 7560. Held on reading. NOT read: the module-level do-blocks at core lines
  4545, 4729, 4846, 4856, 5608, 6048 and 6863 and _disown_unvouched_retirements (line 3584 call), out of budget.
- scripts/archive_partition_whole.sql: F6-01. The comments describe both #1159 halves; the code has neither.

## time and zones

- _from_hypertable_ctl_text (ISO pinned, column type kept), _ts_text for chunk bounds and the handoff anchor,
  _from_hypertable_check_frontier's naive read as UTC wall time: held on reading.
- IntervalStyle iso_8601 session ran from_hypertable end to end: partition_step stored as 'P1D' (core's
  rendering, parses back anywhere), names and grid as under postgres style. Held.
- The script's resume watermark goes through _max_hi_native and covered_hi through _native_text. Held on reading.

## boundary arithmetic and types

- _from_hypertable_check_names (octet_length > 63 over four suffixes), _from_hypertable_tmp_name fallback,
  _from_hypertable_past (NULL watermark, inclusive keyed form), drain_appends_step tie-inclusive bound and
  greatest(p_batch - 1, 0) offset, _snapshot_wait's age() comparisons against written_xid or own xid. Held.
- from_hypertable_time_estimate: p_copy_mibps 'NaN' raises a raw 'interval out of range' (the `<= 0` guard does
  not catch NaN) and 'Infinity' returns 00:00:00. Observed, not claimed: an informational sizing function.

## operator error

- Second from_hypertable_copy, copy re-run with p_track_changes toggled (delete of delta/fn records when not
  tracking), drain before the copy (refuses naming from_hypertable_copy), cutover without a copy: read, held.
- Drain called after the cutover on the now-partitioned table: refuses "found no copy to drain -- run
  from_hypertable_copy first", a remedy the preflight then refuses ("is not a hypertable"). Cosmetic, not claimed.

## failure injection

- Cutover: every refusal before the swap's COMMIT rolls the catch-up and pre-builds back; the incoming-FK records
  and pgpm.handoff are written inside the swap transaction. Held on reading.
- uninstall.sql refusal: the refusal block drops nothing; see H5 for the client that carries on past errors.

## contracts versus documentation

- docs/reference.md from_hypertable* entries read against the code: argument rules, drains' lock order, the
  wait and its limit, the 42P01 after the swap, the copy's key adopted rather than rebuilt (broken: F6-02).
- Script header vs code: broken (F6-01). uninstall header: held under --single-transaction.

## Hypotheses (no reproduction)

- H1 (contracts): from_hypertable_cutover carries retention only from `config->>'drop_after'` of the
  policy_retention job. A TimescaleDB retention policy made with `drop_created_before` (2.13+) has no drop_after,
  so p_retain stays null and the migrated table is registered with no retention, against "a carried-over
  drop_chunks retention policy is auto-translated into pgpm's retain". Not buildable here: the harness image is
  the Apache edition, which refuses add_retention_policy.
- H2 (fresh surface, F6-02's sibling): F6-02 needs the incoming key's pg_constraint row to precede the primary
  key's in a seqscan. The repro forces it with a RENAME CONSTRAINT; in a long-lived database any free space in
  pg_constraint's earlier pages (pgpm's own install drops and re-adds constraints) can place it so with no rename.
- H3 (failure injection): from_hypertable_cutover with p_predrain => false on a tracking copy: a REPEATABLE READ
  snapshot taken after the copy's last write and after an UPDATE of a copied row reads the copy's old version of
  that row after the swap (the under-lock reconcile is invisible to it). This is the documented last-mile window,
  but with p_predrain => false it spans every change since the copy, not "since the last pre-drain batch".
- H4 (operator error): a hand drain_appends_step / drain_delta_step called inside a client transaction that has
  already read the hypertable holds ACCESS SHARE on it while it queues behind the cutover's SHARE on the copy,
  and the cutover's ACCESS EXCLUSIVE then waits on it: a deadlock the detector breaks (one side errors), against
  "neither can deadlock the other". The step itself takes no source lock first; the caller's transaction does.
- H5 (failure injection): uninstall.sql run without --single-transaction and without ON_ERROR_STOP: the regrain
  sweep block (regrain_cancel, capture function and delta drop) commits before the refusal block refuses, so a
  refused uninstall has already cancelled every in-flight regrain while pgpm stays installed. The header says the
  script "REFUSES and drops nothing" in that case.
- H6 (operator error): _surface_prepare drops a declared function whose installed shape cannot be replaced; a
  GRANT EXECUTE an operator gave a monitoring role on it (pg_shdepend, not pg_depend) is not counted as a
  dependant and is lost by the drop-and-recreate, while the section header says CREATE OR REPLACE keeps grants.
  Needs an older install's shape of pgpm.status() to reproduce.

## Round 2

- Built: H6 as F6-03 (Tier 3, older-install state, shape 5). Over an install whose pgpm.status() has the earlier
  result (no regrain_to), re-running install.sql drops and recreates it, and the operator's REVOKE EXECUTE FROM
  PUBLIC and GRANT EXECUTE TO a monitoring role are gone (PUBLIC can execute it again). _surface_unreplaceable
  counts pg_depend dependants only, never the ACL. Repro run: fails on the tree.
- Not attempted, H1: not buildable in this harness (the Apache edition refuses add_retention_policy).
- Not attempted, H2: it is F6-02's precondition (catalog order) without the rename, which no fixture can
  pin deterministically. F6-02 already covers the mechanism.
- Not attempted, H3: it is the documented last-mile window of the snapshot wait, with a wider span under
  p_predrain => false. A reproduction would show documented behaviour, not a broken contract.
- Not attempted, H4: the deadlock needs the caller's own transaction to read the hypertable before it calls a
  drain step. The detector breaks it by erroring the drain's transaction, and the cutover goes on. Nothing is
  lost, and the trigger is the caller's ordering, so it is weak as a claim.
- Not attempted, H5: the uninstall header prescribes --single-transaction, and under that invocation the
  refusal holds. Outside it, the loss is in-flight regrain copy work only. It is weak relative to the budget.
