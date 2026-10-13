---
name: pass11-plan
description: Pass 11 plan, RUN 2026-10-09 (see pass11-review) (pin 0c38aae, the lever phase's record merge 2026-10-09 22:08Z, no known Tier 1): the exact /review-pass command, rotated lenses, seed guidance (next-hop shape), budget, fresh-surface files, what pass 11 must show for convergence, earliest stop after pass 12; run in a NEW session
metadata:
  type: project
  modified: 2026-10-09T16:20:00Z
---

**Pin = `0c38aae`** (the merge of record PR #1156, 2026-10-09 22:08Z; code at dab8434, #1152's merge, plus the record docs).
The phase left no known Tier 1 (see [[lever-phase-pass11]]). Known-open to list before the hunt: #1141 b3 (T5), #1154
(T5), #1153 (CI), #638 (the hand-recreated block), plus the pass-11 plan's T3 list below.

**Command** (the skill is `/review-pass <pin> <K> <lenses>`; it asks for the budget):
`/review-pass 0c38aae 9 fresh surface, identity and names, concurrency and locks, upgrade and install paths, tests that pass for the wrong reason, resource cliffs`
Five of six lenses differ from pass 10's (operator error, contracts versus documentation, failure injection, time
and zones, boundary arithmetic and types), which satisfies the at-least-half rule; the four rotated in were out for
two passes (last used in pass 9), resource cliffs is the least-used lens in the catalogue.

**Seeds (K=9, sealed, at least a third novel).** Plant one of the NEXT-HOP shape the per-PR mode is known to miss
(a fix's new write read by an older function elsewhere: #1141 b1's shape, adopt_partition meeting the archive
coverage reset), one on the lever phase's own surface (the by-oid lookups in pgpm_archive after `_resolve_child`),
one in bench/ (the pass-9 lesson: bench seeds are found only when the brief says every pre-pass claimed line is
built first), and the rest from the pass-10 fix mutations (569 -> 646 in the catalogue, 77 new). Run
`plant_seeds.py --suite` and keep the read-caught share high; mark side effects. Avoid the pass-9 planting errors
(MUTANT markers, drifted regex, a masked seed behind a downstream refusal).

**Budget** as pass 10: 15 finders on about 13 slices (tests split in three), the model-tier split on two slices
(opus primary, fable duplicate), one verifier per candidate, about 7.5M agent tokens, coverage gated at 0.9 before
classification; round 2 of hypotheses. Fresh surface = everything merged since 0654e1e: the 25 pass-10 fix PRs,
#1137, the lever phase's four PRs #1149 #1150 #1151 #1152 (files: .github/workflows/lint.yml bench/archive_key_by_resolved_oid.sh bench/archive_retired_chunk_kept.sh bench/mutations/mutate.py bench/retain_horizon_ambiguous_wall_time.sh bench/transmute_claim_owner_under_set_role.sh bench/upgrade_in_place.sh CHANGELOG.md docs/reference.md docs/runbook.md pgpm_archive/install.sql pgpm_core/install.sql scripts/archive_partition_whole.sql scripts/check_archive_child_by_oid.py test.sh tests/309_archive_retired_chunk_kept_test.sql tests/310_transmute_claim_owner_under_set_role_test.sql tests/311_retain_horizon_ambiguous_wall_time_test.sql tests/archive/db/49_archive_key_by_resolved_oid_test.sql tests/archive/db/50_archive_retired_chunk_kept_test.sql); the pass-10 record's "Fresh surface" section names the rest.

**What pass 11 must show.** Convergence read on 2026-10-09: Tier 1 per pass flat at 2-5 since pass 5, with the
source shifting to the previous fix phase's surface (pass 10's two were both on pass-9 surface, none on
per-PR-verified code). Pass 10's fix phase was the first per-PR-verified one at scale. If pass 11 finds zero Tier 1,
or only on surface the per-PR mode does not cover (bench, docs), the injection channel is closed and passes 11 and
12 can meet criterion 1 (earliest stop after pass 12). If it finds a Tier 1 on verified surface, widen the per-PR
finder's scope from "touched units and callers" to the readers of the state the PR writes (how #1141 b1 escaped).
Expected: 0-2 Tier 1. Precision/recall are already converged (0.99 / 1.00 in pass 10; 0.92-0.96 / 0.89 before).

**Backlog before the pin** (the method's "backlog verified before pin" rule): no open Tier 1; open Tier 2: #771 b3
(reproduction on #771), #1119 (T2? obtain hand-attached overlap), check `gh issue list --label bug` for T2s in
#1104-#1146 and decide fix-or-carry; the per-PR-filed Tier 3s (#1104 #1105 #1111 #1117 #1118 #1119 #1126 #1129
#1134 #1135) and the adjacent-confirmed ones (#1138 b1 b2 b4, #1139 b1 b4, #1143 b2, #1144 b2) are the pass-11
known-open list for the re-find count.

**Fix phase after pass 11:** as pass 10's (fix-phase skill, per-PR verification of every install-touching PR,
landq --batch 5 with the alarm fixes in [[lever-phase-pass11]]).
