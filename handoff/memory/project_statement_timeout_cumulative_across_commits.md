---
name: statement-timeout-cumulative-across-commits
description: "statement_timeout accrues across a whole top-level CALL to a procedure, including across internal COMMITs -- verified empirically, directly relevant to pgpm's maintain() and any script that loops with internal commits"
metadata: 
  node_type: memory
  type: project
  originSessionId: 76528814-f267-4a80-9071-366cc19f87fe
  modified: 2026-09-08T21:13:07.729Z
---

`statement_timeout` is enforced cumulatively across an entire top-level `CALL` to a procedure,
and does **not** reset at an internal `COMMIT`. Only a genuinely separate top-level statement
(a new network round-trip / protocol Query message) gets a fresh `statement_timeout` clock.

**Why this matters:** verified directly in the pg_partition_magician (pgpm) project, 2026-09-08,
while checking a colleague's reasoning about `pgpm.maintain()`'s timeout budget. A test procedure
with three `pg_sleep(1.5)` segments separated by `COMMIT`, run under `statement_timeout = '2s'`,
failed at ~2.0s total (mid-second-segment) -- not 4.5s. Three *separate* top-level statements of
1.5s each, by contrast, all succeeded, since each got its own fresh timer. This confirms: (a) one
call to `pgpm.maintain()` has its timeout budget shared cumulatively across every internal step
(obtain, write-block enforcement, archive, retain, regrain, FK restore/validate), regardless of the
`-- BOUNDARY` commits between them -- exactly the mental model to use when reasoning about
`archive_batch`/`archive_byte_budget`/`statement_timeout` tradeoffs for that project; and (b) a
script that loops over multiple units of work inside one procedure, committing between them, gets
**no** timeout protection from those commits -- this exact mistake was first shipped in
`scripts/archive_partition_whole.sql` (PR #364) and had to be corrected (PR #365) to process one
unit of work per top-level call instead, once the mistake was caught and verified.

**How to apply:** when reasoning about `statement_timeout` for any procedure/script that loops with
internal commits (in pgpm or elsewhere), assume the timeout is cumulative across the whole call,
not reset per commit. If independent per-unit timeout headroom is actually needed, the unit of
work must be split across separate top-level statements (repeated calls from the client), not
internal commits within one call.
