---
name: pass5-review
description: Pass 5 review DONE 2026-10-01 (pinned 47a293a): 27 findings (2 T1) in 22 groups #723-#744, 12 known-open re-finds commented, recall 8/9 (read-caught 6/7, S5 bench-guard seed missed), precision 0.80, record PR #745 MERGED 2026-10-01; fix phase DONE (see fix5-phase); where the work dir and claims live
metadata:
  type: project
---

Pass 5 ran 2026-10-01 02:33Z to 02:59Z in session 679cc592 (the same session that landed the prep PRs #719 to #722),
after the user typed `/review-pass 47a293a... 9 fresh-surface, identity-names, contracts-vs-docs, tests-pass-wrong-reason,
upgrade-install, concurrency`. Budget adopted from the plan ("same as pass 3"): 10 finders (F1-F8 opus, F9 = S1 and
F10 = S8 on fable), one verifier per candidate (opus, medium). Measured: 2,366,352 finder tokens + 1,509,595 verifier
tokens = 3,875,947; 26 min hunt-to-last-verdict (faster than pass 4's 32).

**Result:** 59 claims, 20 seed hits, 39 candidates, 27 findings (T1 2: #723 regrain reconcile writes by name, #724
loosened retention never recalls an armed detach; T2 4: #725 set_partition_tz vs uncommitted obtain, #726 19-digit
orphan guard, #727 SET SCHEMA wedges lifecycle, #728 NDJSON signer encoding; T3 14 #729-#738; T4 3 #739-#741; T5 3
#742-#744), 12 known-open re-finds (commented with repros on #634 #635 #640 #706 #707 #708 #710 #711; #706/#708/#635
got their FIRST built reproductions; #707 and #710 got corrections: data loss, and "nothing lost" is wrong), 0 fell.
Precision 0.80 (1.00 counting re-finds). Recall 8/9: suite-caught 2/2 (S2 tests/172, S9 timescale 22+25), read-caught
6/7; MISSED S5 = bench/untransmute_race.sh identity assertion weakened to a count (lens tests-pass-wrong-reason; F7 ran
out of budget before bench/). Model split: F9 (fable, S1) found 6 new T3 and 0 seeds; F1 (opus, S1) 4 seeds, 0 new.

**Record:** docs/reviews/2026-10-01.md + pass-history row, PR #745, MERGED 2026-10-01 (main 84afbe0) on the user's
say-so; the fix phase is [[fix5-phase]]. Work dir: scratchpad `679cc592-.../scratchpad/pass5/` (tree, claims/ with every
repro and repro.verified.sh for F10-01, classified.json, verdicts.json, sealed.json + seeds/ (7 novel patches),
groups.json, issues/filed.json, notes.md, tokens.json, agents.tsv/verifiers.tsv). closure.sh for the fix phase reads
pass5/claims. Harnesses were brought down at the end.

**Pass 5 owes:** (1) fix phase DONE 2026-10-01 (PRs #746-#764, record #777, see [[fix5-phase]]); (2) seeds catalogued in #776 (S1 S3 S6 S8 S9; S4 identical to #749's mutation; S5 has no mechanical guard, #775); (3) pass 6 lens rotation: at least 3 of 6 must differ again (unused lately: time and zones, boundary arithmetic, operator error, failure injection, resource cliffs); give bench/ guards their own slice under tests-pass-wrong-reason (the S5 blind spot); pin main after #777 (ae5dddc) or a release.

**How to apply:** the stopping criteria are NOT met (T1 = 2, 9 → 7 → 7 → 2 across passes 2-5); pass 6 must pin the
fix-phase result. See [[pass5-plan]] for the plan this executed and [[pass4-review]] for the previous shape.
