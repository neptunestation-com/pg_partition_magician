---
name: fix5-phase
description: Pass 5 FIX PHASE DONE 2026-10-01 17:27Z: 18 fix PRs #746-#763 + #764 + seeds #776 + record #777 all MERGED (main ae5dddc); closure 58/59 on d2faa7d, 30 issues commented, #710 closed by hand, #706 kept open; follow-ups #766-#775; what the landing taught (GitHub stall, stale PR head, one real perf regression repaired at landing); nothing pending
metadata:
  type: project
---

The fix phase for review pass 5 (findings #723-#744 plus the eight known-open issues that completed classes: #634 #635
#640 #706 #707 #708 #710 #711) ran 2026-10-01 03:14Z to 17:27Z across sessions 679cc592 (fixers, first batch) and a1867f7a
(landing, closure, filing, seeds, record). Everything is on main `ae5dddc`: 18 fix PRs #746-#763, workflow PR #764 (dbdev
cap advisory, issue #765), seeds PR #776, record PR #777. The authoritative account is the fix-phase section of
`docs/reviews/2026-10-01.md` (landing table, closure table, the one real failure, lessons); do not re-derive it.

**State to know:** #706 is OPEN on purpose (its min/max-before-lock bullet; closing it would remove the phase-2 failure
window tests 112/128/140 inject). #710 CLOSED by hand with a pointer (#753 fixed seven bullets, one unreachable, three
filed as #768 #769 #771). Adjacent observations are #766-#774 (one mechanism each, unverified) and #775 (harness, landing
and method lessons, continues #713). Closure: 58 of 59 reproductions pass on d2faa7d; the one failing is #727's assertion 7,
unsound by construction (caveated). Seeds: S1 S3 S6 S8 S9 catalogued in #776; S4 was byte-identical to #749's existing
mutation; S5 (count-only bench assertion) has no mechanical guard, recorded in #775. All scratch lives in
`/private/tmp/claude-501/.../679cc592-a383-4972-8c12-6a93e543f42c/scratchpad/fix5/` (closure.json, comments/, landing_notes.md,
landq.log, prs.tsv) if a number is ever questioned.

**Lessons not yet folded into tooling (they are in #775; the record explains each):** land.sh must compare GitHub's
`pulls/N .head.sha` with the SHA it pushed before trusting a check count (twice it read a superseded head's green: GitHub's
push-event pipeline stalled 08:13-08:21Z, and one PR never synchronised its push); never force a re-sync by pushing an
ancestor of main (GitHub closes the PR); close/reopen or push a new non-ancestor commit instead; a `RemovedFromMergeQueueEvent`
reason of `invalid_merge_commit`/`merge_conflict` on a head that merges cleanly is the same symptom from the queue's side; a
storm clean-up that cancels a PR's own perf run leaves it unverified until landing (#753's regression was caught only then:
the `reltuples < 0` analyse test, repaired as c2d7ec8, analyse when never analysed or analysed-empty with a row); land.sh
stops at the first file keep_both refuses and leaves resolvable add/add hunks behind; three of six stops were the same
transmute-refusal paragraph of docs/reference.md (list one shape per line to make future insertions add/add). closure.sh's
timescale gap is FIXED in #777.

**Measured:** 19 PRs in 12.4 h wall clock (39 min/PR, same as pass 4), 99-min median per PR, 36 enqueue requests, 6 stops,
1 flake (#556 signature), 37 keep_both hunks. Seeds agent: ~210k tokens, two phases via SendMessage (phase B after the
landing). Next: pass 6 (see [[pass5-review]]: rotate at least three lenses, give bench/ guards their own slice).
