# F9 null results (pass 12, slice S8a)

Claims: F9-01 (T1, untransmute without #1157's pending-detach refusal), F9-02 (T3, obtain/extend_to log no
fail_obtain_name), F9-03 (T3, restore_incoming_fks ignores its own five-minute park), F9-04 (T3, the lock budget's
fine count discounts aged sub-ranges an archive_fn makes regrain copy).

## fresh surface

- The snapshot wait (`_snapshot_wait`, `_regrain_snapshot_wait`): read the predicate (`age(backend_xmin) >=
  age(reference)`), the per-poll `pg_stat_clear_snapshot`, the direct-blocker pass (own-xid only), the chain refusal
  (recursive `pg_blocking_pids`, depth 16), the peer marker (advisory key 1885826423, objsubid 2) and the older/younger
  rule (this transaction always has an xid via `pg_current_xact_id`, so two peers cannot both read the other as
  "null, older"). `config.regrain_written_xid` is written by every copy batch that moved rows and every reconcile
  batch, never cleared at the swap; a later run that writes nothing reuses the old xid, but then its copies are empty,
  so nothing is protected wrongly. Held.
- `retire()`'s lock-then-read and the dispatch record, `_disown_unvouched_retirements` (pending null vs false),
  `_retain_recall`'s three arms, `_detach_reap`'s disown ahead of the FINALIZE: held by reading.
- `_archive_hold_partition`: ACCESS SHARE on the parent does not conflict with DETACH ... CONCURRENTLY's first
  transaction (SHARE UPDATE EXCLUSIVE on parent and partition), so the flag can be set after the hold. Built a
  two-session repro (maintain's archive step with a slow strategy reading through the parent, the detach started 2 s
  into it). The strategy still saw all 50 rows: PostgreSQL 15 keeps a partition visible to later statements of the
  same top-level statement after the flag commits (a standalone experiment confirmed: a function sleeping then
  counting saw 100 rows; the next top-level statement saw 0). So no coverage over unseen rows; no claim.
- The transmute cutover's forward-name block (`v_fwd_names`, `_transmute_names_present`, the 23505/42P07/42710
  handler, `_transmute_refuse_child_holders` after obtain): held by reading. With F9-02 present, obtain's skip of a
  held name is silent, but the refusal after obtain still fires in the up-front words.
- `_transmute_reap`'s re-read under ACCESS EXCLUSIVE with SKIP LOCKED and the PGPMR rollback: held.
- `restore_incoming_fks`: F9-03. `_fk_def_unvalidated`, `_regrain_copy_make`, `_regrain_fresh_copy_drift`: held.
- Hypertable: `_scratch_written` after every copy chunk and both drain steps; the cutover's SHARE on the copy, then
  baseline, then the wait, then ACCESS EXCLUSIVE; a drain blocked on the copy's SHARE with an old xmin is refused at
  once (chain rule), which is the documented outcome. Held.

## time and zones

- `_cell_walk_rows` casts `lo::timestamptz` only for ordering; bounds are `_ts_text` with offsets. Held.
- `_native_order_key`: an offset-less or DateStyle-shaped bound gets null (always a candidate), a BC bound (` BC`
  suffix) fails the regex and gets null. Held.
- `_naive_grid_zone_off`: see Hypotheses.
- `_time_unit_breach` casts `p_anchor::timestamptz`; every anchor pgpm stores comes through `_ts_text` with an
  offset. Held.

## boundary arithmetic and types

- `_regrain_fine_count`: F9-04. The cap (`p_cap + 1`) and the `2 * n > slots / 2` line read; the clamped first cell is
  counted (floor of p_lo). On the harness (64 x 100) the line is 1600 children.
- `_same_step`: months plus residual epoch; '1 month' vs '30 days' differ, '24 hours' vs '1 day' agree. Held as
  documented.
- `archive.to_s3`: page of exactly fetch_rows followed by an empty page switches to the NULL run; NULL run's cursor
  is (tableoid, ctid) only. Held.

## operator error

- `set_retain` refuses any tightening that reaches a partition (it blocked my own fixture; used transmute's p_retain).
- `set_regrain` re-stating a target in another spelling passes `_same_step`. Held.

## failure injection

- DETACH ... CONCURRENTLY interrupted by statement_timeout in its wait leaves the flag (used in F9-01). Against
  untransmute: F9-01. Against `retire()`: refused as skip_retain (read). Against `_detach_reap`: finalized, mark
  disowned first (read).

## contracts versus documentation

- obtain/extend_to: F9-02 (comment "so it is logged (#710)" over an empty branch; `_log_unbuilt_cell` is defined and
  never called).
- restore_incoming_fks: F9-03 (CHANGELOG #633 promises the park).
- untransmute: F9-01 (CHANGELOG/comment #1157 promises both gates; the comment sits over no call).

## Hypotheses

- `_naive_grid_zone_off` (install.sql ~7224): the header says a zone is on the column's clock when its offset is ZERO
  at every month's 1st, but the body compares each month's offset with 2000-01-01's, so a constant non-zero offset
  (Asia/Tokyo, Asia/Kolkata, America/Phoenix) reads as on the clock and neither `_regrain_step_shape` nor the
  install's `warn_grid_off_unit` flags such a grid. For a date key the registered anchor (zone midnight, off 00:00
  UTC) is refused first by `_time_unit_breach`, so the consequence is only a different message; for a timestamp key
  a fixed-offset lattice round-trips, so I found no failing regrain. A reproduction needs an older install's config
  (partition_tz 'Asia/Tokyo' on a naive key) and a regrain toward '1 day' or '1 hour' that then fails at the swap.
- `_detach_reap`'s disown (install.sql ~12003) matches the pgpm.part row by oid but asks `_detach_dispatched` and
  `_disown_retirement` by the CURRENT relname (r.crel); a partition renamed after pgpm stamped the mark has neither
  found by name, so a pending detach under an unvouched mark is finalized without the disown, leaving the mark under
  the old name. retire() then refuses by identity (fail_retain_identity), so no drop; unbuilt.
- `_archive_hold_partition`: a strategy that reads in a NEW top-level statement (an asynchronous exporter that is
  handed the range and reads later, or a strategy run via dblink in its own session) would not be covered by the
  "same statement still sees it" behaviour above; with such a strategy the post-hold DETACH ... CONCURRENTLY hides
  the partition and coverage is recorded over rows not read. Needs a dblink-based strategy fixture.

## Round 2

- Built F9-05 (Tier 1, fresh surface, sibling copy): building the `_archive_hold_partition` hypothesis led to its
  sibling, `scripts/archive_partition_whole.sql`. Its candidate query has no `_part_detached_by_hand` filter (#705), and
  it never calls `_archive_hold_partition` (#1159), although its comments say it does both. A table the operator
  detached by hand (still write-blocked) is handed to a strategy that reads through the parent. The strategy sees 0 of
  the table's 50 rows, coverage is recorded, and once the table is re-attached `retire()` drops it.
- Built F9-06 (Tier 3, time and zones) from the `_naive_grid_zone_off` hypothesis: a date grid registered in Asia/Tokyo
  by an older install (simulated by putting `config.partition_tz` and the `pgpm.part` bounds at Tokyo midnight). The
  same grid in America/New_York is refused, but `set_regrain(.., '1 day')` accepts the Tokyo one, and its first fine
  cell encodes as the empty date range [2025-01-01, 2025-01-01).
- Tried and not reproduced: a post-hold DETACH ... CONCURRENTLY under `_archive_step` itself. As in round 1, the
  strategy runs inside the step's statement and still sees the partition. A strategy that reads in its own session
  (dblink) was not built.
- Not attempted: `_detach_reap`'s disown by the current relname of a renamed partition. Its likely end is
  fail_retain_identity, not a drop.
