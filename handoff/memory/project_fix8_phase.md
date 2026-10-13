---
name: project_fix8_phase
description: Pass-8 fix phase DONE 2026-10-05: 27 PRs merged, closure 65/72, adjacent #949-#963 verified, record PR #965 MERGED 17:52Z (main 3951b00); PASS 9 PIN can be taken from 3951b00: 27 PRs merged (main e19b362), closure 65/72, #892-#919 + #875 + #953 + #960 CLOSED, adjacent #949-#963 verified (24 confirmed: 1 T1 #955, 3 T2 #950/#952; 17 struck); worktrees/branches/containers cleaned; record_fix_section_draft.md ready to append: all 27 fixers reported, PRs #922-#948 for #892-#919 + reproduced bullets of #773 #875 #877 #881 #890; landq.sh landing in tier order; where the tracking files are; how to resume landing, closure, record and adjacent filing
metadata:
  type: project
---

Coordinator run in session d9aafdd7 after the user typed `/fix-phase` (pass 8's record PR #921 merged first, main 43d36f7).
Work dir `$WORK` = `/private/tmp/claude-501/-Users-davida-ventimiglia-Work-pg-partition-magician/d9aafdd7-3b4e-43f1-9297-1857dbdb680b/scratchpad/fix8/` (plan.md, groups.json [27 groups: id, tier, wave, closes, part_of bullets, branch, tests, guards, harness, what],
briefs/G*.md, issues/<n>.md [bodies + comments], fixers.tsv [group -> agent id, wave], prs.tsv, landq.txt, gate.lock, fix/<G>/ scratch, landing_notes.txt).
Numbers assigned: core tests 244-271, archive tests 40-41, timescale tests 47-48, guard dbs pgpm_perf217-252 (see plan.md). The pass-8 claims dir
(reproductions) is `.../scratchpad/pass8/claims/`; closure.sh reads it.

**Waves:** wave 1 = G1-G14 (T1 #892 #893 #894; T2 #895-#900; T3 #903+#875, #901+#877, #902, #904, #905+#906), spawned 2026-10-04T20:02:05Z in worktrees;
wave 2 = G15-G27 (#907 #908 #909, #890 bullets, #773 bullet, docs #910+#911, guards #912 #913 #914 #915+#916 #917+#918 #919, #881 bullet) to spawn
as wave-1 fixers report. Landing: append `<tier> <pr>` to landq.txt as PRs arrive; `scripts/review/landq.sh $WORK --batch 5` (merge-commit queue);
seed runs on main for timescale.yml and archive.yml were triggered before spawning. Lessons applied from #882: harness was DOWN before spawning,
briefs name the runner-dependent guards, ask for "every mutation builds" not a count, attribution trailer fixed, permission-stop recovery written in.

**Progress 2026-10-04 22:42Z: ALL 27 FIXERS REPORTED, 27 PRs #922-#948** (prs.tsv has every issue -> PR, test, guard, mutations; landq.txt has every `<tier> <pr>`).
#922 MERGED 21:23Z; the tier-2 batch 924 925 930 932 enqueued 22:10Z (merge group running at 22:42Z); landq.sh (nohup, log landq.stdout) then takes
tier 1 (#934 #937 #942), tier 2 (#935 #946), tiers 3-5. Coordinator decisions recorded in adjacent/G6.md, G10.md, G12.md, G13.md, G25.md (re-anchored
guards; owner-only partition ACL + grantor refusal; NOT VALID incoming key REFUSED so transmute(preserve) after untransmute needs VALIDATE; tests/233
name; descriptive guard DB names). Caveats in caveats.json: F3-03 (#898 repro unsound post-fix) and F6-02 (pass-6 repro, psql without -q).
Interaction checks: #944's key checker passes over #946's archive install (done); #936 and #938 both extend bench/tests_fail_on_defect.sh (add/add
expected at the second landing). Lessons so far: gate.sh is not FIFO (waits of 44 min, 7193 s, 8694 s); merge group starved 50 min behind PR runs
(cancelled 20 queued PR runs outside the batch); fixer agents report "completed" while only waiting on a background gate run (interim notices).
Adjacent observations FILED 2026-10-04 23:05Z: #949-#963 (15 mechanism groups, unverified, pass-7 style) + #964 (method lessons); filed.tsv maps slug -> number; comments posted on #705 and #879. Still to post after landing: #815 (self-referencing policy bullet fixed by #935), #877/#881/#890/#773 (bullets fixed by #926/#938/#946/#947, issues stay open). Verification of #949-#963 (one verifier per bullet against main) happens AFTER the landing, before the pass-9 pin.

**Then:** closure.sh --claims pass8/claims --wait-fix-prs; caveats.json; close_comments.py (--post); fix-phase section in docs/reviews/2026-10-04-pass8.md
+ history row; adjacent observations -> issues (unverified) -> one verifier per bullet before the pass-9 pin; catalogue the pass-8 novel seeds (#920 item 9).
See [[pass8-review]], [[project_fix7_phase]].

**2026-10-05 ~16:00Z:** ALL 27 PRs MERGED (last #944 15:28Z, main e19b362; 18.9 h first enqueue to last merge; median 29 min enqueue->merge; 2 hand conflicts (#945 reference.md + stray test.sh guard entry from #932; #938 shared tests_fail_on_defect.sh, proven locally before push), 2 real CI stops (#930 discriminate interaction regrain_no_outgoing_fk; #931 doc guard false positive on #939 prose), 1 known flake (#930 lock probe), 29 enqueues). Closure on e19b362: 65/72 pass (64 + F4-07 re-run after a random-payload liveness flake), F3-03 caveat, 6 fell claims still fail. close_comments posted; #892-#919 CLOSED; #875 CLOSED (both bullets); notes on #773 #877 #881 #890 #815. NEXT: 41 bullet verifiers (adjv/prompts, verdicts in adjv/verdicts) -> post repro+tier or strike per bullet, close empty issues; then record section (record_fix_section_draft.md + landing_stats) PR; then remove 27 fixer worktrees (.claude/worktrees/agent-*) and local fix/* branches; harness containers (pgpm_test-15/-archive/-timescale) are UP from closure: compose down -v when verification ends.

**2026-10-05 ~15:50Z:** adjacent verification DONE: 41 verifiers (1.84M tokens), 24 confirmed (T1: #955 b1 from_hypertable_copy drops operator tables by name; T2: #950 b2 delta owner after re-own, #952 b1 negative-scale numeric key, #952 b2 pre-#922 NaN claim resumes after upgrade; T3 x11; T5 x9), 17 struck; #953 and #960 closed. Comments + body edits posted. Cleanup DONE (27 worktrees, local fix/* branches, harness down). Record PR #965 MERGED 2026-10-05 17:52Z on the user's call (main 3951b00). PASS 9 can be pinned from 3951b00: the backlog is verified (#949-#963) and the lever/record are in. Pass-9 Tier 1/2 backlog: #955 b1, #950 b2, #952 b1+b2 (+ #872-class leftovers in #890).
