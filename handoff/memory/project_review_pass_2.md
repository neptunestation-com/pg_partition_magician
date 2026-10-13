---
name: project-review-pass-2
description: "Review pass 2 of pgpm (2026-09-25, pinned 581e87a): 49 verified findings (7 T1) in 27 root-cause groups, issues #496-#522; seeds 9/9, precision 1.00; Opus finders beat Fable on the duplicated slices; tooling defects fixed in PR #493; record PR + CI PRs #494/#495"
metadata:
  type: project
  originSessionId: e3676f1f-5dd0-49b1-884e-c5176eaa0ec4
  modified: 2026-09-25T17:03:10.586Z
---

Pass 2 ran 2026-09-25 under [[project-adversarial-review-method]] (docs/adversarial-review.md),
pinned main 581e87a (all 25 pass 1 fixes in). Coordinator = me; 10 finder agents (8 slices on
fable/high, S3 regrain and S4 retain duplicated on opus), 49 verifier agents (opus/medium, one per
candidate), 9 blind seeds (6 catalogue incl. 4 pass-1 fixes, 3 novel patches).

Result: recall 9/9, 73 claims, 24 seed hits, 49 candidates, 49 findings (precision 1.00): T1 7, T2 24,
T3 13, T4 2, T5 3; 44 distinct defects in 27 root-cause groups filed as issues #496-#522 (T1 first:
#496-#502). Record: docs/reviews/2026-09-25.md (PR #523 MERGED via the queue 2026-09-25; #493 tooling fixes and #524 docs also merged through it, the first three PRs through the queue). Budget
4.66M agent tokens (~95k per finding), hunt 15:32Z, last verdict 17:00Z.

Headline T1s: user triggers lose tgenabled at cutover (#499); DateStyle-dependent stored bounds
(#500); dropped_fk definition text search_path-relative + oid moves to monolith (#498); regrain
capture keyed by parent's CURRENT relname + delta reuse + no grants (#496); reconcile watermark
snapshot race (#497); archive encoders ignore partition_tz (#501); S3 key drops the sign (#502).
Big T2 class: day-step labels as wall date in partition_tz collide across DST (#503), max(uuid)
still present (#507; pass 1's tier 2 was never filed).

**Why:** the user wants find -> fix -> harden -> find again measured; this is the first measured point.

**How to apply:**
- Model choice: on both duplicated slices Opus produced more claims at equal precision and found T1s
  Fable missed (F9-03, F9-04, F10-07), for 8-27% more tokens. Use Opus as the default finder for pass
  3 and keep duplicating two slices (the union also beat either member).
- Finder self-reported time is wrong ("2 hours" = 20-35 min measured); use notification durations.
- Reproduction contract gaps found: psql indents `not ok` (fixed); liveness/fixture failures read as
  defect on pristine (fixed: LIVENESS/GUARD/fixture-prefixed assertions; 5 verifiers had to rebuild);
  archive claims need a `container` field + tests/archive/fixtures.sql in `install`; seed attribution
  needs isolation when two seeds share a function. All in PR #493 (fix/review-plant-seeds-apply).
- Concurrency cap is 20 subagents: verifiers run in waves; pipeline verification as finders finish.
- Fix phase is next: ~27-32 PRs. CI: perf job sharded (PR #494 MERGED 2026-09-25; critical path 27 ->
  11 min, discriminate shard 1/4 is the long one). Merge queue: workflows are merge_group-ready (PR
  #495 MERGED) and main now requires Test Summary + Lint summary + Perf summary (strict on), BUT the
  ruleset POST fails 'Invalid rule merge_queue': GitHub offers merge queues only on ORGANIZATION-owned
  repos. RESOLVED 2026-09-25: the user transferred the repo to the neptunestation-com org (free plan;
  dventimisupabase is an org owner, same gh identity works). New path github.com/neptunestation-com/
  pg_partition_magician (old URL redirects; Pages URL does NOT: explainer now at
  neptunestation-com.github.io/pg_partition_magician). Ruleset 24013010 'main: merge queue' active
  (SQUASH, ALLGREEN, 5 per group). `gh pr merge --squash` now ENQUEUES (it needs repo setting
  allow_auto_merge=true, set 2026-09-25, else 'Auto merge is not allowed'; `--delete-branch` is REFUSED
  with a queue, so delete_branch_on_merge=true is set on the repo instead). A PR needs the three
  required summary checks reported on ITS OWN head before it can be queued: PRs opened before #495
  had to be rebased+pushed so their heads ran the new workflows. Merge-group runs appear as
  `gh run list --event merge_group` on branch gh-readonly-queue/main/pr-N-<sha>. scratchpad
  queue_merge.sh <pr> <min_checks> waits for PR checks, enqueues, waits for MERGED. #524 first through. main WAS
  already protected (8 checks, strict, conversation resolution); CLAUDE.md's "unprotected" was stale.
- merge waiters: an empty check list right after a force-push looks like "all green"; wait for a
  minimum registered-check count (scratchpad merge_wait.sh <pr> <min>).
- Post-pass follow-ups not yet done: add the 3 novel seeds to bench/mutations (need guards), add
  fixed-defect mutations after fixes, close each finding by its repro on the fixed main.
