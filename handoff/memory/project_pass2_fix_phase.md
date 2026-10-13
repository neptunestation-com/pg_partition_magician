---
name: project-pass2-fix-phase
description: "Pass-2 fix phase DONE 2026-09-26: all 24 fix PRs (#525-#549) + #528 merged (main 56b3b40), closure run 62/73 repros pass + 11 explained, evidence comments on #496-#522 (none reopened), adjacent issues #550-#558 filed; squash-queue + flake lessons"
metadata:
  type: project
  originSessionId: e3676f1f-5dd0-49b1-884e-c5176eaa0ec4
  modified: 2026-09-26T00:20:00Z
---

Fix phase of [[project-review-pass-2]]: 27 issues -> 24 fix PRs (#525-#549; #541 covers the zone class
#503-#506) + CI PR #528. PR bodies say `Closes #N`, so issues auto-close on merge; the user's "close each
issue by re-running its reproduction" is satisfied by `fix2/closure.sh` (waits for zero open fix/* PRs,
re-runs every repro on main) + `fix2/close_comments.py` (one evidence comment per issue, REOPENs one whose
SOUND repro still fails; known-unsound repros are listed in its CAVEATS dict).

Merged by 2026-09-26 00:17Z: #525 #527 #526 #528 #543 #529 #530 #531. The other 17 were STACKED
(`fix2/stack_build.sh 532..549`, each rebased onto the previous PR's branch, `PREV=` for a mid-list
restart) and are driven sequentially by `fix2/stack_drive.sh` (log fix2/stack_drive_rest.log).

**Why:** add/add conflicts in CHANGELOG.md, bench/mutations/mutate.py and test.sh on EVERY rebase made
per-PR rebase-and-wait cost a CI round trip each; stacking runs each PR's checks once and the queue takes
them in order (squash of k onto main holding k-1 = k's tree). Hand-merged install.sql hunks: #532 (#496 vs
#497), #541 (_grid_next: keep #505's snap AND wrap in #530's _ts_text; #506 partition_tz column vs #509
take-over arm), #544 (#510 name check + #516 cancel block sharing an `end if`).

**How to apply:**
- `fix2/keep_both.py` (has --selftest with the real conflict hunks as fixtures) resolves the list files;
  three mutate.py shapes git produces by factoring the SHARED tail out of both sides: `"", 1)],` + `    ),`
  after an unclosed site tuple; entry closer missing when the second side opens with comment lines; two
  block constants sharing a closing `"""`. Both merge_cycle.sh and resolve_lists.py call it.
- Detect rebase completion with `git status | grep 'rebase in progress'`, not REBASE_HEAD.
- ALL 24 fix PRs + #528 MERGED by 2026-09-26 08:29Z (main 56b3b40). Guard database names ended up unique
  and dense (the driver renumbered every collision); duplicate test FILE numbers remain (tests/124_* x7,
  125_* x7, 129_* x4, archive 16_* x3) for the housekeeping issue. Closure run (classify_claims against
  56b3b40) DONE 09:0xZ: 62 not_reproduced, 10 candidate + 1 invalid_repro, every one explained by a
  documented caveat (unsound fixtures from seed interactions, #504 making #501's premise legacy-only,
  F7-04 moot since perf.yml lost its paths filter in #495); close_comments.py --post put one evidence
  comment on each of #496-#522, NONE reopened. Adjacent issues FILED: #550 obtain silent name skip,
  #551 archive key session-dependent, #552 hypertable name length, #553 archive ledger vs regrain
  lifecycle, #554 regrain concurrency races, #555 capture delta schema anchor, #556 flaky lock guard
  (4 hits, always 20 timeouts = deadlock_timeout/autovacuum hypothesis), #557 housekeeping (dup test
  numbers 124 x7, 125 x7, 129 x4, archive 16 x3), #558 methodology follow-ups. #439 got a comment.
  Record update PR #559 (docs/reviews/2026-09-25.md fix-phase section + pass-history row) MERGED
  2026-09-28 on the user's say-so (after one lock-guard flake in its merge group, the 5th, noted on #556); the 24 fixer worktrees and their merged branches were removed 2026-09-28 on the user's say-so.
- Adjacent-observation issue drafts (9, grouped by mechanism) are in `fix2/adjacent_issues/*.md`; file
  them AFTER the closure run, per the user. #439 gets a comment (skip_write_block_lift substitution), not
  a new issue. Facts verified on main: obtain's `continue when to_regclass(...)` has no log row; archive
  key = `cfg.prefix || p_parent::text || '_' || _object_stem(kind, lo)` and `_ts_text` pins DateStyle only.
- STACKING DOES NOT SURVIVE A SQUASH QUEUE: once k-1 lands as a squash, PR k's branch (carrying k-1's commits)
  conflicts with main in the list files at the queue's 3-way merge, and a plain `git rebase origin/main` replays
  k-1's commits onto their own squash (conflicts). What works: `git rebase --onto origin/main <k-1's OLD head>`
  (only k's own commits move; parent tree already holds k-1's lines). `fix2/stack_drive2.sh` does that per PR
  from `fix2/stack_bases.tsv`, then waits head checks, enqueues, waits merge: ~22 min/PR, sequential, no way
  to pipeline under squash (merge-commit method would allow batching; offered to the user, not taken up).
- Known CI flakes, retried ONCE by the driver only when `fix2/flake_check.sh` matches a narrow signature:
  bench/regrain_outgoing_fk_lock.sh "writes to the MANAGED PARENT are not blocked got N, want 0" with its
  liveness PASS and no other FAIL (3 hits in 3.5 h on 2026-09-26: #530 group, #535 head, #539 head; the 50 ms
  lock_timeout count cannot discriminate on loaded runners; drafted as an issue), and public.ecr.aws
  "toomanyrequests: Data limit exceeded" on the supabase/postgres fleet image (a CI storm of 17 heads
  exhausted the anonymous quota; #538). queue_merge.sh exit 9 = PR left the queue unmerged (failed group).
