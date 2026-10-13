# F4 null results (pass 12, slice S4)

All 62 units of the slice were read in full before building. Two claims: F4-01 (T3, obtain/extend_to never log
fail_obtain_name; _log_unbuilt_cell has no caller) and F4-02 (T3, retain_disown's remedy leaves a permanent
fail_retain_identity wedge). Everything below was probed and held, by reading against the unit's own comments
unless marked "ran".

## fresh surface

- #1162 walk (`_cell_walk_rows`, `_cell_walk_step`, obtain, extend_to): checked that `p_covered` is true only when a
  passed BUILT row's hi is above the cell's lo and no passed dead row's hi is; a cell exactly at a built row's hi is
  not covered (strict `>`), a dead row spanning several cells keeps them all on the `_cell_attached` path; rows are
  read after extend_to's dry count has already forgotten the edge's dead row. Ran obtain and extend_to over a hole
  (F4-01 fixture): the walk built every nameable cell around the hole. Held apart from the missing log row.
- #705/#1250 retire(): ran the failed-dispatch path (no pg_cron in the database): mark stamped, no
  `detach_dispatched_oid`, `fail_retain_detach`; after a hand DETACH the install pass disowns it as documented.
  Read the lock-then-ask order (SHARE UPDATE EXCLUSIVE before pg_partition_ancestors), the pending branch's
  disown and skip_retain, and the referenced branch's re-stamp of the record on retry. Held.
- `_disown_unvouched_retirements`: attached marks get a record only when the job holds the exact command; pending
  and detached ones without a record are disowned; ran it (returns 1, logs retain_disown).
- `_retain_recall`: the detached branch now asks `_detach_dispatched` before re-attaching; the unarmed attached
  branch clears all three columns. Held.
- #1159 `_archive_hold_partition`: ACCESS SHARE on the parent, then the catalog as of the lock; a pending detach
  answers false. Held.
- #1163 `_over_retired_chunks`: the floor excludes only retired rows whose hi key is <= min attached lo key, and the
  native overlap test needs l.hi > m.lo >= floor, so nothing overlapping is excluded; an unkeyed attached lo drops
  the floor; an unkeyed ledger hi is always read. Held.
- #1160 `_backfill_chunk_oids`: identity anchors with ALWAYS, origin-only or absent block are attributed; adopted
  anchors and disabled/replica blocks are marked retired. Held on reading.
- #1164 forget_missing: chunk list written into the log row before the ledger delete. Held.
- #1239 adopt_partition: regrain lock, pending refusal before and after the lock (see hypothesis H3).

## time and zones

- `_native_order_key` (ran): the same epoch for an offset-carrying ISO text under DateStyle 'SQL, DMY', 'German',
  'ISO, YMD', 'ISO, DMY'; '+05:30' offsets and a five-digit year parse; BC and infinity texts get no key (always a
  candidate). Immutable marking is sound for the texts it keys.
- `_retain_horizon` / `_retain_boundary`: calendar part on the wall clock in partition_tz, time part on the instant;
  stable in the session zone. Held on reading.
- `_next_archive_chunk`: values rendered through `_ts_text` for aware columns, `::text` for naive ones parsed back in
  the same session. Held.
- `_archive_step` stores `_native_text(covered_hi)` in the session that checked it. Held.

## boundary arithmetic and types

- retain's candidate predicate `hi <= boundary` against retire's `not hi > boundary`: same half-open rule.
- `_archive_contract_breach`: strict lower bound, inclusive upper, id round trip through the base type. Held.
- extend_to dry count: edge cell counted when missing; `v_needed + v_edge > p_max` refuses before any DDL.
- obtain lock budget `2 * cost > slots / 2` and the ceiling exit on a type overflow. Held on reading.
- `_retain_nonnegative` refuses NaN and every negative field; set_retain's arm-from-null guard refuses a NaN that
  reached it anyway. Held.

## operator error

- set_obtain negative/null refused, 0 accepted (obtain then builds the frontier cell only; maintain_obtain's
  back-off threshold ceil(0/2) = 0 still bypasses for a hole in the frontier's own cell). Held.
- set_retain with wrong-unit text, negative, mixed-sign: refused. set_retain tightening refused (ran: hit it while
  building F4-02's fixture). Held.
- hand DETACH of a referenced partition under a failed-dispatch mark (ran): disowned, refused. The documented remedy
  then wedges (F4-02).
- retain_batch with a hand-detached or pending row at the head of the backlog: takes a slot on every call. Documented
  in reference.md (retire: "Until then it takes a retain_batch slot on every call"; "To end that, attach the table
  back ... or delete its pgpm.part row"), so not claimed.

## failure injection

- `_dispatch_detach` with no cron schema (ran): reason returned, logged fail_retain_detach, mark left without the
  record; the next call re-dispatches (attached) or disowns (detached). Held.
- `_detach_job_holds` returns false on any error: the only consumer stamps a record on true, so false is the safe
  direction (no record, later disown).
- `when others` in retain's per-partition loop, `_enforce_write_blocks`' per-child loop, `_archive_step`'s
  per-candidate loop and maintain's per-step blocks: each logs a prefixed skip with its range; a rolled-back
  subtransaction leaves coverage where it was. Held on reading.

## contracts versus documentation

- reference.md fail_obtain_name row and Partition naming promise a log row (F4-01, ran).
- reference.md retire: "drop the table by hand ... (its pgpm.part row is kept)" (F4-02, ran).
- retain_batch, retire, retain_disown, skip_retain wording against the code: match apart from the above.
- observe_window's `regrains` counts action 'regrain', which regrain() does write (copy_swap_drop). Held.

## Hypotheses (no reproduction built)

- H1 (retire, pending branch with a record): a partition pending pgpm's own dispatched detach (retiring_at and
  detach_dispatched_oid set, inhdetachpending true, its session dead) is not short-circuited: retire() goes on to
  `_install_write_block` and, on the referenced path, finds `v_child` by name in pg_inherits (a pending link is still
  listed) and re-dispatches `DETACH ... CONCURRENTLY`, which PostgreSQL refuses on an already-pending partition
  ("already pending detach ... use FINALIZE"). Whether the cron job then fails every tick until `_detach_reap`
  finalizes, and whether retire() logs anything for it, was not built.
- H2 (retain candidates): the disowned-then-dropped row of F4-02 and an identity-wedged row both stay in retain()'s
  candidate set, oldest first, so at retain_batch = 1 retention for the table stops behind them; the #1141 fix
  excluded the analogous retired-chunk-held rows from the candidates but not these.
- H3 (adopt_partition under REPEATABLE READ): the post-lock re-check reads pg_inherits.inhdetachpending through the
  transaction snapshot, not the catalog as of the lock (retire() uses pg_partition_ancestors for exactly this). A
  caller in REPEATABLE READ whose snapshot predates a DETACH ... CONCURRENTLY's first transaction can adopt a
  partition that is pending detach; build with a dblink session holding the snapshot.
- H4 (`_disown_unvouched_retirements` join): rows are joined on `c.relname = p.child_name`, so a marked partition
  renamed by hand (child_oid resolves, relname differs) is skipped by the install pass and keeps an unvouched mark;
  whether retire() then reaches it (its own by-name resolution fails the identity check first) was not built.

## Round 2

- H3 BUILT as **F4-03** (T3, fresh surface; long-surviving shapes 1 and 2): under REPEATABLE READ, a DETACH that
  commits after the caller's snapshot is invisible to both of adopt_partition's pg_inherits checks (the one after
  the partition lock included), and the detached table is recorded in pgpm.part (ran with dblink: the adopt_partition row is
  logged and `pgpm.part` holds the standalone table).
- H1 NOT BUILT: reaching "pending pgpm's own detach with the dispatch record" needs a successful dispatch, which needs
  pg_cron in the database (only `postgres` has it here) or a hand-written `cron` shim, which the verifier would
  rightly call the finder's own environment. Even when reached, the consequence is a re-dispatched DETACH ...
  CONCURRENTLY that the cron job fails on until `_detach_reap` (run ahead of every maintain_all tick) finalizes the
  detach. That is noise, not loss.
- H2 NOT BUILT: reference.md (retain_batch: "an unexpected drop failure at the head of the backlog defers everything
  behind it until it clears"; retire: a pending or hand-detached row "takes a retain_batch slot on every call")
  documents the stall behind a permanently failing row. The disowned-then-dropped row's share of it is F4-02's
  consequence.
- H4 NOT BUILT: a renamed marked partition skipped by the install pass is then refused by retire()'s and
  _retain_recall's by-name identity checks (fail_retain_identity), so nothing is dropped. That is a wedge with no
  loss, and its reproduction would add nothing beyond the identity-wedge behaviour the runbook already documents.
