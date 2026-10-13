---
name: project-adversarial-review-method
description: "pgpm's measured bug-hunt method (docs/adversarial-review.md, #491 merged 2026-09-25) and its tooling (scripts/review/, finder+verifier agents, /review-pass skill, PR #492): seeds, precision, stopping criteria; pass 2 is next, model-tier split planned"
metadata:
  type: project
  originSessionId: e3676f1f-5dd0-49b1-884e-c5176eaa0ec4
  modified: 2026-09-25T15:22:00.353Z
---

After the 2026-09-24 hunt ([[project-bug-hunt-2026-09-24]]) the user asked for a methodology and
stopping criteria before "turning the crank again", worried that (a) bug yield asymptotes to a
non-zero floor and (b) a model pushed for bugs will hallucinate or manufacture them. Agreed shape,
written as `docs/adversarial-review.md` (PR #491, MERGED 2026-09-25, main c5a60df):

- a finding is an executable reproduction that fails on the pinned commit and survives an independent
  verifier; else it is a hypothesis, never counted or filed
- roles separated: coordinator / finder / verifier / fixer; finder never sees seeds, bench/mutations,
  the pristine tree or other finders; verifier never sees the finder's reasoning
- **seeds**: K blind known defects (from bench/mutations + at least a third novel) planted in a
  history-less "review tree"; recall measures the pass's sensitivity (the repo's liveness-witness rule
  applied to the hunt itself)
- metrics read in order: recall, precision = (findings + seed hits)/claims, THEN counts; per-finder
  precision (the hallucination alarm); blind spots by lens; cost per finding
- **stopping**: two consecutive passes with zero Tier 1, recall >= 0.8, precision >= 0.7 (+ capture-
  recapture ~0 or a third pass); then per-PR verification + a full pass after a release or a >5-PR batch
- **Between passes**: pass N+1 pins a commit containing pass N's T1/T2 fixes; "known and open" is a
  verifier class; fix = guard + mutation or it is a patch; repro is the acceptance test; fixed defects
  become seeds; judge the fix phase on root causes closed; fixes are new surface (fresh-surface lens
  always on)

Tooling (PR #492, opened 2026-09-25, branch feat/review-pass-tooling): `scripts/review/`
build_review_tree.sh, plant_seeds.py, classify_claims.py, pass_metrics.py (all with --selftest, run by
lint job "Review tooling self-test"); `.claude/agents/finder.md` (fable, high) and `verifier.md` (opus,
medium); `.claude/skills/review-pass/SKILL.md` = coordinator checklist. Smoke-tested end to end on
pgpm_test-15: seed_hit attributed correctly, candidate/not_reproduced/hypothesis classes right.

**Why:** the user's mental model is find -> fix -> harden -> find again, and wants the curve measured.

**How to apply:** pass 2 = `/review-pass <sha> <K> <lenses>` after #492 merges; pin main with all 25
fixes (>= 31f6140), fresh-surface lens mandatory (hand-merged hunks of #481/#484/#485/#483 first),
run the model-tier split (two slices duplicated on a second model) because seeds give labeled data
for model choice. Model prior: finders strongest/high, verifier strong/medium, seed authoring mid,
formatting cheapest. Pass records go in `docs/reviews/YYYY-MM-DD.md`; update the doc's Pass history
table. Pass 1 (a72c5bf) is the unmeasured baseline. Related: [[project-run-test-ci-locally]].
