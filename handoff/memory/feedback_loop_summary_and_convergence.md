---
name: loop-summary-and-convergence-report
description: "After every review loop (pass + fix phase), give the user a summary of the loop AND a convergence report across all passes (T1 per pass and where they came from, precision, recall, closure, adjacent T1 produced by fix phases, stopping-criteria status, earliest stop)"
metadata:
  node_type: memory
  type: feedback
  modified: 2026-10-11T17:49:02.716Z
  originSessionId: 74512dc7-512c-4ce9-be68-e242754d9908
---

After every loop of the adversarial review (a review pass plus its fix phase, ending with the record merged), the user wants two things in the final message, unasked: a **summary of the loop** and a **report on overall convergence** across all passes so far.

**Why:** the user's decision each time is whether to run another pass; the per-pass numbers alone do not answer it, the trend does. Asked for on 2026-10-11 after pass 11's loop ("After every loop, I want a summary of the loop as well as a report on overall convergence").

**How to apply:** source the numbers from the history table in `docs/adversarial-review.md` (rows per pass: findings, T1, claims, precision, seeds/recall, tokens, fix-phase clause) and the pass record's "Stopping criteria status". The convergence report should give: T1 per pass as a series and WHERE each pass's T1 came from (long-standing code via a rotated lens, a fix phase's fresh surface, a sibling copy, an older-install state); precision and recall series; closure ratios; adjacent T1 produced by each fix phase (the injection channel: 5, 1, 1, 1, 0 for passes 7 to 11); per-PR verification's blocked rounds; the stopping-criteria status and the earliest stop under the rules (from pass 12 the rule is the FULL LENS CYCLE: zero Tier 1 across all ten lenses over two consecutive passes at coverage 0.9 or better, so say which lenses the cycle still owes); the OLD-versus-YOUNG split of the pass's Tier 1 and 2 with the lens that found each (the age tag decided on 2026-10-11: old = survived earlier passes with its unit marked read; young = on code newer than the previous pin), and the recall on the late-survivor seed set separately from the catalogue seeds; the loop's cost against the budget ceiling (about 27M tokens and two days per loop, campaign through pass 13 unless the user extends); and a one-paragraph reading with a recommendation. Keep it factual; no em dashes. See [[fix11-phase]] and [[convergence-before-pass6]].
