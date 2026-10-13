---
name: pgfr-maintain-partitions-deadlock
description: "pg_flight_recorder's hourly maintain_partitions() deadlocked against run_tier()'s ledger writes; root cause confirmed, fixed and pushed, install bundle cut for Boardy"
metadata:
  node_type: memory
  type: project
  originSessionId: 85c4bf29-124a-464c-ae29-554214dbc8be
  modified: 2026-09-28T17:08:25.907Z
---

Boardy.ai's pgfr v2 instance hit `deadlock detected` in `pgfr_maintain_partitions`
(the hourly `pg_cron` job) every hour since 2026-09-28 01:00 UTC, reported by
Indranil via Codex using pgfr to diagnose an unrelated CPU spike
([[project_boardy_pilot]]). Because the job's whole transaction rolls back on
deadlock, no new hourly partitions get created, so pgfr's own activity/lock
snapshots had been dropped since 01:59 UTC (statement snapshots on daily
partitions were unaffected).

**Root cause, confirmed by reproduction, not just source reading:** a
lock-order inversion between two code paths that both touch `ledger_runs` and
`ledger_captures` in a single transaction, in opposite orders.

- `pgfr_record._partition_targets()` listed `ledger_runs` before
  `ledger_captures`. `maintain_partitions()` step 1 iterates targets in that
  order, issuing `CREATE TABLE ... PARTITION OF` (ACCESS EXCLUSIVE) for
  whichever targets need a new partition, in the same order: `ledger_runs`
  first.
- `run_tier()` (`pgfr_record/sql/08_collector.sql`) does the opposite within
  one transaction: it `INSERT`s into `ledger_captures` for every target
  across its loop (first insert held all run) and only `INSERT`s the single
  `ledger_runs` row at the very end.

Normally create-ahead (2 partition-widths ahead) means the ACCESS EXCLUSIVE
request lands on a future bucket, so this is dormant. Once *any* single
collision fires, the whole `maintain_partitions()` transaction rolls back, so
the same partition stays missing into the next cycle too -- turning a rare
race into a deterministic every-hour repeat, matching what Indranil observed.
A two-session shell regression test
(`scripts/deadlock_maintain_partitions_test.sh`, new -- pgTAP can't drive two
real concurrent sessions from one file) reproduced the exact deadlock against
the old ordering; its `DETAIL` line matched the hypothesis precisely
(`Process A waits for AccessExclusiveLock on ledger_captures blocked by
process B; process B waits for RowExclusiveLock on ledger_runs blocked by
process A`).

**Status 2026-09-28: fixed, pushed, bundle cut.** Fix committed `fff22cd` on
`feat/pgfr-v2` (pg_flight_recorder): reorder `_partition_targets()` to list
`ledger_captures` before `ledger_runs`, matching `run_tier()`'s write order.
Regression test passes clean against the fix; `./test.sh all` (4 PG versions
x 3 install channels) green. Not yet in a tagged release -- PR #131 is the
long-lived branch feeding v2 into `main`, and David isn't ready to cut a
release yet. Per house practice for this pilot, cut a manual install bundle
instead (`scripts/build_install_bundle.sh pgfr_record
dist/pgfr_record-bundle.sql`; `dist/` is untracked, built on demand),
confirmed the fix is present in the bundle output. David is sending it to
Indranil himself via Slack file upload (as done before for this pilot), not
via MCP in this session -- channel is
[[reference_boardy_slack_support_thread]] (C0BRQJML6P3).

Also handed David ready-to-run mitigation SQL, independent of the bundle:
pause the 4 tier cron jobs via `cron.alter_job(jobid, active => false)`, run
`maintain_partitions()` once uncontested, resume -- lets Boardy recover
immediately on their current install without waiting on any release or
bundle.

Separate from this: Boardy's own `XPost`/`ownReplyStats` CPU spike is on
their side (pacing flag or a partial index), already actioned by their own
Codex agent; not a pg_flight_recorder or pgpm issue.
