---
name: pass7-review
description: Pass 7 review DONE 2026-10-02 (pinned 4060f6b); precision REDEFINED + backlog-before-pin rule (PR #851 MERGED 2026-10-02): 35 findings (6 T1 claims in 5 groups) in 28 groups #821-#848, 23 known-open re-finds commented on 9 issues, recall 5/9 (the four CARRIED seeds missed again), strict precision 0.64 (0.97 counting re-finds), round 2 (hypothesis build-out) added 14 findings incl. 3 T1; record docs/reviews/2026-10-02-pass7.md = PR #850 MERGED 2026-10-02 14:49Z (main 009d759); lessons #849; fix phase NOT started
metadata:
  type: project
---

Pass 7 ran 2026-10-02 10:0xZ (prep) / 10:58Z (hunt) to 11:49Z (last verdict) in session 4a6b7a35 after the user typed "Start pass 7".
Work dir: `/private/tmp/claude-501/-Users-davida-ventimiglia-Work-pg-partition-magician/4a6b7a35-4911-4de6-a2ef-350d9101957c/scratchpad/pass7/`
(tree, claims/, classified.json [the FINAL re-classification, run after verification so repro.verified.* count], verdicts.json [F10-01's verdict
kept aside in verdicts_aside/: it became seed hit S9], sealed.json, seeds/ (4 novel + 4 carried patches), groups.json, issues/filed.json,
known_open/, notes.md, notes_record.md, root_causes.md, lessons_issue.md, tokens_harness.tsv, verifiers_tokens.tsv, per_finder.tsv,
round1_claims.txt, round2_claims.txt, agents.tsv, verifiers.tsv). closure.sh for the fix phase reads pass7/claims.

**Decisions:** pin 4060f6b (v0.6.0-254, no release); budget = passes 3-6's (F1-F8 opus on S1-S8, F9 fable on S7 = bench, F10 fable on S8 =
fresh surface) PLUS a bounded ROUND 2 (each finder handed its own null-results hypotheses, ~15 min/100k, uniform and blind, not announced in
the brief) adopted from #797 item 3; lenses fresh surface, tests-pass-wrong-reason (carried), failure injection (carried), identity and names,
concurrency and locks, resource cliffs (in; exactly half differ from pass 6). Seeds K=9: 4 CARRIED (pass 6's missed novel patches re-planted
verbatim: bench sum-only, tests/194 count, janitor isolation, regrain analyse), 4 novel (reclaim lock after reads, shape drift ignores NOT NULL,
pgpm_key clash PK-only, untransmute restored by search_path T1), 1 catalogue (archive_encode_array_agg_unnest). All 9 read-caught (suite controls
clean: core 202, archive 28). MinIO bucket created by hand (#797 item 1 still open).

**Result:** 69 claims (45 round 1 + 24 round 2), 9 seed hits, 60 candidates -> 35 findings (T1 6 claims: #821 archive row_to_json(t) alias,
#822 object key reused after drop, #823 object stem drops BC, #824 shape drift misses value-changing DDL (F3-07+F3-10), #825 reads under the
caller's RLS (hypertable copy T1 + transmute bound T3); T2 1 group #826 control column renamed wedges obtain; T3 17 groups; T5 5 groups incl. #844
hypertable_time_rendering.sh pre-#795 verdict), 23 known_open on #555 #632 #768x3 #769x2 #814 #815x4 #816x5 #817x5 #819 (commented with repros;
re-tier recommendations: #816 publication bullet -> T1, #769 BC floor -> T2, #555 -> T1 with a stranger), 3 fell (F9-04 hypothetical; F1-09
undocumented hand edit; F10-01 = seed after rebuild). Recall 5/9 = 0.56 AGAIN: every novel seed found (S9 by three finders), every carried seed
missed, and this time none was even a hypothesis (S1, S2 unreached; S3, S4 read and judged sound: a seed with its own justifying comment is read
as correct). Round 2: 14 findings (3 T1), 8 known_open, 2 fell, 0 seeds, ~1.05M tokens: cheap and productive, does NOT repair a blind spot.
Model split: no new T1 on either duplicated slice (capture-recapture 0 there, undefined for the tree; the 5 T1 groups came from S3, S5, S6).
Tokens: finders 2,630,564 (harness counts; 128k of it round 2), verifiers 61 runs 2,331,774, total 4,962,338 (under the 5M cap).

**Measurement lessons (filed #849):** strict precision 0.64 < 0.7 is the known-open backlog (#813-#819, #766-#775 filed unverified days before),
not reaching (only 3 fell); a claim bundling a seed with a real defect loses the seed attribution (F7-03, F10-02); a seed claim with an unsound
pristine assertion reads as candidate until a verifier rebuilds (F10-01: regclass::oid constant bound at plan time); re-run the FULL
classification after verification; the exact `LIVENESS:` prefix (F3-02 wrote `LIVENESS A:`); fleet image segfaults on `grant ... to current_user`;
pass-6 and pass-7 novel seeds still uncatalogued.

**How to apply:** stopping criteria NOT met (T1 5 groups, recall 0.56, strict precision 0.64): earliest stop now after pass 10. Fix phase next
(`/fix-phase` with pass7/claims; 28 issues #821-#848, T1 first #821-#825). Before pass 8: verify or close the known-open backlog first (or count
verified re-finds as true), build the mechanical cardinality pre-pass for the S1/S2 shapes, catalogue the seeds, add round 2 to the skill. See
[[pass6-review]] and [[convergence-before-pass6]].

**Decisions after the pass (2026-10-02, user accepted both recommendations):** (1) precision = (findings + seed hits + verified
known-open re-finds) / claims, strict figure beside it, FELL RATE (<= 0.3) is the reaching alarm; stopping criterion 3 and the abandon rule
(fell rate > 0.5) changed; passes 2-6 recomputed read 1.00/0.97/1.00/1.00/1.00; pass 7 = 0.97 (strict 0.64, fell rate 0.03). (2) The
backlog is verified before the pin: a fix phase's adjacent observations get one verifier per bullet before the next pass; re-found issues
with reproductions join /fix-phase's default list. Written into docs/adversarial-review.md, pass_metrics.py (+selftest), scripts/review/README.md,
both skills, and the pass-7 record: PR #851 (MERGED 2026-10-02 after #850; both branches deleted). #849 commented with the decision. Why the slide happened: the known-open share of claims rose 0 -> 33% (fixers' unverified
adjacent-observation issues #705-#713, #766-#775, #813-#819), while fell stayed 0-4%.
