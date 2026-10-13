---
name: pass3-fix-phase
description: Pass-3 fix phase (2026-09-28/29) outcome: 39 issues #563-#601 fixed by PRs #603-#626, closure 65/73 on main 46e1d45, record PR #645, follow-ups #627-#644, queue flipped to MERGE; what pass 4 owes
metadata:
  type: project
---

Pass 3's fix phase ran 2026-09-28 22:18Z to 2026-09-29 11:53Z: 23 fixers (G1-G23), 24 PRs (#603-#625 fixes,
#626 test-147 margin), landed one at a time under the squash queue via fix3/landq.sh + land.sh (28-min median,
17.8 h total; 9 hand interventions: 4 non-list-file conflicts, 5 real CI failures). Closure on main 46e1d45:
65 of 73 reproductions pass, 8 explained (F9-04/#580 and F3-07/#582 unsound since their fixes, 4 known-open
re-finds of #550/#551/#554, F4-08 and F6-04 fell/unfiled). All 39 issues closed with evidence comments, none
reopened. Adjacent observations filed as #627-#644 (#627 is a Tier 1 candidate: retain horizon resolves an
ambiguous fall-back time to the later instant). Record PR #645 (branch docs/pass-3-fix-phase) OPEN, awaiting
the maintainer's say-so to enqueue.

**Why:** the maintainer accepted three behaviour changes before landing (#613 extend_to lock budget, #615
NOT VALID re-add, #620 regrain parent SHARE lock) and decided 2026-09-29 to switch the merge queue to MERGE
commits before pass 4; the flip ran at 11:55Z right after #626 merged (ruleset 24013010).

**How to apply:** pass 4 prep owes: land.sh batch mode (merge-commit queue keeps stacked ancestry, groups of
up to 5); `concurrency` groups on PR workflows; configurable/retryable wait caps; keep_both.py markers
anchored at column 0; the 3 novel pass-3 seeds (novel_retire_straddle, novel_archive_overclaim,
novel_abort_pid_only in pass3_sealed/seeds/) still need guards+mutations in bench/mutations; F4-08 (retain
'NaN') and F6-04 (second from_hypertable_cutover overload after upgrade) still fail on main and deserve a
second look. Stopping criteria not met (pass 3 had 9 T1); pass 4 reuses lenses to see whether T1 falls.
Fixer gate lesson: 5 of 6 real CI failures came from tracks `./test.sh 15` does not run (shellcheck, upgrade
guard, PG 18, discriminate install check). See [[pass3-prep]] and [[pass2-fix-phase]].

**Pass-4 prep, 2026-09-29 afternoon:** record PR #645 MERGED (15:20Z). Tooling PR #646 (land.sh --batch for the
merge-commit queue, env wait caps, exit 6 = rerun, MERGED re-check, conflictstyle pinned, rerere off; landq.sh
loop with keeper folded in; gate.sh with container-absent wait; landing_stats.py; concurrency groups on the 7 PR
workflows keyed by PR number; record correction: #623's keep_both refusal was the pre-#598 copy, not a remaining
gap) and seeds PR #647 (retire_straddles_horizon, archive_contract_no_overclaim, abort_owner_alive_by_pid_only
with test-file guards on tests/60, 115, 101; pgpm_perf81-83) are landing as the FIRST LIVE BATCH via
`land.sh --batch 646 647` (log: scratchpad prep4/land_batch_646_647.log). Still open on main: F4-08 (retain
'NaN') and F6-04 (second from_hypertable_cutover overload after upgrade) fell in verification but fail on main.

**Batch landing, measured 2026-09-29:** #646 + #647 landed via `land.sh --batch` (first live batch). Finding: GitHub's
merge queue DROPS a queued PR whose head sits on another queued PR's head (added and removed 12 s later, twice, no
group built) with no reason in the timeline; a stacked PR can be enqueued only after its predecessor merges, and
then needs no rebase or head checks. So a batch saves the rebase + head-check round per PR but still pays one
merge group (~12 min) per PR. PR #648 makes enqueue-in-turn the design and confirms each enqueue (the first
request for #647 left no entry, silently). #644 and #558 CLOSED 2026-09-29 with evidence comments.
