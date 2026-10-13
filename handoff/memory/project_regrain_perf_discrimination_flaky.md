---
name: regrain-perf-discrimination-flaky
description: "regrain_no_delta_analyze can fail to discriminate on a GitHub runner while passing locally; rerun the job before suspecting the diff"
metadata:
  node_type: memory
  type: project
  originSessionId: 93fb0226-89ab-406f-9393-8c9a443119bb
  modified: 2026-09-22T19:40:00.034Z
---

`./test.sh discriminate`'s `regrain_no_delta_analyze` mutation (which strips the `analyze` on
regrain's trigger-populated delta table, so the planner should misplan a reconcile tick into a seq
scan) failed once on `ubuntu-latest` with:

```
FAIL  bench/regrain_perf.sh PASSED against its own defect: it does not discriminate
      PASS  reconcile tick does not scan the delta    0 <= 12500  (reconciled:3000, delta=50000 rows)
```

The delta scan counter read **0 against the mutant**: with stats missing the planner still chose an
index plan on that runner, so the guard had nothing to catch. Observed on PR #415 (2026-09-22,
[[project_pgpm_security_hardening_campaign]] #407); it was the first Perf-guard failure in 12 runs,
passed on a plain `gh run rerun --failed`, and the same mutation passed locally on macOS/Docker
against identical code.

**Why:** unlike the guard's forward direction (scan counters, expected exactly zero, deliberately
not a timing threshold), the DISCRIMINATION direction depends on the planner actually misplanning
without statistics. That is a cost-estimate decision and it varies with the runner, so it is not
protected by the "no timing thresholds" reasoning in `.github/workflows/perf.yml`'s header.

**How to apply:** if this specific mutation reports "does not discriminate", rerun the job before
suspecting the diff -- and confirm the diff's blast radius first. `regrain_perf.sh` exercises
`regrain_step`'s reconcile only. Not yet filed as an issue; if it recurs, it deserves one (the fix
is probably to make the mutant's misplan deterministic rather than planner-dependent). Compare
[[project_restore_fk_lock_flaky]], a different guard with a different, already-filed defect.
