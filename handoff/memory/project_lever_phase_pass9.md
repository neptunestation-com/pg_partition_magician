---
name: project_lever_phase_pass9
description: Lever phase before pass 9 DONE 2026-10-06: levers #967 #968, residue fixes #971 #972, record #970 all MERGED; PASS 9 PIN = 06643c8 (the #972 merge); residue #969 CLOSED (6 fixed, 5 struck); what pass 9 inherits: two levers (W1 scratch relations minted/resolved by record; W2 one preflight every converting entry point inherits), scratch lever9/, what closes, how to resume, then PASS 9 PIN on the last lever merge
metadata:
  type: project
---

**Decision (2026-10-05):** the user accepted the convergence assessment after the pass-8 fix phase ("Do it"): pass 8 was the
first trustworthy count since pass 5 (coverage 1.00, recall 0.89, precision 0.92) and still read 3 Tier 1 groups; the backlog
verification added 1 Tier 1 (#955 b1) + 3 Tier 2 (#950 b2, #952 b1, b2), nearly all class siblings of fixed sites (hypertable
path lagging). Earliest stop under the criteria: after pass 11 (capture-recapture undefined -> three clean passes).

**Tracking issue #966.** Scratch `$W9` = `.../d9aafdd7-.../scratchpad/lever9/` (plan.md, briefs/COMMON.md + W1.md + W2.md,
issues/*.json, prs.tsv, landq.txt, gate.lock, fix/W1, fix/W2, landing_notes.txt). Acceptance tests = the pass-8 verifiers'
reproductions in `.../scratchpad/fix8/adjv/A*/repro.*`.

| W | lever | closes | branch | numbers |
|---|---|---|---|---|
| W1 | mint scratch relations one way (record oid, own like parent, ACL reset at creation) + resolve/drop from the record, never by name; ownership re-checked each tick; conformance suite + optional static check | #949 (all), #955 b1 (T1), #950 b2 (T2) | fix/lever-scratch-relations | tests 267, ts 49; pgpm_perf250 |
| W2 | one preflight before any commit at every converting entry point: null args at EVERY public entry point (pg_proc sweep), control-type contract (negative scale) + resume re-checks recorded bounds, NOT VALID / PG18 NOT ENFORCED key gates shared with from_hypertable | #951 (both), #952 b1 b2 (T2), #959 (both) | fix/lever-shared-preflight | tests 268, 269, ts 50; pgpm_perf251, 252 |

Open as known-open for pass 9 (no lever): #954 b1, #955 b3, #956 b2, #957 b1, #958 b1, #961 b3 b5, #962 b2 b4, #963 b1 b2 b4 b6.

**Resume:** fixers report PR numbers -> append to prs.tsv/landq.txt (tier 1 for W1, tier 2 for W2) -> `scripts/review/landq.sh $W9 --batch 5`
(nohup; main checkout must have no pgpm_test-* up while fixers gate) -> closure-style re-run of the 11 reproductions on main
(closure.sh needs a claims dir; re-run by hand with classify or the repro files directly) -> comments/close on #949 #950 #951 #952
#955 #959 -> residue issue -> "Lever phase before pass 9" note in docs/reviews/2026-10-04-pass8.md + history row -> PASS 9 PIN =
main at that merge. See [[project_fix8_phase]], [[project_lever_phase_pass8]].

**2026-10-06 04:10Z (after a session restart):** #967 (W2 shared preflight) MERGED 22:21Z via one of land.sh's earlier enqueue requests taking effect once its rerun checks went green; #968 (W1 scratch relations) MERGED 23:15Z (rebased onto #967, auto-resolved). A GitHub incident ("delays in assigning GitHub-hosted runners", ~19:40-21:55Z) cancelled jobs with "The job was not acquired by Runner of type hosted"; added flake signature `runner_not_acquired` to scripts/review/flake_check.sh LOCALLY (uncommitted in the main checkout; carry it in the record PR). Residue issue #969 filed (11 bullets). Closure rerun script: lever9/closure_rerun.sh (log closure_rerun.log). REMAINING: closure comments on #949 #950 #951 #952 #955 #959 (close all but #955, whose bullet 3 stays), record note in docs/reviews/2026-10-04-pass8.md + history row + flake_check.sh change in one PR, user merges, PASS 9 PIN = that merge.

**04:30Z:** closure rerun 12/12 PASS on 86ab769 (lever9/closure_rerun.log); closure comments posted; #949 #950 #951 #952 #959 closed (by the PRs' Closes lines), #955 open for bullet 3; residue #969 filed; record PR #970 (docs/lever-phase-pass9: lever section + history row + flake_check.sh runner_not_acquired) OPENED, NOT enqueued (user's call). Residue verification: 11 verifier briefs in lever9/adjv/prompts (A969-1..11), verdicts to lever9/adjv/verdicts. After #970 merges: PASS 9 PIN = that merge; pass 9 known-open = #955 b3, #954 b1, #956 b2, #957 b1, #958 b1, #961 b3 b5, #962 b2 b4, #963 b1 b2 b4 b6, #969 confirmed bullets, #890 leftovers.

**04:50Z:** residue #969 verified: 6 confirmed, 5 struck. Confirmed: A969-3 + A969-7 = ONE TIER 1 (the #496/#655 upgrade DO block ~install.sql:4212 adopts an operator's `<rel>_pgpm_regrain_delta` by name on re-running install.sql; the next prepare DROPS it), A969-2 T3 (teardown/regrain_cancel lack the hand-over refusal), A969-5 T3 (carried_ddl excludes an operator's trigger by function name), A969-9 T3 (archive_to_s3_* no null check; empty-range PUT overwrites an archived object), A969-10 T5 (#730 CHECK gate PG18 NOT ENFORCED wording). Struck: A969-1 (hand_over_scratch works), -4 (documented), -6 (first tick re-mints), -8 (PG18 pgTAP job catches), -11 (#578 covers). Follow-up fixers spawned (fresh agents; old ones not resumable): W1b branch fix/lever-scratch-residue (bullets 2,3,5,7; tests 270, ts 51, pgpm_perf254), W2b branch fix/lever-preflight-residue (bullets 9,10; tests 271, archive 41, pgpm_perf255). Then: land both via landq (lever9), re-run the 6 repros, comment/close #969 bullets, add a residue paragraph to PR #970's section (amend the open PR), then the user merges #970 = PASS 9 PIN.

**06:30Z:** record PR #970 MERGED 06:26:58Z (main cb8eb86) on the user's call; its text pins pass 9 on #972's merge. #971 MERGED 05:42Z (df2c8af). #972 (W1b, the Tier 1 upgrade-backfill fix) STOPPED at landing: CI PG15 on its rebased head d1f84d0 failed tests/251 (child_keys read a timestamptz pgpm.part bound under rg251c's reused oid: stale rows left by an earlier file, likely the new 42501 hand-over refusal firing in a cleanup path); W1b re-engaged on the branch. When fixed: `grep -v '^972 FAILED'` landq.done, restart landq (lever9), then lever9/closure_rerun_residue.sh, update/close #969, remove worktrees agent-aa2a51f984d97d4e0 + agent-a32196fb1b688f610, PASS 9 PIN = #972's merge commit.

**07:20Z:** #972 MERGED 07:16:38Z -> main 06643c8 = PASS 9 PIN (per the record's text, "pinned on the merge of #972"). Residue closure re-run started (lever9/closure_rerun_residue.sh -> closure_rerun_residue.log); then comment/close #969. Worktrees and local lever branches removed. #973 filed (test-helper planner-order hazard, Tier 5, unverified beyond tests/251). Pass 9 known-open backlog: #955 b3, #954 b1, #956 b2, #957 b1, #958 b1, #961 b3 b5, #962 b2 b4, #963 b1 b2 b4 b6, #973, #890 leftovers (minus what #967/#968 covered), #964 method lessons.
