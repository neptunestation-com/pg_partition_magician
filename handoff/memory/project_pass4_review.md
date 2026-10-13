---
name: pass4-review
description: Pass 4 review + fix phase DONE 2026-09-30: 32 findings (7 T1) #649-#676 + 8 known-open all FIXED (PRs #680-#704), closure 66/69 on main ff01584, record PR #718 MERGED 15:20Z; landing lessons (batching lost wall clock, pg_stat_activity snapshot class on #713); pass 5 must rotate lenses
metadata:
  type: project
---

Pass 4 started 2026-09-29 when the user typed `/review-pass b52a0d9 9 fresh-surface, concurrency, time-zones,
boundary-arithmetic, upgrade-install, operator-error, failure-injection, resource-cliffs`. Pinned
b52a0d9703dedbd9040ca11e6d12f1f42d4d808e (v0.6.0-97-gb52a0d9: main after the pass-3 fix phase #603-#626, record
#645, prep PRs #646-#648). Fresh surface: 33 commits, 29 of 103 core functions touched (3 new: _id_label,
_obtain_name, _regrain_step_forward), tests/130-156, archive db/18-24, timescale db/21, 43 new bench guards.

**Lenses are the same eight as pass 3, deliberately.** The methodology says at least half must differ; the
maintainer chose to re-run the method unchanged on the pass-3 fixes to see whether Tier 1 falls (recorded as
a deviation in the record). Only 3 catalogue lenses were unused in pass 3, so the rule was satisfiable only
with <= 6 lenses.

Budget = pass 3's (comparable cost per finding): 10 finders (F1-F8 opus; F9 = S3 dup and F10 = S8 dup on fable),
~350k tokens / 45 min each; verifiers opus medium; target <= 5M tokens. No budget was given in the command;
the pass-3 budget was adopted and stated.

Work dirs (session scratchpad 2f0a72a3-...): `pass4/` (tree, claims, slices, prompts, verify, verdicts,
fresh_surface.json, core_functions.txt, render_verifier_prompts.py, usage.py) and `pass4_sealed/`
(plan.json, sealed.json, seeds/ = 3 novel patches, budget.md, finders.tsv, agents.tsv, open.json = 23 open bug
issues, hunt_start.txt). Harness: pgpm_test-15 (core) and pgpm_test-archive + minio (bucket
archive-test-bucket) both up from main.

Seeds (sealed; never show finders): S1 transmute_publication_not_carried (S1 slice, T1), S2
grid_floor_month_later_midnight (S2, T2), S3 regrain_restart_needs_cursor (S3, T1), S4
maintain_all_fixed_sweep_order (S4, T2), S5 parquet_numeric_scale_unsigned (S5, T1), S6
uninstall_keeps_regrain_copies (S6, T3), S7 novel set_retain would-drop guard strict (hi < horizon misses
hi == horizon; S4, T3, operator error), S8 novel regrain() takes SHARE UPDATE EXCLUSIVE instead of SHARE
(#580 deadlock back; S3, T2, concurrency; side_effects declared), S9 novel _check_text_time_collation returns
early for the database default collation (S2, T1, boundary). Rejected novel ideas worth remembering: an
obtain() loop fencepost (too global: every fixture's forward grid shrinks, pollutes attribution), a stale
`_part_name` overload drop (v0.6.0 shipped the 5-arg shape and no caller passes 5 args, so inert).

**How to apply:** after the finders report: `classify_claims.py --finders F1,...` per finder as each finishes
(pipeline verifiers behind finders as pass 3 did), `render_verifier_prompts.py classified.json` then one
verifier Agent (opus) per candidate, `jq -s add verdicts/*.json`, `pass_metrics.py --pass 4`, groups.json,
`file_issues.py`, record PR under docs/reviews/2026-09-29.md, then the 3 novel seeds need guards+mutations
in the catalogue. See [[pass3-fix-phase]] and [[pass3-prep]] for the previous pass's shape.

**RESULT 2026-09-29 18:29Z (last verdict):** 69 claims, 27 seed hits (recall 9/9), 42 candidates, 32 findings (T1 7 /
T2 12 / T3 12 / T4 1) in 28 root-cause groups filed as #649-#676 (T1 #649-#655), precision 0.86 (formula counts the 10
known-open re-finds as misses; nothing fell, so reaching-adjusted 1.00). Known-open re-finds commented with repros on
#551, #552 (re-tier to 2), #554, #628, #630, #631 (re-tier to 1), #636, #641. One rebuilt repro (F9-04). Budget 3.68M
tokens (finders 2.05M, 42 verifiers 1.63M), 32 min hunt-to-last-verdict. Record: docs/reviews/2026-09-29.md, PR #677
(branch docs/pass-4-record) OPEN, not enqueued (maintainer's say-so, as for #645). Model split: F8 (opus, fresh
surface) ran the whole test suite on the tree and found all 9 seeds and nothing else in 12 min; F10 (fable) found 5
seeds by reading + 1 real T2. Method lesson: every seed had a test-file guard, so recall measured "suite was run";
pass 5 should plant seeds no test catches or split recall into suite-caught/read-caught. Tooling fragilities met
(classifier crashes on a half-written claim.json anywhere under --claims even with --only; archive claims need
container defaulted from install list; verifier brief lacked the classifier command): worked around with
pass4/claims_final staging + classify_finder.sh + sealed_for_verifiers.json; fixes owed to scripts/review.

**Pass 4 owes:** (1) DONE: the 3 novel seeds are in the catalogue as set_retain_strict_horizon /
regrain_sync_share_update_exclusive / text_time_collation_default_trusted with guards bench/set_retain_horizon.sh,
bench/regrain_writer_waits.sh, bench/text_time_default_collation.sh (tests/98, 149, 122), PR test/novel-seeds-pass-4
OPEN, discrimination proven locally on PG 15; (2) the classifier/verifier tooling fixes above, filed as #679 (unverified, coordinator observations); (3) the
fix phase (/fix-phase over #649-#676, T1 first; RC groups in pass4/groups.json); (4) pass 5 MUST rotate lenses
(identity and names, contracts versus documentation, tests that pass for the wrong reason + fresh surface).

**FIX PHASE 4 STARTED 2026-09-29 18:55Z** (user: "start the fix phase, classes first"; the /fix-phase skill is user-launch
only, so I follow its checklist directly). Work dir scratchpad/fix4: plan.md + plan.json (24 groups: C1-C7 root-cause
CLASSES incl. open issues that complete them: C1 #653+#673 count-only conservation, C2 #656+#666+#630 captured-before-lock,
C3 #655+#663+#552 63-byte names, C4 #554+#660 setters mid-regrain, C5 #674+#641 set_regrain validation, C6 #657+#665
no lock_timeout, C7 #662; singles S1-S17 incl. verified re-finds #631, #551, #628, #636), briefs/*.md, fixers.tsv
(agent ids), prs.tsv, landq.txt (empty until PRs arrive), gate.lock (scripts/review/gate.sh mutex; EVERY ./test.sh run
goes through it). Assigned: tests/157-182, archive/db/25-28, timescale/db/22-26, pgpm_perf86-122; next free tests/183,
archive 29, timescale 27, perf123. Fixers run their own containers pgpm_fix_<G>[_a|_t] on pgpm_test_net (minio alias
there, bucket archive-test-bucket). Wave 1 (C1-C7 + S1-S7) spawned 18:55Z; wave 2 (S8-S17) pending. land.sh --batch
677 678 running detached (log scratchpad/land_677_678.log; both hit the #556 lock-guard flake, auto-rerun). Then:
landq.sh fix4 --batch 5 (append `<tier> <pr>` to landq.txt as fixers report), closure.sh, close_comments.py, record
fix-phase section, adjacent-observation issues.

**FIX PHASE 4, fixers DONE 20:43Z:** 25 PRs #680-#704 (S13 made two: #691 + #701 for #668 after a coordinator decision to
rewrite tests/112/128/140's fixtures to a two-session lever) covering all 36 issues; all in fix4/landq.txt; #688 released
by the maintainer 20:37Z. #677 (record) MERGED 19:50Z, #678 (seeds) MERGED 20:25Z. landq.sh --batch 5 running detached
(log fix4/landq.log); first tier-1 batch 680 682 683 686 693 needed one hand-resolve (#693 docs/reference.md vs #682).
Incidents for the record: pass harness containers blocked gate.sh (exit 7) until 19:14Z; a failing gated run leaves
pgpm_test-15 up (19:37Z); fix_minio's `minio` alias collided with compose's on pgpm_test_net (moved to fix_net 20:00Z);
CI storm starved the merge-group summary jobs (cancelled queued fix/* PR runs twice, 19:50Z and 20:20Z). Accepted
deviations/behaviour changes: C4 pgpm.regrain_lock table (#688); C3 renames over-long capture names to oid form instead
of refusing (#697); C6 p_lock_timeout param on from_hypertable* (#684); S5 MVCC-horizon refusal (#698); S7 UTC key stem +
schema-qualified key (#702); S12 pgpm.config.monolith_oid column (#703); S16 transmute_inflight.control_attnum (#695);
S13 time-kind frontier = greatest(max, now()) (#701). Closure caveats so far: F1-02/F1-03 unsound (psql INSERT echo),
F4-03 needs the upgrade variant, F1-15 passes for a second reason. Adjacent observations in fix4/adjacent.md (to file
grouped by mechanism, unverified). Next: watch landq (re-arm Monitor), closure.sh --wait-fix-prs, caveats.json,
close_comments.py --post, record fix-phase section (docs/reviews/2026-09-29.md) + pass-history row, adjacent issues,
remove worktrees (.claude/worktrees/agent-*).

**Landing + follow-ups (23:1xZ):** 5 fix PRs merged (#680 #682 #683 #686 #693); batch 697 698 699 702 in the queue (#699
hand-merged against #698: interaction in from_hypertable_cutover's conservation check, row-naming refusal ordered first,
timescale track PASS on the merged tree). Adjacent observations FILED as #705-#713 (8 mechanism groups + #713 harness
lessons, all label bug, unverified). Still owed: closure.sh --wait-fix-prs after the last merge, caveats.json (fix4/),
close_comments.py --post with fix4/filed_plus.json (adds the 8 known-open issues), record fix-phase section + history row
(docs PR), worktree cleanup, memory final.

**Landing status 2026-09-30 08:45Z:** 21 of 25 fix PRs MERGED (680-690, 693-699, 702, plus 685; harness #714 here-string
guards, #715 landq empty-array fix, record #677/#678). OPEN: #700, #704 (tier 3, batch stopped on a tests/160 flake),
#691/#701/#703 (tier 3, re-queued after #691's fixer hand-merged it against #689), #692 (tier 4 docs), and coordinator
#716 (tier 0: tests/160 pinned its clock once via \gset; first push was broken because the replacement rewrote the gset
line and `| tail` masked the failing exit; amended 7d04c15 after a checked 28/28). landq.sh restarted 08:41Z, Monitor
re-armed. Draft of the record's Fix phase section: fix4/record_fix_phase.md (TODO_ markers for last merge, pace,
batches, keep_both counts, closure). Interactions: #699 vs #698 (coordinator hand-merge, timescale PASS), #691 vs #689
(fixer S13 hand-merge, head 2efc5a1). Hand-resolves: 693, 699, 684, 688, 695, 696, 704 (mine), 691 (fixer). Flakes:
restore_fk_lock (#677 group), tests/116 (#698), tests/166 (#694), tests/160 minute boundary (#700, real -> #716);
stuck queue entry #699; dropped enqueue #694. Remaining after landing: closure.sh --wait-fix-prs, close_comments.py
(--post), record docs PR (draft above + history row), worktree cleanup (.claude/worktrees/agent-* and /private/var/.../land-*),
memory final, ping user.

**09:20Z:** #716 MERGED 09:10Z. Tier-3 batch 691 700 701 703 704 running (landq restarted 09:19Z, Monitor armed); #703
hand-resolved by me (f8beb89: two same-spot add/add hunks in core install vs #688/#689 + test.sh list; 12 untransmute
tests PASS on merged tree). #685 needed a hand-added "merged" line in landq.done (batch-stop bookkeeping gap, as #697).
Shell gotchas this session: the Bash tool runs zsh (for-loops over $(...) do not word-split: use `bash script.sh`),
and a tree-wide marker grep matches scripts/review/keep_both.py's selftest strings (scope it to the resolved files).
Then #692 (tier 4), closure, comments, record PR, cleanup of the 5 remaining agent worktrees + land-691/704, ping.

**09:55Z:** #701's head failed tests/166 'backend is gone' (3rd time today). ROOT CAUSE FOUND: pg_stat_activity is frozen
per transaction after its first read (documented snapshot), so a plpgsql poll loop never sees a backend leave; fixed for
tests 116/166 by #717 (perform pg_stat_clear_snapshot() each turn), tier 0, landing now before batch 691 700 701 703 704.
CLASS recorded on #713: tests 109/157/158/162/163 + bench maintain_lock.sh, regrain_outgoing_fk_lock.sh (= the #556 flake
signature!), retire_detach_lock.sh all poll pg_stat_activity in one transaction without clearing. Worth a follow-up PR with
re-proven discrimination. Draft record section updated (fix4/record_fix_phase.md).

**12:58Z: ALL 25 FIX PRs MERGED** (#704 last, 12:55Z; #691 11:17, #700 11:42, #701 12:01, #703 12:36 after a registry flake +
hand enqueue on GraphQL errors). #692 (docs, tier 4) landing now via landq. Early closure run started 12:56Z against main
784c5f4 (closure_pre.json/.log, NOT the official one: rerun after #692 merges for the record's SHA). Landing stats so far:
28 merged via landq, median 121 min start-to-merge; keep_both 56 (CHANGELOG 27, mutate.py 17, test.sh 12). Remaining:
#692 merge -> official closure.sh -> close_comments.py (--post) -> record PR (draft fix4/record_fix_phase.md + history row)
-> cleanup (5 agent worktrees now all merged, land-691/704, pgpm_coord container, fix_minio, compose harness) -> ping.


**FIX PHASE 4 DONE 2026-09-30 13:27Z (last merge #692).** 25 fix PRs #680-#704 MERGED; coordinator harness PRs #714 (here-string
guards), #715 (landq empty array), #716 (tests/160 clock), #717 (tests/116+166 pg_stat_activity snapshot) MERGED. Closure on
main ff01584: 66/69 not_reproduced; F1-02/F1-03 known unsound (INSERT echo), F4-03 liveness caveat. Evidence comments posted on
all 36 issues by close_comments.py (prs_issues.tsv = prs.tsv minus the non-numeric 'harness' row, which breaks load_prs). Six
issues (#636 #667 #668 #672 #675 #676) were NOT auto-closed by their merged PRs' Closes lines (GitHub; the 30 earlier were) and
were closed by hand with a comment. Record PR #718 (branch docs/pass-4-fix-phase) OPEN: do not enqueue without the maintainer's
say-so. Landing measured: median 127 min/PR (mostly queue position: one group per PR, ~17 min steps), wall clock 16.2 h for 25
PRs = 39 min/PR vs pass 3's 27 one-at-a-time; 14 stops, 9 hand-resolves (6 same-spot add/add), 2 code interactions; three loop
changes recorded on #713 (enqueue each PR when ITS head is green; multi-PR groups; add/add resolver in any file).

**Open class for a follow-up (on #713):** every plpgsql loop polling pg_stat_activity without pg_stat_clear_snapshot() cannot
observe change (tests 109/157/158/162/163; bench maintain_lock.sh, regrain_outgoing_fk_lock.sh = the #556 flake signature,
retire_detach_lock.sh). Fix together, re-prove each guard's discrimination.

**Pass 5 owes:** lens rotation (identity and names, contracts vs documentation, tests that pass for the wrong reason, + fresh
surface); seeds no existing test catches (recall 9/9 measured "the suite was run"); tooling fixes from #679 and #713.
Cleanup done: all fixer worktrees, land-* worktrees, merged local branches, compose harness, pgpm_coord, fix_minio, fix_net.
- record PR #718 MERGED 2026-09-30 15:20Z (enqueued at the maintainer's word; main 30bfc35). Pass 4 fully closed.
