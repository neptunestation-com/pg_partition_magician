## The defect (#1272, F4-02, Tier 4)

A retirement mark disowned because pgpm recorded no dispatch of its own (#705) is logged `retain_disown` with a remedy. The remedy said "once its detach is finished, drop the table by hand, or attach it back to the parent on its bounds", and `docs/reference.md`'s `retire` entry repeated it, adding "its `pgpm.part` row is kept". Typed as written, the `DROP` left that row attached and anchored to the oid of a relation that no longer exists. `retire()` refuses that as `fail_retain_identity` on every call, by design (#1038), so `status().retain_drop_failures` climbed for good and the row took a `retain_batch` slot on every tick. The document was wrong, not the refusal.

## The fix

- `pgpm._disown_retirement` (pgpm_core/install.sql), the only writer of `retain_disown`, now ends every method with the whole remedy: attach the table back on its bounds, or drop it and delete its `pgpm.part` row with it, spelled as the two statements to run, for example `drop table public.t_p...; delete from pgpm.part where parent_table = 'public.t'::regclass and child_name = 't_p...';`. The `DROP` names the relation the row records (by `child_oid`, schema-qualified, where it is now; a row with no `child_oid` falls back to `_child_nsp` plus the name). The parent is schema-qualified, never resolved through the search path. The method also says that the `DROP` alone leaves the row refused as `fail_retain_identity`.
- Sites covered: every path that disowns a mark goes through that function: the pass every `install.sql` run makes (`_disown_unvouched_retirements`, which drops its own partial copy of the old remedy), `retire()` (detached and pending), `_detach_reap` and `_retain_recall`. Tests cover the install pass and `retire()` (detached). `_detach_reap`, `_retain_recall` and `retire()`'s pending branch get the same text from the same function but are not tested separately.
- `docs/reference.md`: the `retire` entry gets a paragraph giving the whole repair with the example statements, the upgrade paragraph no longer gives the half-remedy, and the `retain_disown` row in the log-action table says what the method spells.
- Unchanged: the refusal of a partition dropped under its row (`fail_retain_identity`), and what gets disowned and when.

## Acceptance

- `tests/339_retain_disown_remedy_test.sql` (23 assertions). Parts A (install pass) and B (`retire()`, a parent in a non-public schema) each read the remedy out of the `retain_disown` row and run it as written: its `DROP`, plus its `DELETE` when the row gives one. They then show retention runs clean: nothing is logged for the disowned range, `retain_drop_failures` stays at 0, and the exact `pgpm.part` rows and parent rows survive. A LIVENESS witness shows retention went on to drop the next aged partition. Fails on base (9 of 23).
- Guard `bench/retain_disown_remedy.sh` (pgpm_perf380), a pgTAP wrapper in the shape of `bench/retain_recall_moved_parent.sh`.
- Mutation `retain_disown_remedy_keeps_row` removes the `DELETE` clause from the remedy. Against it the guard FAILS on defect checks, not LIVENESS (not ok 5, 9, 10, 11, 17, 20, 21). The mutant's remedy, typed as logged, drops the table and leaves the row, and both parts log `fail_retain_identity` twice for [100, 200), which is the issue's wedge.
- `tests/327` part C's remedy pattern follows the new wording (it still requires the remedy, now with both statements).

## Caveat about the reproduction

F4-02's `repro.sql` types the OLD remedy, `drop table` alone, and its LIVENESS 5 requires the method to say `drop the table by hand`. With the remedy fixed, LIVENESS 5 fails on this head (the method no longer gives the half-remedy). Its checks 7 and 8 still fail as well, because what it types is still only the `DROP`, and by design that leaves the row behind. So no remedy-text fix can make it pass unedited. `tests/339` is the reproduction with the remedy the head logs typed in, and it passes. On base it fails, and on the mutant it fails exactly as the issue describes.

Proof: `./test.sh 15 --channel=psql` PASS (gated); `check_quoted_splices.py` and `--selftest` PASS; `check_living_docs.sh` PASS; every mutation builds; `shellcheck` 0.11.0 clean on the new wrapper; `bash -n test.sh`; markdownlint 0.13.0 clean on CHANGELOG.md and docs/reference.md.

Closes #1272

🤖 Generated with [Claude Code](https://claude.com/claude-code)

