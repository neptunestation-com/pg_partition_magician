---
name: project_lever_phase_pass8
description: Lever phase before pass 8 (started 2026-10-03, tracking issue #884): one lever per Tier 1 class with an exhaustiveness check, four workstreams W1-W4, scratch lever8/; why pass 8 waits
metadata:
  type: project
---

**Decision (2026-10-03):** the user accepted the convergence assessment after the pass-7 fix phase: NOT converging
(Tier 1 2 -> 4 -> 5 across passes 5-7, plus 5 more from the fix-phase verification; recall 0.56 twice; strict
precision 0.64). Nearly every Tier 1 since pass 5 is one of four CLASSES fixed site by site. So: no pass 8 yet; build
one lever per class with an exhaustiveness check, fix the five open Tier 1 through them, then pass 8 with a
full-slice-reading brief. Earliest stop under the written criteria: after pass 9.

**Tracking issue #884.** Scratch `$W2` = `.../scratchpad/lever8/` (plan.md, briefs/W1-W4.md + COMMON.md,
issues/872|873|878.json, prs.tsv, landq.txt, gate.lock). Acceptance tests = the verifiers' reproductions in
`.../scratchpad/fix7/verify/A872-*/A873-*/A878-2/repro.verified.*`.

| W | lever | closes | branch | numbers |
|---|---|---|---|---|
| W1 | recorded identity (regrain copy sites, dropped_fk identities + restore render, uninstall exemption by confrelid, hypertable copy index by indrelid) + moved-parent conformance suite | #872 b1-b4 | fix/lever-recorded-identity | tests 239, 240, ts 45; pgpm_perf211 |
| W2 | `_refuse_filtered_reads` at every row-reading entry point on the relation actually read + under the cutover lock + RLS conformance suite enumerating entry points | #873 b1-b3 | fix/lever-reads-under-rls | tests 241, 242, ts 46, archive 38; pgpm_perf212 |
| W3 | one archive key function consulting object_key_owner for every path + static single-assembly check | #872 b5 | fix/lever-archive-object-key | archive 39; pgpm_perf213 |
| W4 | null regrain_source_mark across #858 upgrade: restart, never adopt; upgrade_in_place stage | #878 b2 | fix/lever-regrain-mark-upgrade | test 243; pgpm_perf214 |

**DONE 2026-10-03 ~11:00Z:** #885 #886 #887 #888 ALL MERGED (main bc7517e at #888; 2h11m, no hand conflicts); closure on bc7517e: 8/9 verifier repros pass, 3 stated caveats (A872-1 L3, A872-2 checks 5/10, A873-1 GUARD 5; tests 239/240/242 stand in); #872 #873 #878 CLOSED; residue issue #890 (uncovered sites, verify before pass-9 pin); record PR = docs/lever-phase-record branch. #889 (ledger) and #891 (record) MERGED 12:34Z. **PASS 8 PIN = ddf130c** (main at the #891 merge); pass 8 runs with the coverage ledger (skill step 4b). Also #889 = the pass-8 recall fix (finder coverage ledger + scripts/review/coverage.py, step 4b in the skill, slice-coverage metric), all queued via lever8/landq.txt.

Open after this phase for an ordinary fix phase: confirmed T3-T5 bullets of #874-#877, #879, #881.

**Why:** if context is lost, resume from `$W2/prs.tsv`/`landq.txt` (landing via `scripts/review/landq.sh $W2 --batch 5`
with `LAND_TOOLING` unnecessary now that #883 carried the flake signature), then closure-style re-run of the four
reproductions on main, comments on #872/#873/#878 (+ close #878 if nothing left), record note in the pass-7 record
or a short docs note, then pin pass 8.
