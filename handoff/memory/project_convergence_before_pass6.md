---
name: convergence-before-pass6
description: "Convergence assessment written 2026-10-01 after the pass-5 fix phase, for the session that runs pass 6: the per-pass numbers, why pass 5 looks like the floor but is not two passes, the five tempering points (sliding precision, lens-shaped yield, fix phases manufacture surface, the known-open backlog incl. a Tier-1-shaped site, undefined capture-recapture so the earliest stop is after pass 8), the expectation for pass 6, and what makes its result trustworthy"
metadata:
  node_type: memory
  type: project
  originSessionId: a1867f7a-af19-41cd-9662-e9e517b1c564
  modified: 2026-10-01T18:31:20.265Z
---

Written at the user's request ("tell me how well we're doing on convergence") after the pass-5 fix phase closed
(main `ae5dddc`, see [[fix5-phase]]); the numbers are from the pass-history table in `docs/adversarial-review.md`
and were re-read from the file, not from memory. Verdict: **converging, not converged**. Pass 5 is the first pass
that looks like the floor; the stopping criteria need two consecutive zero-Tier-1 passes and pass 5 had two.

| pass | fresh surface | findings | Tier 1 | root-cause groups | precision | seed recall |
|---|---|---|---|---|---|---|
| 1 | release 0.6.0 | 76 | 25 | n/a | not measured | none |
| 2 | +30 commits | 49 | 7 | 27 | 1.00 | 1.00 |
| 3 | +34 | 55 | 9 | 39 | 0.92 | 1.00 |
| 4 | +33 | 32 | 7 | 28 | 0.86 | 1.00 |
| 5 | +76 | 27 | 2 | 22 | 0.80 | 0.89 (read-caught 0.86) |
| 6 | +25 commits / 105 files (the pass-5 fix phase) | 23 | 5 claims in 4 groups | 19 | 0.78 | 0.56 (read-caught 0.43) |
| 7 | +18 commits / 60 files (the pass-6 fix phase) | 35 | 6 claims in 5 groups | 28 | 0.64 strict (0.97 incl. 23 re-finds) | 0.56 (read-caught 5/9; all 4 carried seeds missed again) |

**Supports convergence:** findings and groups halved in two passes while fresh surface doubled; Tier 1 fell from a
flat 7 to 9 down to 2, both of them leftovers of earlier fixes (#723 a site #631/#686 left, #724 the retention
mechanism); precision above 0.7 and recall above 0.8, so the drop is earned; pass 5 is the first pass whose recall
measured READING (suite-caught split, new in #722) and it held at 0.86.

**Tempering points (each one changes what pass 6 should do):**
1. Precision slides 1.00 → 0.92 → 0.86 → 0.80: the floor signature, but it crosses 0.7 within two passes at this rate,
   and cost per Tier 1 is already ~1.9M tokens. Pass 6 will feel thinner and dearer per catch.
2. Yield is lens-shaped: 14 of pass 5's 27 findings came through its three NEW lenses, both Tier 1s through
   identity-names and concurrency. "Zero under these six lenses" says nothing about the five rotated out (time and
   zones, boundary arithmetic, operator error, failure injection, resource cliffs). Rotating them back in is the test:
   a Tier 1 under them means the limit is the lenses, not the code.
3. Each fix phase manufactures surface: pass 5's fix phase added 19 PRs, ~2,500 lines, three hand-merged paragraphs
   and one regression no fixer test caught (only the perf guard, at landing: #753's analyse test). The criteria's own
   rule (a batch of more than five PRs mandates a full pass) means convergence shows as a pass whose FIX PHASE is small,
   not as a pass that finds nothing.
4. The known-open backlog is not empty: #766-#775 hold ~45 unverified observations; at least one is Tier-1-shaped:
   `regrain_step` still resolves its source by rendered name (#768, the #723 mechanism; also the reconcile's source
   reads and `archive._resolve_child`). Pass 6 will verify some as re-finds (known-and-open, not findings), but a
   "zero" would sit on top of them.
5. Capture-recapture undefined: pass 5's duplicated slices had no Tier 1 on either side, so criterion 4 falls back to
   THREE clean passes. Under the rules as written the earliest stop is after pass 8 (passes 6, 7, 8 all at zero Tier 1,
   read-caught recall >= 0.8, precision >= 0.7). Say this to the user before pass 6 so expectations are set.

**Pass 6 result (2026-10-01):** four Tier 1 GROUPS (5 claims), not the one to three expected, three of them on fresh surface (#778 retain recall's schema, #779 views following the oid, #780 untransmute's publications) and one in the archive (#781 float digits); recall fell to 0.56 (read-caught 0.43), the first below 0.8, so the pass does NOT start the zero-T1 count and the earliest stop moves to after pass 9. Three of the four missed seeds were finders' hypotheses (#797). Fix phase closed 19/19 groups (PRs #799-#812) by 2026-10-02 06:54Z.

**Original expectation for pass 6:** one to three Tier 1s, mostly from the 19 fix PRs' fresh surface and the rotated-in
lenses, precision near 0.75. A zero would start the count and should be treated as a pleasant surprise, not as
evidence by itself.

**How to apply (what makes pass 6's result trustworthy):** rotate at least three lenses back in (plan in
[[pass5-plan]] / [[pass5-review]]); give the `bench/` guards their own slice under tests-pass-wrong-reason (the one
seed pass 5 missed, S5); plant at least one seed in the regrain reconcile-and-analyse region the landing repair touched
(c2d7ec8) and keep >= 5 seeds read-caught; feed #766-#775 to the classifier as known-open so re-finds classify as
such; pin main after #777 (`ae5dddc`) unless the user cuts a release first (a release mandates a full pass anyway).
Compare pass 6 against this table when writing its record, and update this file with the pass-6 row.

**Pass 7 result (2026-10-02):** five Tier 1 groups (6 claims), three in the archive module (identity lens) and two in regrain/hypertable (fresh surface); recall 0.56 for the second pass running, with the four carried seeds missed again and not even hypothesised; strict precision 0.64 (below 0.7) is the unverified known-open backlog (#813-#819, #766-#775), not reaching (3 fell of 69). The earliest stop is now after pass 10. Round 2 (hypothesis build-out) found 14 findings (3 T1) for ~1.05M tokens but none of the carried seeds. See [[pass7-review]].
