---
name: pass8-review
description: Pass 8 review IN PROGRESS 2026-10-03 (pinned ddf130c): decisions (13 finders / 11 slices / cap 9M; lenses A; K=9 with 3 carried seeds), where the work dir and its helpers are, and how far the pass got; update as it advances
metadata:
  type: project
---

Pass 8 started 2026-10-03 19:38Z in session d9aafdd7 after the user typed `/review-pass` with no arguments.
Work dir `$WORK` = `/private/tmp/claude-501/-Users-davida-ventimiglia-Work-pg-partition-magician/d9aafdd7-3b4e-43f1-9297-1857dbdb680b/scratchpad/pass8/`
(budget.md, notes.md [decisions + timeline], plan.json, sealed.json, seeds/ (6 patches + edits.json), tree/ (seeded b29f0cf, docs/reviews REMOVED),
slices.json + slices_files.json + slices/*.md + slices/F*.units.txt, finder_template.md, render_finder_prompts.py -> prompts/F1..F13.md, finders.tsv,
verifier_template.md, render_verifier_prompts.py, round2_template.md, classify.sh, install_check.sh, harness_up.sh, open.json [49 open issues incl. #874-#881/#890],
contract.md, mkpatch.py, usage.py, run.sh, fresh_*.diff, units_tree_*.tsv, suite.log + suite_work/).

**Decisions (user confirmed via AskUserQuestion):** pin ddf130c (v0.6.0-311, no release); budget option A = 13 finders on 11 slices
(F1-F4 core groups, F5 archive, F6 hypertable+install/upgrade/uninstall+docs, F7/F8 bench halves (split at orphan_guard/orphan_type) + machinery,
F9 fresh surface (98 touched units), F10/F11 tests halves + timescale/archive tests; F12=S5, F13=S8 on fable; the rest opus; 350k-500k each;
round 2 unannounced; cap 9M / 2.5 h); lenses option A = fresh surface, tests-wrong-reason (carried, mechanical count/sum pre-pass in the brief),
failure injection (carried), upgrade and install paths, operator error, contracts versus documentation; seeds K=9 = 3 carried (bench sum-only,
tests/194 count, janitor isolation rebuilt) + 4 novel (S4 archive claims not seeded at install T1 upgrade; S6 _next_archive_chunk without
_control_followed T2 operator; S7 _owned_key lookup-before-claim T1 fresh, two-session) + 3 catalogue (S5 runbook_retain_count_of_intervals T4;
S8 upgrade_child_oid_backfill_noop T3; S9 maintain_no_lock_timeout_after_retain T2).

**Lessons so far:** coverage.py line ranges must be computed from the SEEDED tree (seed deletions shift lines; the first render scored F9 at 23/98);
tests/235 + ts/38 assert column grants, tests/217 widens the key, tests/240 plants namesakes (those lever seeds would be suite-caught);
`upgrade_regrain_mark_block_noop` is loud (`where false`); docs/reviews must leave the tree when seeds are carried.

**RESULT (2026-10-04 ~19:30Z, PASS 8 REVIEW DONE):** 72 claims (52 r1 + 20 r2), 19 seed hits, recall 8/9 = 0.89 (suite-caught 1/1 S6; read-caught 7/8; S1 bench sum-only MISSED a THIRD time: F7 read it, wrote H1, "not attempted" in round 2), precision 0.92 (strict 0.78, fell 6/72 = 0.08), 37 findings (T1 4 claims / 3 groups, T2 6, T3 14, T4 2, T5 11) in 28 groups FILED #892-#919 (T1: #892 capture trigger existence-not-ENABLE-ALWAYS + v0.6.0 upgrade sibling; #893 forget_missing leaves pgpm_detach armed; #894 unqualified drop of pgpm_dbatch/pgpm_htail; T2 #895-#900 incl. #896 the null-argument class of 6 claims), 10 known_open re-finds commented on #773 #875 #877 #881 #890, 6 fell. Coverage 1.00 everywhere (F9 0.62 + F9r 1.00; coverage.py case bug on F6 files). Tokens 7.49M (finders 5.21M, verifiers 2.28M). Record docs/reviews/2026-10-04-pass8.md + history row = PR #921, MERGED 2026-10-04 through the queue. Lessons #920. Harnesses DOWN. Novel seeds (seeds/*.patch + edits.json) still to catalogue. Capture-recapture undefined (S8 opus 1 T1 in the re-run half, fable 0). Stopping: NOT met (T1 > 0); recall/precision/fell met for the first time since pass 5.
Next: /fix-phase with pass8/claims (28 issues #892-#919 + the 5 re-found issues' bullets), then catalogue the seeds, then the pass-9 pin after the backlog (#890 residue, #874-#881) is verified.
See [[pass7-review]], [[project_lever_phase_pass8]].
