---
name: pass6-review
description: Pass 6 review + FIX PHASE DONE 2026-10-02 (pinned ae5dddc): 23 findings (5 T1 claims in 4 groups) in 19 groups #778-#796, 9 known-open re-finds commented, recall 5/9 (read-caught 3/7, the first below 0.8: three missed seeds were finders' hypotheses), precision 0.78, nothing fell; record docs/reviews/2026-10-01-pass6.md on branch docs/pass-6-record; where the work dir is; fix phase NOT started
metadata:
  type: project
---

Pass 6 ran 2026-10-01 18:43Z (prep) / 19:32Z (hunt) to 20:08Z (last verdict) in session 419fd648 after the user typed "start pass 6".
Work dir: `/private/tmp/claude-501/-Users-davida-ventimiglia-Work-pg-partition-magician/419fd648-93a8-4e0a-a99c-8061bbd9b605/scratchpad/pass6/`
(tree, claims/, classified.json, verdicts.json, sealed.json + seeds/ (nine novel patches), groups.json, issues/filed.json, known_open/,
notes.md, notes_record.md, tokens.json, agents.tsv, verifiers.tsv). closure.sh for the fix phase reads pass6/claims.

**Decisions:** pin ae5dddc (v0.6.0-220, no release); budget = passes 3-5's (F1-F8 opus on S1-S8, F9 fable on S7 = bench guards alone,
F10 fable on S8 = fresh surface); lenses fresh surface, tests-pass-wrong-reason (carried), time and zones, boundary arithmetic, operator
error, failure injection (four rotated in). Nine novel seeds, 7 read-caught by the suite check.

**Result:** 41 claims, 9 seed hits, 32 candidates -> 23 findings (T1 5 claims: #778 _retain_recall in the parent's schema after SET SCHEMA
(3 claims, RC1), #779 views follow the renamed oid into the monolith, #780 untransmute drops the parent's publication membership, #781
NDJSON floats follow extra_float_digits; T2 8; T3 8; T5 2) in 19 groups #778-#796, 9 known_open on #712 #713 #766 #767 #768 #769 #773
(commented with repros, incl. a wording correction for #769), 0 fell. Precision 0.78 (1.00 counting re-finds). **Recall 5/9 = 0.56,
read-caught 3/7**: missed S1 (regrain analyse pre-c2d7ec8; F8 had it as a hypothesis), S3 (bench sum-only; F9 argued it down as a
hypothesis), S4 (tests/194 count-only; read by three finders, judged sound), S8 (janitor isolation; F4's hypothesis). Capture-recapture
on S8: both models found RC1 and nothing else at T1 (estimate 0 there); three T1 groups came from single-finder slices. Model split: on
the bench slice opus and fable found two different T5s; on fresh surface fable's 4 claims = 2 seeds + RC1 + a #768 re-find.

**Tooling/method lessons** filed as #797: the archive profile comes up WITHOUT its MinIO
bucket (test.sh/closure.sh create it; the skill does not say so) and the first suite check's archive control failed 19/27 files, sealed as
"noise"; `--suite` should refuse a broken control; seed-shaped hypotheses; record filename collision for two passes a day.

**Fix phase DONE 2026-10-02 06:54Z:** 14 PRs #799-#812 all MERGED (main 107da01); closure 33/41 on 107da01 (every finding + 9 seed hits +
F7-03 whose #712 bullet #807 closed; the 8 still failing are re-finds of #766 #767 #768 #769 #713 #773, out of scope), closure comments
posted on #778-#796, notes on #712/#643. Landing: 93-min median/PR, 9.7 h wall for 14; one hand merge (reference.md #801 vs #811); TWO
real CI failures repaired at landing by the coordinator (tests/208's throws_like spliced a bare `:var`, throws_pinned.sh needs `:'var'`;
#806's two new timescale wrappers lacked #807's verdict block: interaction caught by the new guard); two false stops from the coordinator's
mistaken push (check runs are per SHA and leak across PRs; re-running cancelled runs under a PR's concurrency group cancels its live runs);
one #556 flake. Adjacent observations filed #813-#819. Record's fix-phase section + pass-history row on branch docs/pass-6-fix-phase
(PR #820 MERGED 2026-10-02, main 4060f6b). Worktrees and merged branches removed; harnesses down. Scratch: fix6/ (plan.md, prs.tsv,
landq.stdout, landing_stats.txt, landing_notes.md, closure.json, comments/, adjacent.md, caveats.json).

**How to apply:** stopping criteria NOT met (T1 4 groups; recall 0.56 < 0.8): the two-pass count does not start; pass 7 must carry the four
missed seed shapes (and read [[convergence-before-pass6]] expectations: it predicted 1-3 T1, got 4 groups). See [[pass5-review]] for the
previous shape.
