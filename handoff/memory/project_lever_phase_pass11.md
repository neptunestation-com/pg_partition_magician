---
name: lever-phase-pass11
description: Lever phase before pass 11 DONE 2026-10-09 (16:43Z to 20:35Z): #627 verified T1 by a clock shim; four PRs #1149 (#771 b3) #1150 (#1064 lever) #1151 (#627) #1152 (#1141 b1) per-PR verified (11 rounds, 11/11 seeds, 4 T1 + 1 T2 found inside the surface and fixed in place) and MERGED (main dab8434); closure 8/8; #1064 #627 CLOSED; filed #1153 (queue requires only the 3 summaries; test 37 flake) #1154 (checker T5) #1155 (lessons); record PR #1156 MERGED 22:08Z = PASS 11 PIN 0c38aae
metadata:
  type: project
  modified: 2026-10-09T20:36:00Z
---

**DONE 2026-10-09 22:10Z.** Record PR **#1156** MERGED 22:08:09Z, merge commit **0c38aae = PASS 11 PIN** (landed on the
third queue attempt: two groups left the queue on Docker Hub 500/429 manifest errors, 21:05Z to 21:34Z, a signature
flake_check.sh lacks, noted on #1155; a 20-minute-gap retry loop merged it). Record worktree removed. Merged code: #1149 ef00a6f, #1151 fe7c142, #1150
e5669e6, #1152 dab8434 (main). Closure 8/8 on dab8434 (acc keys 1064, 1141-b1, 771-b3, 627, 1152-v01, 1152-upgrade,
1152-upgrade-other, 1152-upgrade-samename). Issues: #1064 and #627 CLOSED; #1141 b1 and #771 b3 ticked (b3 of #1141 and
#771's other bullets stay open); #1153 (the queue merges when the 3 summaries are green: #1149's group merged with the
Archive track RED on a test 37 flake, #1151's with it still running; the tracks need summaries in the required set),
#1154 (check_archive_child_by_oid.py passes an ORDER BY CASE relname lookup; test 49 catches the module), #1155 (method +
tooling lessons: caveats are claims, premise_removed acceptances, lexical checkers, the queue's required set, a known_open
naming the PR's own issue printed clear once and was overridden by hand, pv_setup .sh acceptances, harness-kind
detection, --mutations). Agent budget about 4.3M tokens (fixers 1.28M, verification rounds 2.95M). Harness DOWN; agent
worktrees removed. Known-open after the phase for pass 11's re-find count: #1141 b3 (T5), #1154 (T5), #1153, the T3s of
the pass-11 plan, #638 (a hand-recreated ENABLE ALWAYS block on a successor: #1152 r5 noted it loses rows on base too).
Scratch kept at `$CLAUDE_JOB_DIR/tmp/lever11/` (record_final.md, record_rows.md, notes.md, pv/<pr>[_rN]/, closure/dab8434/).

**Why:** the pass-10 convergence read: criteria 2-3 met for three passes; criterion 1 not, because each fix phase injects
1-2 Tier 1s; pass 11 on a per-PR-verified surface is the test of the per-PR mode. The pin now carries no known Tier 1
(every T1 the phase found was fixed in place before landing), so pass 11's Tier 1 count measures new defects.
See [[pass11-plan]] for the pass-11 command.
