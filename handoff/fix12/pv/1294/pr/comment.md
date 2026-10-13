## Per-PR adversarial verification of `f96b180` (base `b76002e`)

**Landing: clear.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1261 acceptance (F3-03): _regrain_copy_make makes each copy LIKE the parent INCLUDING CONSTRAINTS, which turns a NOT VALID CHECK on the parent into a validated one on the copy, so a row written before the CHECK (which the table still serves) fails every copy batch (23514): regrain()/regrain_history() raise and auto-regrain logs skip_regrain on that child every tick with capture and the TRUNCATE refusal left on, where the copy should carry the parent's NOT VALID CHECK as NOT VALID (as #633 does for NOT VALID foreign keys) and regrain should complete | yes | yes | `regrain_copy_validates_not_valid_check`: yes; `regrain_drift_compares_not_valid_check`: yes; `regrain_drift_excuses_validated_copy_check`: NO |  |

### Closing claim

**holds**: (1) Other entry points: _regrain_copy_make is the only maker of regrain copies (regrain_step at 8374, and the probe in _regrain_fresh_copy_drift at 6617), and regrain_step's swap at 8599 is the only ATTACH of a regrain copy. regrain(), regrain_history(), regrain_step and auto-regrain (maintain) all go through it. The other core LIKE ... INCLUDING CONSTRAINTS site, the transmute cutover (10984), refuses a NOT VALID CHECK in its preflight (_transmute_refuse_uncarried_constraints, #730), which is documented. The ATTACH at 4135 re-attaches a detached retirement partition, which keeps its own NOT VALID constraint and copies no rows. untransmute makes no LIKE copy. uninstall.sql has no copy path. (2) Upgrade or resume path, measured on pgpm_prv-15: base install, a NOT VALID CHECK that row 150 violates, regrain_step ran prepared, copied:99, then died 23514 on every tick (S1's copy holds the CHECK validated). Installing the head over that state and ticking on gave restarted:1, the copy ticks, then swapped:10. Row 150 is still served, and the log shows regrain_restart naming the copy's validated up_no_bad, then copy_swap_drop. So the body's sentence 'A run that was wedged by this defect is unwedged the same way' holds. The scheduled path is the same regrain_step. The drift check runs before the reconcile, the copy and the swap on every tick, so a wedged copy phase reaches it. (3) The body's guarantees: the mid-run CHECK (test B), the copy that holds the CHECK validated after a drop and re-add (test C, restart, and the probe matches so it is not a refusal) and the swap's 'keeps it' arm (reachable only by a copy that matches by name, and a validated one is drift first) left no input I could break on 15. PostgreSQL 18's NOT VALID NOT NULL arm could not be run (this harness has 15 only). The body discloses pgpm_hypertable's from_hypertable LIKE copy (install.sql:1184) as not covered. It is a sibling mechanism outside the PR's claimed surface, and it cannot be built here: pgpm_prv-15 has no timescaledb. It is a lead to file, not a partial. (4) Mutations: regrain_copy_validates_not_valid_check and regrain_drift_compares_not_valid_check each restore the acceptance failure alone. regrain_drift_excuses_validated_copy_check does not, by design: it targets the drift rule's copy side (test part C, the wedge after a drop and NOT VALID re-add), a cousin defect the PR also fixes, and the body says so. (5) The CHANGELOG and reference.md entries add no refusal of a documented workflow. The only behaviour change an operator meets is one restart of an in-flight run.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 2 | seed_hit |  | REGRESSION (passes on the base, fails on this tree): _regrain_copy_make still makes every copy LIKE the parent INCLUDING CONSTRAINTS and drops nothing after it (the hunk at 6554-6561 is comment only), while _regrain_shape_drift now leaves the parent's NOT VALID CHECK out on the parent's side (6673), so on a parent holding a NOT VALID CHECK that NO row violates every copy reads as drift, the probe copy drifts too, and the resumed tick is refused on every tick ('a copy made from the parent now would differ from it too'): regrain_history raises and auto-regrain logs skip_regrain with capture and the TRUNCATE refusal left on the source until regrain_cancel, where the base regrained it (the old drift check compared both sides by expression) and the body says it completes without a restart. |
| `P1-02` | 2 | seed_hit |  | The defect of #1261 is still present (fails on the base and on this tree): _regrain_copy_make's LIKE ... INCLUDING CONSTRAINTS gives the copy the parent's NOT VALID CHECK validated and no statement after the LIKE drops it (only the comment at 6554-6561 says it is dropped), so the first old row the parent still serves fails the copy batch with 23514 (regrain_history raises; auto-regrain skip_regrain every tick with capture and the TRUNCATE guard left on until regrain_cancel); the swap's pre-ATTACH add (8565-8582) and the drift exclusion (6673) are never reached, and the body's guarantee ('copies every row the parent serves, rows written before the constraint included') does not hold. Same root cause as P1-01. |

### Seed witness

- S1 in `pgpm_core/install.sql` (regrain_copy_validates_not_valid_check): **found**

### Coverage and budget

- P1: 13 of 13 units read (1.00)
- surface: 6 file(s), 13 unit(s) in the ledger (touched units, their callers, touched files)
- budget: P1 finder ~144k tokens (13/13 units), claims verifier ~77k; acceptance F3-03; seed = the PR's mutation regrain_copy_validates_not_valid_check (caught by P1 as P1-01 and P1-02); upgrade path over a wedged base run exercised by V

🤖 Generated with [Claude Code](https://claude.com/claude-code)
