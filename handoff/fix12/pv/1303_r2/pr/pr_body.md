## The defect (#1272, F4-02, Tier 4)

A retirement mark disowned because pgpm recorded no dispatch of its own (#705) is logged `retain_disown` with a remedy. The remedy said "once its detach is finished, drop the table by hand, or attach it back to the parent on its bounds", and `docs/reference.md`'s `retire` entry repeated it, adding "its `pgpm.part` row is kept". Typed as written, the `DROP` left that row attached and anchored to the oid of a relation that no longer exists. `retire()` refuses that as `fail_retain_identity` on every call, by design (#1038), so `status().retain_drop_failures` climbed for good and the row took a `retain_batch` slot on every tick. The document was wrong, not the refusal.

## The fix

`pgpm._disown_retirement` (pgpm_core/install.sql) is the only writer of `retain_disown`. When it disowns a mark it now checks one fact as of the call: does the retention policy in force reach the partition's range? It uses `retire()`'s own precondition, `hi` at or below `_retain_boundary`. It then writes the remedy that is true for that state, as statements to run:

- **Reached**: two options. Attach it back on its bounds (`alter table <parent> attach partition <child> for values from (...) to (...);`) so retention retires it. Or drop it AND delete its row with it (`drop table <child>; delete from pgpm.part where parent_table = '<parent>'::regclass and child_name = '<child>';`). The method also says that the `DROP` alone leaves the row refused as `fail_retain_identity`.
- **Not reached** (the table has no policy, or the range ends past the horizon): the `ATTACH` alone, plus "Do not drop it". Its rows are rows the policy keeps, so the method spells no `DROP` and no `DELETE`.
- **Not judged** (the horizon or the bounds could not be computed; the error is in the method): the `ATTACH`, and the `DROP` only in words, conditional on retention reaching the range.

How the statements name things:
- The child is the relation the row records by `child_oid`, schema-qualified where it is now. A row with no `child_oid` falls back to `_child_nsp` plus the name.
- The parent is schema-qualified, never resolved through the search path.
- The `ATTACH` bounds come from the grid's `_encode`, as `_retain_recall`'s own re-attach does.

Sites covered: every path that disowns a mark goes through this one function, and the state decides the remedy, not the path:
- `retire()` disowns only a partition that passed its horizon check, so it gets the reached remedy.
- `_retain_recall` disowns only a partition the policy no longer reaches, so it gets the attach-only remedy.
- The `install.sql` pass and `_detach_reap` can find either state, and get whichever is true.

The install pass's own partial copy of the old remedy is removed. Tests cover the install pass and `retire()` (reached) and `_retain_recall` (not reached). `_detach_reap` and `retire()`'s pending branch go through the same function and are not tested separately. The not-judged branch is not exercised by a test.

Docs: `docs/reference.md`'s `retire` entry now gives the three remedies with example statements. Its `set_retain` entry says a disowned recall gets the `ATTACH`, never a `DROP`. The `retain_disown` row of the log-action table says the same.

Unchanged: the refusal of a partition dropped under its row (`fail_retain_identity`), and what gets disowned and when.

## Round 2 (V-01)

The first cut wrote the drop remedy into every row, including `_retain_recall`'s. That row is logged after `set_retain` lengthened the policy, and typed as logged its remedy destroyed rows the policy in force keeps. V-01's `repro.sql` now passes on this head (7/7) and fails against `retain_disown_remedy_drops_unreached` (not ok 6 and 7).

## Acceptance

- `tests/339_retain_disown_remedy_test.sql` (34 assertions):
  - Parts A (install pass) and B (`retire()`, a parent in a non-public schema) read the remedy out of the `retain_disown` row and run its `DROP`, plus its `DELETE` when the row gives one. They then show retention runs clean: nothing is logged for the disowned range, `retain_drop_failures` stays at 0, and the exact `pgpm.part` rows and parent rows survive. A LIVENESS witness shows retention went on to drop the next aged partition.
  - Part C (`_retain_recall` after `set_retain '1000'`) asserts the row spells the exact `ATTACH` and no `DROP` or `DELETE`. It runs the drop remedy if the row gives one, and the `ATTACH` otherwise. It then shows rows 150 and 160 are served again under the very relation `pgpm.part` records, before and after later retention.
- Guard `bench/retain_disown_remedy.sh` (pgpm_perf380), a pgTAP wrapper in the shape of `bench/retain_recall_moved_parent.sh`.
- Mutations (the guard FAILS on defect checks, not LIVENESS, against each):
  - `retain_disown_remedy_keeps_row` removes the `DELETE` clause from the reached remedy (not ok 5, 9, 10, 11, 17, 20, 21). The typed `DROP` leaves the row behind, and both parts log `fail_retain_identity`, which is the issue's wedge.
  - `retain_disown_remedy_drops_unreached` forces the reach clause to true, which is this PR's first cut (not ok 28 to 31, 33). The typed `DROP` loses rows 150 and 160.
- `tests/327` part C's remedy pattern follows the new wording (it still requires the remedy, now with both statements).

## Caveat about the F4-02 reproduction

F4-02's `repro.sql` types the OLD remedy, `drop table` alone, and its LIVENESS 5 requires the method to say `drop the table by hand`. With the remedy fixed, LIVENESS 5 fails on this head. Its checks 7 and 8 still fail as well, because what it types is still only the `DROP`, and by design that leaves the row behind. So no remedy-text fix can make it pass unedited. `tests/339` parts A and B are the reproduction with the remedy the head logs typed in.

Proof:
- `./test.sh 15 --channel=psql` PASS (gated)
- `check_quoted_splices.py` and `--selftest` PASS
- `check_living_docs.sh` PASS
- every mutation builds
- `shellcheck` 0.11.0 clean on the new wrapper
- `bash -n test.sh`
- markdownlint 0.13.0 clean on CHANGELOG.md and docs/reference.md

Closes #1272

🤖 Generated with [Claude Code](https://claude.com/claude-code)

