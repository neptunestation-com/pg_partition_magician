## The defect (#1261, pass 12 F3-03)

`pgpm._regrain_copy_make` made each regrain copy `LIKE <parent> INCLUDING CONSTRAINTS`, and `LIKE` gives the copy every
`CHECK` of the parent as a **validated** one, a `NOT VALID` one included. A row written before that `CHECK`, which the
parent still serves, then failed every copy batch of its sub-range with 23514: `regrain()` and `regrain_history()`
raised, and a `regrain_step` run failed on every tick with capture and the `TRUNCATE` refusal left on the source until
`regrain_cancel`. #633 leaves the parent's `NOT VALID` foreign keys off the copy for this reason; its `NOT VALID`
`CHECK`s were not. On PostgreSQL 18 a `NOT VALID` `NOT NULL` behaves the same way (measured on 18: `LIKE` gives the
copy a validated `NOT NULL`, and a null row fails with 23502), so the fix covers it with the same mechanism.

## The fix (`pgpm_core/install.sql`)

Three sites, one mechanism, modelled on how #633 handles a `NOT VALID` key:

1. **`_regrain_copy_make`** (the one routine that makes both the real copies and `_regrain_fresh_copy_drift`'s probe
   copy): after the `LIKE`, it drops from the still-empty copy each `CHECK` the parent holds enforced and `NOT VALID`
   (matched by name) and, on 18, each `NOT VALID` `NOT NULL` (matched by column name, since `LIKE` may give it a new
   name). A `NOT ENFORCED` `CHECK` (18) reads `convalidated = false` too, refuses nothing, and is left as `LIKE`
   made it.
2. **The swap in `regrain_step`** (the only place a regrain copy is attached, reached by `regrain()`,
   `regrain_history()`, `regrain_step` and auto-regrain alike): after the residual reconcile and the existing #633
   key loop, and just before each `ATTACH`, it adds each such constraint to the copy `NOT VALID` under the parent's
   name. This checks no row, and `ATTACH` adopts it under the parent's `NOT VALID` one without a scan. Verified on 15
   and 18: without it `ATTACH` fails with `child table is missing constraint` / `must be marked NOT NULL`. A copy that
   already holds the `CHECK` by name (or a `NOT NULL` on the column) keeps it.
3. **`_regrain_shape_drift`**: a parent `CHECK` that is enforced and `NOT VALID` is left out on the parent's side,
   and so is a column's `NOT NULL` when it comes from a `NOT VALID` `NOT NULL` constraint, because no copy is made
   with them. The copy's side is **not** excused, unlike #633's keys. A copy holding the `CHECK` validated (made while
   the parent's was, before someone dropped it and re-added it `NOT VALID`) is drift and restarts the run. Before
   this change it passed the drift check, which compares expressions, and then refused, on every tick, a row made
   violating in between and reconciled into it (test part C reproduces that wedge on the base).

What it guarantees: a regrain of a parent holding an enforced `NOT VALID` `CHECK` (or a `NOT VALID` `NOT NULL` on 18)
copies every row the parent serves, rows written before the constraint included, through `regrain()`,
`regrain_history()` and `regrain_step` (and so auto-regrain). This holds whether the constraint existed before the
run or was added mid-run. Every fine child ends up holding the constraint `NOT VALID`, inherited from the parent, and
refuses a new violating write.

Upgrade note: a run already in flight whose copies hold such a `CHECK` validated reads as drift after the upgrade and
restarts once (the probe copy matches, so it is a restart, not a refusal). A run that was wedged by this defect is
unwedged the same way.

## Acceptance

- The issue's reproduction (F3-03 `repro.sql`, unchanged): fails 4 and 6 on the base and on the mutant
  `regrain_copy_validates_not_valid_check`, and passes 6/6 on this head.
- `tests/331_regrain_not_valid_check_test.sql` (28 assertions; part D runs on 18 and skips before it):
  (A) `regrain_history` over two old violating rows in two sub-ranges; (B) `regrain_step` with the `CHECK` added
  mid-run (a copy made before it, a row made violating through the reconcile, one copied after it), with no restart;
  (C) a copy made with the `CHECK` validated, then the parent's re-added `NOT VALID` with a row violating it: restarts
  once and swaps; (D) PostgreSQL 18 `NOT VALID` `NOT NULL`. Every assertion names the rows and the fine child that
  serves each. Fails 13 on the base (15), 16 on the base (18); passes on 15, 17 and 18 at this head.
- Guard `bench/regrain_not_valid_check.sh` (`pgpm_perf369`), a pgTAP wrapper over tests/331. It FAILS (on defect
  assertions, not LIVENESS) against each of its three mutations:
  - `regrain_copy_validates_not_valid_check`: the pre-fix `_regrain_copy_make`, no drop after the `LIKE` (parts A,
    B, C; D on 18).
  - `regrain_drift_excuses_validated_copy_check`: the plausible-but-wrong drift rule that excuses the copy's side
    by name as #633 does for keys (part C).
  - `regrain_drift_compares_not_valid_check`: the drift check without the parent-side exclusion (parts A, B, C).

## Local proof

`scripts/review/gate.sh ... ./test.sh 15 --channel=psql`: PASS. `python3 scripts/check_quoted_splices.py`: PASS.
Every mutation in `bench/mutations/` builds. `bash -n test.sh`: OK. `shellcheck` 0.11.0 (current stable) on the new
guard: clean. `bench/throws_pinned.sh`, `bench/liveness_witness_labels.sh`, `bench/wrapper_premise_rule.sh`: PASS.
`scripts/check_living_docs.sh`: PASS. markdownlint-cli2 0.13.0 on `CHANGELOG.md` and `docs/reference.md`: 0 errors.

## Not covered

`pgpm_hypertable`'s `from_hypertable_copy` has its own `LIKE ... INCLUDING CONSTRAINTS` (it does not use
`_regrain_copy_make`), and as far as I can see from reading it, it does not refuse a `NOT VALID` `CHECK` on the
hypertable. I did not run that path or change it here.

Closes #1261

🤖 Generated with [Claude Code](https://claude.com/claude-code)

