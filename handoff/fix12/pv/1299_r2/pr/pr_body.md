## The defect (#1259, F14-01)

`retire()` stamps `pgpm.part.retiring_at` before it dispatches a referenced partition's concurrent detach. #705 (PR #1250) taught `retire()`, `_detach_reap`, `_retain_recall` and the install's pass that a mark vouches for pgpm's own retirement only with the record of pgpm's dispatch (`pgpm.part.detach_dispatched_oid`, `_detach_dispatched`). The other readers of the mark still vouched for it by itself:

- `pgpm._part_built`: `or (p_retiring_at is not null and <the relation exists>)`, and through it `pgpm._part_detached_by_hand`;
- `pgpm._archive_hold_partition`: `or p_retiring_at is not null`.

So a partition whose dispatch failed (no `pg_cron`) and which the operator then detached by hand was, on the next `maintain()` tick (whose archive step runs before `retain()`), handed to the archive strategy and recorded as covered, in the same tick `retire()` disowned the mark (`retain_disown`). A strategy reading through the parent, as pgpm_archive's transports do, read none of its rows. When the operator took the documented remedy (attach it back so retention retires it), retention dropped it on that false coverage and rows 1, 2 and 15 were in neither the table nor the archive.

## Round 2: the converse state the per-PR verification found (V-01)

A mark WITH its record (pgpm's own dispatched detach, landed) on a partition archiving was configured for only after the mark was stamped (so `retire()`'s coverage gate never ran for its range): `_archive_hold_partition` vouched for it, the archive step handed the detached table to the strategy, the strategy read none of its rows through the parent, the range was recorded as covered with `rows_archived` 0, and `retire()` dropped the table. Pre-existing on the base, inside this PR's surface.

## The fix

1. One rule for "is this detached relation still pgpm's": the new `pgpm._retirement_vouched(p_parent, p_child_oid, p_retiring_at)`, which is `p_retiring_at is not null` AND `_detach_dispatched` for the row anchored at that oid (the record must name this relation). `_detach_dispatched` is unchanged, moved ahead of `_part_built` so the SQL body can call it. `_part_built` calls it where it used to test the mark alone.
2. `_archive_hold_partition` holds NO detached table, whatever its mark (refuse, not warn): the mark clause is gone, so it answers by `pg_partition_ancestors` alone. When the table it did not hold is pgpm's own retirement (`_detach_dispatched`), the new `pgpm._archive_unheld_retirement` gives the reason and the remedy: `_archive_step` logs it `skip_archive` over the partition's range on every tick it finds the table, and `scripts/archive_partition_whole.sql` returns it. A row with no recorded oid that carries a mark is asked by the relation its name resolves to. Nothing is recorded, so `retire()`'s coverage gate stays shut and it keeps the table. The remedy (attach it back on its bounds once it is no longer pending a detach) is typed from the log row in tests/330 part D and archives ids 1, 2 and 15 before `retire()` completes.

What it guarantees:

- An anchored `pgpm.part` row whose relation is not (or no longer) a partition of its parent, and whose `retiring_at` mark carries no `detach_dispatched_oid` equal to that relation's oid, is read as detached by hand at every caller of `_part_built` / `_part_detached_by_hand`: `_archive_step`'s and `scripts/archive_partition_whole.sql`'s candidate queries, `_enforce_write_blocks`, `maintain()`'s auto-regrain candidate scan, the regrain-source-detached reclaim, `progress().coarse_frozen`, `_cell_attached` and `_cell_walk_rows` (obtain, extend_to, maintain_obtain's back-off walk; these walk only from the frontier's cell), `status()` (n_partitions, coarse_partitions, newest_bound) and `progress().write_child`. A mark WITH its record still reads as pgpm's there, as before. An unanchored row (null `child_oid`) behaves as before at these sites.
- Neither archive path (`_archive_step`, `scripts/archive_partition_whole.sql`) hands a strategy a table that is not a partition of its parent as of the hold's lock, whatever its mark, so no coverage is recorded from a read through the parent that cannot see the table's rows.

Readers of `retiring_at` this does not change, deliberately: `retire()`'s one-detach-in-flight tiebreak (asks only about attached or pending partitions), `status().retain_detaching` (a count), `adopt_partition`'s refusal (refuses any mark), `_retain_recall`'s prefilter, `pgpm.forget_missing`'s match of the detach job's command, and the sites #1250 already fixed. I did not add a general "rows_archived 0 while the table holds rows" refusal: `rows_archived` is nullable by the published strategy contract and a strategy reading the partition itself reports its own count, so that would be a contract change; the hold makes the 0-row read through the parent unreachable for a detached table instead.

No new column; installing over the base was checked.

## Acceptance

- F14-01's `repro.verified.sql`: fails on the base (6, 7, 9; every LIVENESS ok), passes on this head, fails against `retirement_mark_readers_whole` at 6, 7, 9 with every LIVENESS ok. Against the single-clause `retirement_mark_vouches_alone` it passes: since round 2 the hold refuses the archive hand-off on its own, so the issue's archive defect needs both readers put back (the precedent is `archive_whole_unfiltered_and_unheld`).
- V-01's `repro.sql`: on the base it fails at 6 and 7. On this head assertion 6 (no 0-row coverage) passes; it fails at LIVENESS 5 ("retire() dropped the monolith") and at 7, because the reproduction presumes the drop and looks for rows 1, 2 and 15 only in the parent and the sink: the fix refuses the hand-off, so the table is kept, detached, with the rows in it (tests/330 part D asserts exactly that, then types the logged remedy and shows the rows archived before the drop). Against `archive_hold_vouches_detached_retirement` it fails at 6 and 7 with every LIVENESS ok.
- `tests/330_retirement_mark_needs_dispatch_test.sql` (31 assertions): A the F14-01 flow through `maintain()`; B the predicates over one vouched mark, one with no record and one whose record names another relation (which ranges are built, detached by hand, held, write-blocked); C `scripts/archive_partition_whole.sql`; D V-01 (the dispatch record stamped as `retire()` writes it, labelled fixture since the harness has no pg_cron; the detach run CONCURRENTLY as pg_cron would): not handed off, no ledger row, kept with ids 1, 2 and 15, `skip_archive` with the remedy, and the remedy as typed archives the rows before the drop. 17 non-LIVENESS failures on the base.
- Guard `bench/retirement_mark_needs_dispatch.sh` (`pgpm_perf367`), three mutations, each failing it on defect assertions (not only LIVENESS): `retirement_mark_vouches_alone` (part B), `archive_hold_vouches_detached_retirement` (parts B and D), `retirement_mark_readers_whole` (parts A to D).
- `tests/280` and `tests/307` part C simulate pgpm's own retirement by stamping the mark by hand; they now stamp `detach_dispatched_oid` too, as `retire()` does. Their assertions are unchanged. Mutations whose anchors moved (`obtain_trusts_detached_cell`, `retiring_cell_forgotten`, `archive_step_hold_skipped`, `archive_whole_hold_skipped`, `archive_whole_unfiltered_and_unheld`) are re-anchored with the same effect and still fail their guards; `archive_hold_unlocked`, `archive_hold_recheck_by_snapshot`, `archive_trusts_part_attached`, `archive_whole_trusts_part_attached`, `detached_by_hand_ignores_retiring_at` and the 13 `bench/retire_pending_detach.sh` mutations still fail theirs.

## Proof run locally

- `./test.sh 15 --channel=psql` (through the gate): PASS on head 356f52e7 (tests/330 31/31, tests/280, 307, 313, 325, 327 PASS)
- `python3 scripts/check_quoted_splices.py`: PASS; `check_archive_object_keys.py`, `check_archive_child_by_oid.py`: PASS
- every mutation in `bench/mutations/` builds; `mutate.py --list` OK
- `bash -n test.sh`; `shellcheck` 0.11.0 clean on the new guard
- `bench/liveness_witness_labels.sh`, `bench/throws_pinned.sh`: PASS
- `scripts/check_living_docs.sh`: PASS; `markdownlint-cli2@0.13.0` on CHANGELOG.md and docs/reference.md: 0 errors

Closes #1259

🤖 Generated with [Claude Code](https://claude.com/claude-code)

