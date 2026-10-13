## Per-PR adversarial verification of `d337c3e` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- V-01: regression with no verdict yet (unverified is not clear)

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1272 acceptance (F4-02): retain_disown's logged remedy (install pass _disown_unvouched_retirements; docs/reference.md retire: 'drop the table by hand ... its pgpm.part row is kept') leaves the attached pgpm.part row anchored to a dropped oid, so every later retire()/retain() logs fail_retain_identity for that range and status().retain_drop_failures climbs for good (and the row takes a retain_batch slot every tick); the remedy should also delete the row, or retire() should forget a disowned row whose relation the operator dropped | yes | yes | `retain_disown_remedy_keeps_row`: yes |  |

### Closing claim

**holds**: Tried: (1) every writer of retain_disown in the head: pgpm._disown_retirement is the only one, called from _disown_unvouched_retirements (install pass), retire() detached and pending branches, _detach_reap and _retain_recall; pgpm_archive, pgpm_hypertable and uninstall.sql have no retain_disown or retiring_at path; the archive message at install.sql:5342 already names the DELETE; no doc (guide, runbook, reference, README) still gives the half-remedy. (2) Upgrade/install pass and retire() covered by tests/339; reap and recall use the same function. (3) The body's sentences: the remedy names the relation by child_oid, schema-qualified, the parent quoted inside %L; 'Deleting the row after the fact stops the refusals' checked live (DROP alone, a retain(), then the DELETE: retention clean afterwards). (4) The mutation retain_disown_remedy_keeps_row puts back THIS defect: the rebuilt ACC-01 (repro.verified.sql: reads the remedy out of the retain_disown row, types every statement as logged, the pre-fix prose read as its DROP; asserts no fail_* for [100,200), retain_drop_failures not climbing, retain_batch=1 slot reaching [200,300), exact surviving ids) FAILS on base (not ok 8-11: fail_retain_identity, failures 3 > 1, slot taken, 250 not retired), PASSES on head (11/11), FAILS on the mutant (not ok 8-11, same), liveness 1-7 passing on all three. The original ACC-01 fails on head only because it types the old half-remedy and pins the old wording in LIVENESS 5: the fix changing what it observes, not a failure to fix. (5) No contract change refuses a documented workflow. One new claim on the PR's surface, not the issue's consequence: V-01 (Tier 4, regression): the remedy now also goes into _retain_recall's retain_disown, for a partition retention no longer reaches after set_retain lengthened the policy; there 'attach it back so retention retires it' is false and the spelled DROP, typed as logged, destroys rows the policy in force keeps (passes on base, which logged no remedy on that path; fails on head and mutant).

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 4 | seed_hit |  | pgpm._disown_retirement's retain_disown remedy still spells the DROP alone ('or drop it: drop table X;'; v_parent_q is computed and never used), so the remedy typed as logged drops the table and leaves its pgpm.part row anchored to a gone oid, and every later retain()/retire() logs fail_retain_identity for [100, 200) while status().retain_drop_failures climbs (#1272 unfixed); the PR body, docs/reference.md's retire entry and log-action row, tests/339 (fails 7 of 23 on this tree) and tests/327 part C all say the method spells the DELETE of the row beside the DROP |
| `V-01` | 4 | regression | unverified | PR #1303 writes the drop remedy ('drop table X; delete from pgpm.part ...', and 'attach it back ... so retention retires it') into EVERY retain_disown row through pgpm._disown_retirement, including the one _retain_recall logs (install.sql ~4148) for a partition retention NO LONGER REACHES after the operator lengthened retain with set_retain. For that partition both halves are false: retention will not retire it if attached back, and the spelled DROP destroys rows the policy in force keeps. Typed as logged, the remedy drops rows 150 and 160 that retain '1000' keeps. On the base the recall path's retain_disown named no remedy, so this is new with the PR (regression, misleading logged remedy). |

<details><summary><code>V-01</code> regression: tails</summary>

base:
```
(1 row)
                                             ok                                             
--------------------------------------------------------------------------------------------
 ok 7 - the remedy does not promise that retention retires a partition it no longer reaches
(1 row)
 finish 
--------
(0 rows)
```
head:
```
--------------------------------------------------------------------------------------------------------
 not ok 7 - the remedy does not promise that retention retires a partition it no longer reaches        +
 # Failed test 7: "the remedy does not promise that retention retires a partition it no longer reaches"
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 7
(1 row)
```

</details>

### Seed witness

- S1 in `pgpm_core/install.sql` (retain_disown_remedy_keeps_row): **found**

### Coverage and budget

- P1: 12 of 12 units read (1.00)
- surface: 7 file(s), 12 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 1: P1 ~90k tokens (12/12 units), claims verifier ~88k; acceptance F4-02 rebuilt by the claims verifier to type the remedy as logged (fails base, passes head, fails mutant); seed caught; BLOCKED on V-01, a regression: the whole remedy is written into _retain_recall's disown row too, where the lengthened policy keeps the partition and the drop it spells destroys kept rows; fixer round 2 in progress

🤖 Generated with [Claude Code](https://claude.com/claude-code)
