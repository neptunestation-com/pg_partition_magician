# Null results, finder P1, PR #1299

## Lens: fresh surface

- `pgpm._retirement_vouched`: NOT held. The tree's body is the mark alone; claim P1-01 (Tier 1) carries the
  issue's flow and a direct predicate assertion. Everything below was probed with that defect present, so a
  behaviour that depends on the record-aware rule could only be observed as the same defect.
- `_detach_dispatched`: compared the moved definition with the base's in the diff: identical body, one
  definition in the tree (grep), defined before `_part_built` so a SQL-language caller resolves it. Held.
- The install's pass (`_disown_unvouched_retirements`) over an older install's state: a mark without a record
  on a detached partition (hand-stamped, as a pre-#1250 pgpm would leave it) is disowned by the pass
  (`retain_disown` logged over its range) and the row then reads as detached by hand, on this tree too, since
  the mark is gone. An attached mark with the job armed is given its record; without pg_cron nothing is
  armed, so a failed dispatch's mark on an attached partition stays a mark retire() will retry. Held.
- Readers of `retiring_at` the body says are unchanged: `retire()`'s tiebreak (joins pg_inherits by name,
  attached or pending only), `status().retain_detaching` (every mark), `adopt_partition`'s refusal (any mark),
  `_retain_recall`'s prefilter, `forget_missing`'s command match (line 13931/13962): all read the mark
  alone, as the body states. Held.
- Modules: `pgpm_archive/` and `pgpm_hypertable/` have no reader of `retiring_at`, `detach_dispatched_oid`,
  `_part_built`, `_part_detached_by_hand` or `_archive_hold_partition` (grep). The one copy outside the core
  is `scripts/archive_partition_whole.sql`, which asks both predicates (tests/330 C). Held.
- `_archive_step` ordering: candidate query (`_part_detached_by_hand`), identity, hold, reads, ledger; it runs
  before `retain()` in `maintain()`, which is why the disown and the archive land in one tick. Held as the
  body describes.
- tests/280 part C and tests/307 part C: pass on the mark-alone tree and would pass on the record-aware rule;
  they exercise the vouched direction only, and the negative lives in tests/330 B, which fails on this tree
  at 11/12/13/15/16 with its LIVENESS assertions green. tests/330 therefore discriminates the tree's rule.
- `bench/retirement_mark_needs_dispatch.sh`: reports an install failure as FAIL, counts assertions ran, and
  labels the zero-ran case LIVENESS. Held.

## Lens: identity and names

- `_retirement_vouched` is keyed by the row's anchor oid and `_detach_dispatched` by child_name; in `retire()`
  the identity check (name resolves to retiring_oid and child_oid) runs before either is asked, and the record
  is `v_child::oid` read from pg_inherits in the same transaction as the mark, so the two keys name the same
  relation on every path that writes them. Held (on the record-aware rule; on this tree the oid is not read).
- `_disown_unvouched_retirements` resolves the relation by `coalesce(child_oid, to_regclass(nsp.name))` and
  requires `c.relname = p.child_name`, so a row renamed by hand is skipped by the pass (pre-existing, #1250's
  surface, not this change). Not a claim: retire() refuses such a row on identity first.
- `_archive_hold_partition` locks `p_parent` by regclass text (format %s of a regclass), as before. Held.

## Hypotheses (no reproduction)

- On the record-aware rule, a mark WITH its record on a partition PENDING a concurrent detach pgpm dispatched
  (pg_cron's detach in its wait) still reads as built and held; a strategy reading through the parent in a new
  transaction would see none of its rows. Not reachable as a candidate in practice: the dispatch required
  `_archive_fully_covered`, and the write block has been on since; only a hand-removed block (coverage reset)
  could reopen it. Not built.
- `test.sh` was read only around the guard array; the rest of the file is outside the change.
