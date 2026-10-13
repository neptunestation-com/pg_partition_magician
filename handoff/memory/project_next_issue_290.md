---
name: next-issue-290
description: "Issue #290 (pgpm.extend_to()) implemented and MERGED via PR #374, 2026-09-13"
metadata:
  type: project
  originSessionId: e50e8cc1-f284-4544-aaec-cc7bc866c442
  modified: 2026-09-13T23:39:50.957Z
---

Implemented in the session after [[project_next_issue_341]] (PR #372 merged). See that memory for
why #290 was picked over #347/#344.

`pgpm.extend_to(p_parent regclass, p_value text, p_max int default 10000) returns int`: builds
every missing partition on the existing grid, from the current forward edge up to and including
the range that would hold `p_value`. Resolves the three open questions the issue itself flagged:

- **Cap**: `p_max` (default 10000), checked with a dry count BEFORE any DDL runs, so a wildly-off
  value is refused loudly and immediately rather than silently truncated partway there.
- **Parameter type**: `text`, decoded via the same `pgpm._decode` path `_frontier_native` already
  uses -- consistent with the rest of pgpm carrying bounds as text, not an `anyelement` overload.
- **Should `obtain` self-extend?** No -- stayed an explicit manual call, per the issue's own
  reasoning (no INSERT-time hook to trigger it from).

Docs updated: `README.md`, `docs/guide.md` (new "Extend the grid past the lookahead ceiling"
section), `docs/reference.md` (new `### extend_to` entry), `docs/runbook.md` (the "write refused"
fix now recommends `extend_to` for a known value), `CHANGELOG.md`.

Tests: `tests/96_extend_to_test.sql`, TDD -- written and run red (function didn't exist) before
implementing. Liveness-witness style throughout: every refusal is paired with proof the write it
guards was genuinely refused first, and the `p_max` cap test proves the target genuinely needs more
than `p_max` (not vacuously already in reach) before asserting the refusal creates nothing. Verified
the guard discriminates by mutating the cap check out of `install.sql` and confirming the test fails.

`./test.sh ci` ran full green except one `perf`-track flake
([[project_restore_fk_lock_flaky]]) confirmed unrelated by an isolated rerun.

PR: **#374**, branch `feat/extend-to-past-obtain-ceiling`. David explicitly said "merge it once CI
is green" this session -- CI went full green (including the perf track, clean on this run) and it
was merged into `main` (fast-forward, branch deleted) on 2026-09-13. That authorization was for
THIS PR only; per [[feedback_dont_assume_standing_merge_authorization]], ask again next time.

**Side finding, not fixed (out of scope for #290):** `docs/reference.md`'s `### obtain` section
(around the `pgpm.obtain` entry) is stale -- it describes the pre-#288 procedure design (advisory
lock, `p_deferred`, "a procedure, not a function, because of those commits"), but current `obtain()`
is a plain function with none of that. Worth a small doc fix in a future session.
