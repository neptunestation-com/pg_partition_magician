---
name: next-issue-341
description: "Issue #341 (set_regrain silent-wedge bug) fixed, tested, and MERGED (PR #372, 2026-09-13)"
metadata:
  type: project
  originSessionId: 8d1d3d0f-dd9e-4e28-ab08-0f41eafad3ef
  modified: 2026-09-13T22:35:32.503Z
---

Issue #341 (`pgpm.set_regrain` accepting a `p_target_step` coarser than `config.partition_step`,
silently wedging auto-regrain forever) is fixed and MERGED: PR #372
(`fix/set-regrain-rejects-coarser-step` -> `main`), merged 2026-09-13 (merge commit d8721d5).

`set_regrain` now rejects a coarser target at call time (compares step widths via the existing
grid helpers anchored at `config.partition_anchor`, which is on-grid for any step). Equal-or-finer
targets and `null` stay unconditionally allowed; `pgpm.regrain()`/`regrain_history()` are
untouched. TDD: `tests/95_set_regrain_rejects_coarser_step_test.sql` written first, confirmed red
against the pre-fix code, green after.

Along the way, `./test.sh ci` surfaced two SEPARATE findings, both resolved before merge:
- [[project_restore_fk_lock_flaky]]: a genuinely flaky `perf`-track probe, unrelated to this fix.
- [[project_minio_dockerhub_pull_denied]]: a genuinely broken CI dependency (Docker Hub denying
  `minio/minio`/`minio/mc`), fixed separately in PR #373 (merged first), then #372 was rebased onto
  the fixed `main` and reverified fully green before merging.

Superseded: [[project_lz77_memory_blowup_fix]] was the prior "next up" item and is already merged.
