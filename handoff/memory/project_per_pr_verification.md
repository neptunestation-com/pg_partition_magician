---
name: project_per_pr_verification
description: Lever phase before pass 10 DONE 2026-10-08: per-PR adversarial verification built (#1050 MERGED 06:08Z = PASS 10 PIN 0654e1e) and trialled on nine fix PRs (#1046 #1047 #1049 #1052 #1053 #1058 #1059 #1060 #1063, all MERGED; 11 verification rounds, 9/9 seeds, two heads blocked and fixed in place, four next-hop Tier 1s in the archive by-name class, the fifth #1064 left for a lever); closure 13/13; record PR #1068 MERGED 2026-10-08 15:24Z (main 81a6fed; the PIN stays 0654e1e, the last code merge); lessons #1067; pass 10 next in a NEW session
metadata:
  type: project
  modified: 2026-10-07T23:08:00.063Z
---

**Decision (user, 2026-10-07 evening):** build "per-PR adversarial verification" (the standing mode in docs/adversarial-review.md's
stopping criteria), trial it on the four verified Tier 1/2 backlog bullets as the lever phase before pass 10, landing each through the
queue; then clear and run pass 10. Session job 8d94cdfa, scratch `$W` = `/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/lever10/`
(briefs/, acc/ + acc_claims/<pr>/, v/<pr>/ per verification [base head review mutants/ pr.diff pr.real.diff surface/ claims/ verdicts/
pr_classified.json comment.md], prs.tsv, adjacent/X*.md, landq.txt, landq.stdout, mkbriefs.py, mkverify_briefs.py, mkcand_brief.py).
Tooling worktree: `.claude/worktrees/pr-verify` (branch feat/pr-verify, PR #1050). Private harness: pgpm_prv-15/-archive(+minio)/-timescale
on network pgpm_prv_net (`scripts/review/pr_verify.sh harness down` when done).

**What was built (PR #1050, lands LAST after the trial):** `scripts/review/pr_verify.sh` (prepare | harness up/down | classify | report |
cleanup), `pr_surface.py` (touched units by dollar-quoted body + callers + touched files = the slice; coverage.py gained explicit `units`),
`pr_classify.py` (four trees: base, head, review = head + seed, mutants/<name> one per NEW mutation; classes regression / pre_existing /
fixed / seed_hit; acceptance claims (dir ACC) judged on base+head+mutants only: fails_on_base, passes_on_head, mutant_restores per
mutation, any_restores), `pr_comment.py` (comment + landing policy, exit 1 = blocked: acceptance not holding, verified regression any tier,
verified T1/T2 pre_existing INSIDE the surface, unverified candidate, closing `partial`; outside-surface and T3-5 → filed), skill
`.claude/skills/pr-verify/SKILL.md`, finder.md/verifier.md per-PR sections (verifier's claims-verifier role writes claims under V/ and
verdicts/closing.json), fixer.md `Addresses #N (bullet k)`, flake_check.sh `summary_only` + `lost_runner` (+ `--attempt N`; issue #1048),
CLAUDE.md pg_stat_activity snapshot rule, fix-phase skill brief items (#1035), docs section "Per-PR verification", README section.

**Trial results (all five PRs clear at the end; comments posted on each PR):**
| PR | fix | verification |
|---|---|---|
| #1046 (X2, #1030 b3, T1, archive script contract) | head a11cef1 → BLOCKED: claims verifier found V-01 Tier 1 (script runs strategy under caller RLS, no `_refuse_filtered_reads`; FORCE RLS owner archives visible rows, retire drops hidden) → fixer fixed in place (head ff0343f, test 286 part E, mutation archive_whole_rls_unrefused) → round 2 clear; seeds found both rounds |
| #1047 (X4, #1039 b1, T2, transmute step/anchor precision) | clear; seed (time_unit_anchor_unchecked) found; P1-02 = known_open #769 (repro posted on #769); closing holds |
| #1049 (X3, #1037 b1, T2, hypertable capture by record) | clear; seed found; V-01 Tier 2 OUTSIDE surface = core regrain capture by name → filed as #1051 |
| #1052 (X1, #1030 b1, T1, to_s3 child held + read by regclass) | clear; seed (archive_to_s3_child_unheld) found as 3 claims; closing holds |
| #1053 (X5, #1051, T2, regrain capture by record) | clear; seed found; claims verifier `partial` on an upgrade-path claim (V-01) that the independent verifier made FALL (unreleased builds only; repro.verified.sh kept) → policy: a partial whose named paths all fell holds |

Landing: `landq.sh $W --batch 5` running from the pr-verify worktree (nohup, log `$W/landq.stdout`); landq.txt = 2 1049, 2 1047, 1 1046,
1 1052, 2 1053, 3 1050 (the tooling PR lands last by tier). PASS 10 PIN = main after the last of these lands; record PR (docs) the user merges.
Adjacent observations FILED unverified 2026-10-07 23:35Z: #1054 (script, 4 bullets), #1055 (archive export identity, 3), #1056 (time-unit rule, 4), #1057 (scratch capture, 5): one verifier per bullet against the landed main before the pin; #769 got P1-02's repro as a comment; #1051 closes via #1053.

**Method lessons so far (for the record and #1035-style issue):** (1) the policy must hold a PR only for T1/T2 INSIDE its surface (the
#1049 sibling in core would otherwise have blocked a hypertable PR); (2) the claims verifier gets the REAL diff, not the seeded one; (3)
one mutant tree per new mutation: overlapping mutations do not apply in sequence, and single-site mutations legitimately do not restore
the issue's defect alone; (4) acceptance claims are judged on base/head/mutants only; (5) a repro that dies identically on every tree
(missing pgtap) reads as pre_existing: same-last-error note added; (6) the QUIETEST seed: a whole-fix revert makes the finder re-find
the issue (#1052: 3 claims all seed); (7) coverage ledger names compare case-insensitively; (8) the claims verifier earned its keep:
it found the only Tier 1 of the trial, inside the PR's own file, which the fixer had listed as out of scope.

**2026-10-08 01:35Z:** #1047 #1049 #1046 #1052 MERGED (landq; #1049 needed a hand dequeue/enqueue after a 19-min queue stall, now automated in
land.sh's wait_merge as LAND_STALL_MIN); #1053 landing; #1050 queued last. Closure on main 89cf9cd: A1030-1, A1030-3, V1046-rls, A1037-1, A1039-1 pass
(comments + ticks posted on #1030 #1037 #1039); V1051 awaits #1053. Adjacent verification (11 of 16): #1054 b1 T3, b2 T2, b3 T3 CONFIRMED, b4 struck
-> fixer X6 (branch fix/archive-partition-whole-follows-step, test 289 or 286 parts, pgpm_perf290); #1055 b1 T1 CONFIRMED (parquet derive-then-read
window under a schema swap) -> fixer X7 (fix/parquet-snapshot-by-regclass, archive 46, pgpm_perf292), b2 struck, b3 known_open #1005 (83/565 mutations
carry MUTANT markers); #1056 b1 known_open #816 (repro posted), b2 b3 b4 struck; #1057 (5 bullets) verify after #1053 lands. X6/X7 PRs get /pr-verify
too, then land via landq (append to landq.txt). Scratch: adjv/ (prompts, verdicts, A*/repro), closure/ (run.sh <sha>), briefs/X6.md X7.md.

**2026-10-08 02:40Z:** #1053 MERGED 02:21Z (land.sh's automatic stall nudge fired at 02:01Z, worked); main 51b1c7f; closure: all 6 landed fixes'
repros pass, #1051 CLOSED with evidence. #1058 (X6: #1054 b1-b3; verified clear, ACC-02 ruled premise_removed with a rebuilt repro) LANDING now;
then #1050 (tooling). #1059 (X7: #1055 b1 T1) verified 02:55Z: BLOCKED (V-01 Tier 1 confirmed: _refuse_foreign_read admits every descendant of p_relation, so a swap onto one of the parent's own partitions passes and the range chunk encodes 0 rows; plus P1-02 Tier 5: test pins the helper, not the call site) -> X7 (agent a109425f3001ebdc8) told to fix in place; re-verify on the new head with a fresh --work (v/1059b), then append `1 1059`.
#1057 verified: b1 T3 (delta moved to another schema leaves unrecorded residue), b3 **T1** (the by-name fast path of BOTH new captures:
unlocked to_regclass check then a by-name insert; rename+namesake in one txn routes a writer's keys into the operator's table, the swap
reverts a committed UPDATE) -> fixer X8 SPAWNED (fix/capture-fast-path-under-lock, tests 290 + timescale 57, pgpm_perf294/295); b2 b4 b5
struck. Method lesson recorded in verifier.md/skill/doc: a caveat ("tiny race") in a PR body is a claim to build. After X8's PR: /pr-verify
it, land, re-run closure, post on #1057; then record PR + memory + cleanup. Adjacent of X6/X7 in adjacent/X7.md (file later as one issue).

**2026-10-08 03:05Z:** #1059 round 1 BLOCKED (V-01 T1: _refuse_foreign_read admitted every descendant; rebuilt repro) -> X7 fixed in place
(head 2198979, name rule + test 46 parts D/E, 7 mutations); round 2 (v/1059b): acceptance x2 hold, claims verifier holds, finder RUNNING.
X8 opened #1060 (both captures lock the delta through the name, insert only if it still leads to the recorded oid; tests 290 + ts 57;
pgpm_perf294/295); acceptance holds; finder + claims verifier RUNNING (v/1060). #1058 in the queue (auto stall-nudged 02:57Z). Closure set
(12 claims) in closure/claims/ACC; closure/run.sh <sha> after everything lands. Record draft $W/record_draft.md has the full tables.

**2026-10-08 03:30Z:** #1058 MERGED 03:10Z (auto stall-nudged once). #1059 round 2 CLEAR (seed found; closing holds) -> queued `1 1059`, landing
now (rebased 20d589d). #1060 CLEAR (seed found; closing holds; P1-02/V-01/V-02 = one verified T3 -> filed as #1061 with both repros; V-03 fell by
class (unreleased-build upgrade); V-04 fell) -> queued `1 1060`. Then #1050 lands last. #1062 filed (3 unverified fixer bullets: to_s3
render-then-read, _resolve_child parent-schema name, set_retain uncast order) -> 3 verifiers (briefs adjv/prompts/A1062-*) before the pin.
After all land: closure/run.sh <sha> (13 claims incl. A1054-*, A1055-1, V1059-carveout, A1057-3), comments on #1054 #1055 #1057 (tick/close),
record section from $W/record_draft.md -> docs PR (user merges), memory, harness down, worktrees removed.

**2026-10-08 03:40Z:** #1062 verified: b1 struck, b2 **T1** (_resolve_child two-statement resolution; untracked relation resolves a namesake
under a schema swap) -> fixer X9 SPAWNED (fix/resolve-child-one-snapshot, archive 47, pgpm_perf297), b3 struck. #1061 filed (T3 from #1060:
42809 uncaught under the freed name). Landing: #1059 head checks running, then #1060, then #1050; X9's PR gets /pr-verify then `1 <pr>`.

**2026-10-08 04:00Z:** #1059 MERGED 03:43Z; #1060 landing (head checks), then #1050, then #1063. X9 opened #1063 (one-snapshot resolution +
identity check under the lock; archive 47; pgpm_perf297); acceptance holds; claims verifier holds but found V-01 **T1 OUTSIDE the surface**
(_owned_key's second by-name lookup in the parent's CURRENT schema under a parent SET SCHEMA) -> verified T1 -> FILED as #1064 with a lever
suggestion (every archive lookup after _resolve_child by oid + a conformance check); DECISION: no tenth fixer, the user chooses the lever
(fifth hop of the by-name class). #1063 finder RUNNING -> report -> `1 1063`. #1061 (T3) and #1064 (T1) are the known-open residue for the pin.

**2026-10-08 05:35Z: ALL NINE FIX PRs MERGED** (#1047 #1049 #1046 #1052 #1053 #1058 #1059 #1060 #1063; last at 05:24Z; main ffa51e7 before #1050).
Closure 13/13 on ffa51e7; evidence posted; #1051 #1054 #1055 #1056 #1062 closed; #1057 b3 ticked (b1 T3 open); #1061 (T3) #1064 (T1 lever
candidate) #1065 (tests/77 probe) #1066 (restore_fk_lock flake, signature in #1050) #1067 (method lessons) filed. #1050 (tooling) LANDING
(head checks at 05:27Z). Harness DOWN; fixer worktrees removed. Record text READY: $W/record_final.md + history_row_addition.txt, applied by
$W/apply_record.py <checkout> on a branch docs/lever-phase-pass10 cut from main AFTER #1050 merges; lint; PR (user merges). PASS 10 PIN =
#1050's merge commit. Then: memory final, remove the pr-verify worktree + local feat/pr-verify.

**2026-10-08 06:15Z: PHASE DONE.** #1050 MERGED 06:08Z (after a fourth automatic stall nudge) -> **PASS 10 PIN = 0654e1e** (main). Record PR #1068 MERGED 15:24Z (81a6fed)
opened from docs/lever-phase-pass10 (section "Lever phase before pass 10" appended to docs/reviews/2026-10-06-pass9.md + the pass-9 history
row extended); the user merges it. Known-open at the pin: #1061 (T3, 42809 under the freed name), #1064 (T1, _owned_key's by-name second
lookup; LEVER candidate: every archive lookup after _resolve_child by oid + conformance check), #1057 b1 (T3), #1065 (tests/77 probe, T5),
#1066 (restore_fk_lock flake, signature in place), #816/#769/#1005 re-finds, #1030 b5, #1037 b2, #1039 b2 b3. Pass 10: rotate lenses per the
pass-9 record; `/review-pass 0654e1e 9 <lenses>` in a fresh session; expect the fix-adjacent hypothesis to be read from pass 10's fresh-surface
Tier 1 count (the trial's own answer: 2 of 9 heads blocked, 4 next-hop T1s found by the backlog verification, not by the per-PR finders).

**Still to do (none for this phase):** report #1053 + queue; watch landq to the end (stops need a hand); land #1050 last (LAND_TOOLING default = its own
worktree); file adjacent observations ($W/adjacent/X1..X5.md + finders' hypotheses) as unverified issues, then one verifier per bullet
before the pin; post closure comments on #1030 (b1, b3), #1037 (b1), #1039 (b1) with the acceptance evidence (strike/close as fit); record
section "Lever phase before pass 10" in docs/reviews/2026-10-06-pass9.md + history row (draft at $W/record_draft.md) as a docs PR (user
merges); harness down; remove agent worktrees (.claude/worktrees/agent-*) and the pr-verify worktree; update this memory with the PIN.
See [[project_fix9_phase]], [[project_merge_group_speedup]], [[project-adversarial-review-method]].
