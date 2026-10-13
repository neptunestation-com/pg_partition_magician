---
name: pass9-review
description: Pass 9 review DONE 2026-10-06 on pin 06643c8: recall 0.89 (read-caught 5/6), precision 0.96 (strict 0.90, fell 0.04), 80 claims, 44 findings in 31 groups #974-#1004 (5 T1 claims / 4 groups), re-finds on #639 #713 #766 #956, lessons #1005, record PR #1006 MERGED 2026-10-06 16:16Z (main b38114b); where the work dir is; what the fix phase inherits; the planting errors to avoid next pass
metadata:
  type: project
  modified: 2026-10-06T15:30:00.819Z
---

Pass 9 ran 2026-10-06 in session 7973082a (job 8d94cdfa) after the user typed `/review-pass` with no arguments and chose,
via AskUserQuestion, option A three times: pass 8's budget shape (13 finders / 11 slices, S6 + S8 duplicated on fable, cap
9M / 2.5 h), lenses = fresh surface + identity and names + concurrency and locks + boundary arithmetic and types + upgrade
and install paths + tests-pass-wrong-reason (4th carry), seeds = 1 carried (bench sum-only) + 5 novel + 3 catalogue.

Work dir `$W` = `/private/tmp/claude-501/-Users-davida-ventimiglia-Work-pg-partition-magician/7973082a-3d70-45f2-b802-db02d6377fdc/scratchpad/pass9/`
(budget.md, notes.md [timeline], plan.json, sealed.json, seeds/ (5 novel patches + edits.json, UNCATALOGUED), tree/ (seeded
0b06438, docs/reviews stubbed), slices.json + slices_files.json + slices/, prompts/F*.md, finder_template.md, round2/, verify/,
verdicts/ + verdicts_aside/ (3 seed-reached "fell" verdicts kept aside), verdicts.json, classified.json (3 hits hand-attributed
to S7 with a note), coverage.json, per_finder.tsv, tokens_harness.tsv, verifiers_tokens.tsv, groups.json, issues/ + filed.json,
known_open/, lessons_issue.md, write_notes.py -> notes_record.md, root_causes.md, suite.log).

**Result:** K=9, recall 0.89 (suite-caught 3/3: S5, S7, S8; read-caught 5/6), precision 0.96 (strict 0.90, fell 0.04), 80 claims
(30 from round 2), 44 findings: T1 5 claims in 4 groups (#974 scratch mint leaves the delta's pgpm_seq SEQUENCE at default
privileges: a stranger's setval makes the swap drop rows; #975 archive direct-call guard checks shape not the ledger's chunk:
a direct archive_to_s3_* after retire or with a shorter range overwrites the only copy; #976 export claim keyed by parent oid
only; #977 _archive_step stores raw offset-less covered_hi, retire in another zone drops an unarchived row), T2 2 (#978 replica
identity index dropped wedges obtain; #979 hypertable delta grants never re-synced), T3 16, T4 3 (README DEFAULT bullet), T5 18
(nine count-for-identity tests the fix phases wrote: 267, 247, 178, 140, 77, 79, 219, ts/05, the regrain conservation files).
Known-open re-finds: F2-01 #639 (T1 by consequence), F7-03 #713, F1-04 #766, F9-07 + F13-08 #956. Fell 3 (F11-05, F12-06,
F10r-04). Coverage: all slices >= 0.9 after re-runs F10r (93 unread tests files -> 3 T5) and F6r (7 docs -> 2 T3 + T4 + 2 r2 T3);
coverage.py still cannot match capitalised file names (#920 item 2 unfixed). Model split: S6 opus 0 T1 / fable 0; S8 opus 0 /
fable 0: capture-recapture 0 with nothing to divide; all T1 from single-finder slices S3, S4, S5. Tokens 7.97M (finders 5.70M,
verifiers 2.27M / 55 runs); hunt 14:49Z-15:57Z. The carried S1 was FOUND on its 4th planting (F7-01, round 1) via the brief's
"build every pre-pass line marked claimed first" rule.

**Planting errors to avoid (lessons #1005):** (1) catalogue mutations carry `-- MUTANT` markers in replacement text: strip them
(S8, S9 were read as "probably a planted seed" by 4 finders); (2) `untransmute_no_recheck_under_lock`'s regex now removes
untransmute's whole lock-and-capture block (drifted since #767): re-anchor the mutation; 20 pgTAP files catch it, 5 claims filed
its consequences; (3) S4 (anchor half of _id_step_contract) was MASKED by _control_bound_contract: demonstrate a novel seed's
consequence on the seeded tree before sealing (plant_seeds.py --prove); (4) plant_seeds.py --suite is block-buffered under nohup
(run python3 -u); (5) verifiers returning "fell" for a seed-reached claim must store a rebuilt repro that passes on pristine
(F9-02, F12-02 needed a follow-up message); (6) repro roles must be `create role if not exists` (cluster-wide, two trees);
(7) tests slice B = 180 files is too big (F11 893k tokens): three tests slices next pass; (8) render ALL round-2 briefs at hunt
start (F8's was missed).

**Next:** record PR #1006 MERGED (main b38114b); then `/fix-phase` with `$W/claims` for #974-#1004 plus the
reproduced bullets of #639, #713, #766, #956; catalogue the 5 novel seeds ($W/seeds) + re-anchor the S7 mutation; fix #920 item 2
(coverage.py case folding). Stopping criteria: T1 > 0 again (5 claims), so earliest stop after pass 11 under the written rules;
recall/precision/fell met. See [[pass8-review]], [[project_lever_phase_pass9]].
