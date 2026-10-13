## The defect (#1259, F14-01)

`retire()` stamps `pgpm.part.retiring_at` before it dispatches a referenced partition's concurrent detach. #705 (PR #1250) taught `retire()`, `_detach_reap`, `_retain_recall` and the install's pass that a mark vouches for pgpm's own retirement only with the record of pgpm's dispatch (`pgpm.part.detach_dispatched_oid`, `_detach_dispatched`). The other readers of the mark still vouched for it by itself:

- `pgpm._part_built`: `or (p_retiring_at is not null and <the relation exists>)`, and through it `pgpm._part_detached_by_hand`;
- `pgpm._archive_hold_partition`: `or p_retiring_at is not null`.

So a partition whose dispatch failed (no `pg_cron`) and which the operator then detached by hand was, on the next `maintain()` tick (whose archive step runs before `retain()`), handed to the archive strategy and recorded as covered, in the same tick `retire()` disowned the mark (`retain_disown`). A strategy reading through the parent, as pgpm_archive's transports do, read none of its rows. When the operator took the documented remedy (attach it back so retention retires it), retention dropped it on that false coverage and rows 1, 2 and 15 were in neither the table nor the archive.

## The fix

One rule shared by the readers: the new `pgpm._retirement_vouched(p_parent, p_child_oid, p_retiring_at)`, which is `p_retiring_at is not null` AND `_detach_dispatched` for the row anchored at that oid (the record must name this relation). `_detach_dispatched` itself is unchanged, moved ahead of `_part_built` so the SQL body can call it. `_part_built` and `_archive_hold_partition` call `_retirement_vouched` where they used to test the mark alone.

What it guarantees: an anchored `pgpm.part` row whose relation is not (or no longer) a partition of its parent, and whose `retiring_at` mark carries no `detach_dispatched_oid` equal to that relation's oid, is read as detached by hand at every site that asks `_part_built`, `_part_detached_by_hand` or `_archive_hold_partition`:

- `_archive_step`: the candidate query and the hold (not handed to the strategy, no coverage recorded);
- `scripts/archive_partition_whole.sql`: the candidate query and the hold;
- `_enforce_write_blocks` (no write block goes on it);
- `maintain()`'s auto-regrain candidate scan, the regrain-source-detached reclaim and `progress().coarse_frozen`;
- `_part_built`'s other callers: `_cell_attached` and `_cell_walk_rows` (obtain, extend_to, maintain_obtain's back-off walk; these walk only from the frontier's cell, so a retired range is not normally reached), `status()` (n_partitions, coarse_partitions, newest_bound) and `progress().write_child`.

A mark WITH its record (pgpm's own retirement whose dispatched detach landed) still reads as pgpm's at every one of them, as before. An unanchored row (null `child_oid`) behaves as before. Readers of `retiring_at` this does not change, deliberately: `retire()`'s own one-detach-in-flight tiebreak (it asks only about attached or pending partitions), `status().retain_detaching` (a count), `adopt_partition`'s refusal (refuses any mark), `_retain_recall`'s prefilter, `pgpm.forget_missing`'s match of the detach job's command, and the sites #1250 already fixed.

No new column; the upgrade path is unchanged (installing over the base was checked).

## Acceptance

- The issue's reproduction (F14-01's `repro.verified.sql`): fails on the base (tests 6, 7, 9 not ok, every LIVENESS ok), passes on this head, and fails again on the mutant at 6, 7 and 9 with every LIVENESS ok.
- `tests/330_retirement_mark_needs_dispatch_test.sql` (21 assertions): A the reproduction's flow through `maintain()` (strategy handed `[20, 30)` alone, no ledger row for the operator's table, after the reattach ids 1, 2 and 15 archived before the drop); B the three predicates and the write-block step over one vouched mark, one with no record and one whose record names another relation (identity of which ranges are built, detached by hand, held, blocked); C `scripts/archive_partition_whole.sql`. 10 non-LIVENESS failures on the base, all LIVENESS green there.
- Guard `bench/retirement_mark_needs_dispatch.sh` (`pgpm_perf367`), mutation `retirement_mark_vouches_alone` (drops the record clause of `_retirement_vouched`, restoring the mark-alone rule at all reader sites while `retire()`'s own rule stays): the guard FAILS against it on 10 defect assertions, none of them LIVENESS.
- `tests/280` and `tests/307` part C simulate pgpm's own retirement by stamping the mark by hand; they now stamp `detach_dispatched_oid` too, as `retire()` does in the dispatch's transaction. Their assertions are unchanged. The two mutations anchored on `_part_built`'s changed line (`obtain_trusts_detached_cell`, `retiring_cell_forgotten`) are re-anchored to the new text with the same effect, and still fail their guard; the 13 `bench/retire_pending_detach.sh` mutations (several rewrite `_detach_dispatched`) still build, install and fail their guard.

## Proof run locally

- `./test.sh 15 --channel=psql` (through the gate): PASS (tests/330 21/21, tests/280 27/27, tests/307 50/50)
- `python3 scripts/check_quoted_splices.py` and `--selftest`: PASS
- every mutation in `bench/mutations/` builds; `mutate.py --list` OK
- `bash -n test.sh`; `shellcheck` 0.11.0 clean on the new guard
- `bench/liveness_witness_labels.sh`, `bench/throws_pinned.sh`: PASS
- `scripts/check_living_docs.sh`: PASS; `markdownlint-cli2@0.13.0` on CHANGELOG.md and docs/reference.md: 0 errors

Closes #1259

🤖 Generated with [Claude Code](https://claude.com/claude-code)

