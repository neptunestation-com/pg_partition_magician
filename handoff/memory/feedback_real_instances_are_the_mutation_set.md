---
name: feedback-real-instances-are-the-mutation-set
description: "When building a checker for a defect class you have real past instances of, run it against those instances, not just synthetic fixtures"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 0bfe9ec5-03bb-432c-aea6-f666d65e1065
  modified: 2026-09-22T23:31:42.538Z
---

When writing a checker (lint, guard, script) for a defect **class** you have already fixed real
instances of, reintroduce each real instance and require the checker to catch it. Do not stop at
synthetic fixtures, however thorough they look.

**Why:** the synthetic fixtures are written from your model of the defect, so they test the model,
not the world. The real instances are free, already-verified mutations that were produced by
something other than your imagination. Demonstrated 2026-09-22 building
`scripts/check_track_filters.py`: its 12 hand-written fixtures all passed, and running it against
the three real gaps just fixed (#419, #423, #424) showed it was **blind to #423** entirely. A track
brings up a container with `$DC --profile x up` and never names `docker-compose.yml` or
`Dockerfile`, so a path regex over the body could not see that dependency at any level of fixture
detail. Shipping on the fixtures alone would have produced a green checker with a silent hole, which
is this repo's signature failure.

**How to apply:** after the self-test passes, script the reintroduction of every historical
instance (git history and closed PRs have them), assert the checker FAILS on each, and restore.
Report the result as CAUGHT/BLIND per instance rather than as an aggregate. If any come back BLIND,
that is a design gap in the checker and not a missing fixture: fix what it keys on, do not add a
fixture for the one case. See [[project_ci_path_filter_drift]] for the worked example and
[[project_next_issue_417]] for the same discipline at guard level.
