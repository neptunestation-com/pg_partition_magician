---
name: project-issue-343-observability-plan
description: "Issue #343 (transmute/freeze/regrain observability) CLOSED 2026-09-24: gaps 1-4 shipped in PR #438 (MERGED a72c5bf), gap 5 declined, gap 6 split out as issue #439 (open, unscoped)"
metadata:
  node_type: memory
  type: project
  originSessionId: b1231edc-c421-43fe-90c9-8f8c2972390b
  modified: 2026-09-25T01:15:44.918Z
---

Issue #343 asks for observability over the transmute -> freeze -> regrain lifecycle (filed 2026-09-05,
the day after the first Boardy production transmute; six gaps). Scoped 2026-09-22, implemented
2026-09-24 as **PR #438**, squash-MERGED the same day as a72c5bf on the user's "merge once green" (all 19
checks green, zero codex review threads). **#343 is CLOSED** (disposition table posted as a comment); the
user asked for gap 6 to be filed as its own issue, which is **#439** (open, unscoped, no plan yet).

**What shipped in #438:**

- `pgpm.progress(p_parent regclass default null)`: 19 columns. Freeze forecast (`frontier`,
  `write_child`, `write_ceiling`, `freeze_margin`, `freeze_in`, `coarse_frozen`) and in-flight regrain
  (`regrain_child/_cursor/_pct_range/_rows_copied/_rows_total_est/_delta_pending/_started_at/_elapsed/_eta`).
- `status()` gained `regrain_to` (appended at the end).
- New internal `pgpm._native_frac(kind, lo, hi, x)`.
- Tests `tests/105_progress_freeze_test.sql` (37) and `tests/106_progress_regrain_test.sql` (49).
- Runbook fix: it said `regrain_skip`; the action is `skip_regrain`.

**The open fork was resolved by me, not the user:** separate `progress()` rather than folding into
`status()`. Stated in the PR body as a mechanical change if the user prefers folding. If they push back,
that is the one design decision to revisit.

**Non-obvious things learned building it** (not in the code comments):

- The capture trigger writes OLD **and** NEW for an UPDATE, so one UPDATE is honestly TWO
  `regrain_delta_pending` entries; a DELETE or INSERT is one. Test 106 uses a DELETE for that reason.
- Identifying the in-flight child by cursor range alone is ambiguous at a sub-range boundary (cursor ==
  A.hi == B.lo, and a freshly prepared regrain on B sits exactly there). `progress()` uses
  `_regrain_capture_active` as the discriminator instead.
- `format('%I', null)` raises, so `_regrain_delta_count` (via `_regrain_capture_names`) must not be
  called for a missing parent; `progress()` gates it behind the `parent_missing` check.
- The cursor only advances when a whole sub-range completes (`v_moved < v_batch`), so `pct_range` is
  flat across every tick inside a large sub-range while `rows_copied` climbs. This is the concrete
  reason the two are separate columns.

**Gap 5 declined** (per-microbatch duration instrumentation): the ETA extrapolates from
`config.regrain_cursor`, which already records exact monotonic range progress, so it never needed it.

**Gap 6 is now issue #439** (filed 2026-09-24 with three possible directions, none chosen): the crux,
verified by grep, is that none of the 8 `skip_*` sites records SQLSTATE, only `left(sqlerrm, 200)`, so
`55P03` lock_not_available (routine) and `57014` query_canceled (recurs every tick) are indistinguishable.
Suggested shape: additive `pgpm.log.sqlstate` column (remember `bench/upgrade_in_place.sh` DEGRADE_COLS),
a classifier keyed on EXACT action + SQLSTATE, a grouped recent-deferrals view. The lock-holding test needs
a second session, so a `bench/` harness + mutation, not pgTAP alone.

**Why:** the reasoning that removed work (gap 5) and the design fork are invisible in the code; the
trigger OLD+NEW detail cost one red test run.

**How to apply:** #438 is done; do not reopen its design. When #439 is picked up, start from the
issue text (it already holds the SQLSTATE table and the test shape) and `docs/reference.md`'s `pgpm.log`
vocabulary table; the merge authorization for #438 does NOT carry to #439's PR
([[feedback_dont_assume_standing_merge_authorization]]). Related: [[project_boardy_transmute_prod_run]]
(the production run that motivated the issue).
