---
name: next-issue-344
description: "Issue #344 (stage transmute's new parent under a temp name before either rename) implemented and MERGED 2026-09-14 (PR #381), ./test.sh ci green"
metadata:
  type: project
  originSessionId: 5694f88a-674e-4e28-aad2-1589847c6607
  modified: 2026-09-14T14:49:01.936Z
---

Implemented in the fresh session David asked for (see [[project_next_issue_345]] for the chain this
continues). PR #381 (`fix/transmute-cutover-stage-before-rename`): moved phase 3's new-parent build
(CREATE TABLE ... PARTITION BY RANGE, identity, owner/grants/RLS/policies/comments) to run under a
staging name (`<rel>_pgpm_new`) BEFORE either rename, then both renames back-to-back, with trigger
replay staying after both renames (the one step needing the live name in place, per the issue's own
analysis). Outgoing-FK re-add and `pgpm.obtain()` untouched, per #344's explicit non-goals.

**Verified, not just claimed:** re-derived the issue's own "regclass survives rename" and "CREATE
TABLE ... LIKE only reads catalog structure at ACCESS SHARE" safety arguments against the CURRENT
`install.sql` (line numbers had drifted since the issue was filed at `917b950`; re-located phase 3 by
content, per the issue's own instruction to do so).

Added `bench/transmute_cutover_order.sh` (asserts `position()` of `partition by range` and `enable row
level security` against the first `rename to`, read from the installed function's own `pg_proc.prosrc`
-- no concurrency probe, since a SHORTER critical section is harder, not easier, to catch live) and a
discriminating mutation (`transmute_cutover_late_build` in `bench/mutations/mutate.py`). Confirmed
statically before running anything: real code has both markers before the first rename (45253/48256 <
50648), the mutant has both after (48306/51309 > 44213). `./test.sh discriminate` then confirmed this
for real: guard passes on real code, fails on the mutant.

`./test.sh ci` full run: all four PG version matrix legs, TimescaleDB, observe, archive, perf, and
discriminate (13/13 guards) all green. No edits needed to
`tests/70_transmute_phases_test.sql`/`72_transmute_attributes_test.sql`/`80_transmute_outgoing_fk_test.sql`
-- confirms final state is unchanged, exactly what the issue's acceptance criteria required.

**Merged 2026-09-14** -- per [[feedback_dont_assume_standing_merge_authorization]], asked before
merging rather than assuming "implement -> commit -> push" extends to merge; David confirmed, PR #381
merged into main and its branch deleted.

**#347 remains the fallback pick** for whatever comes after this (splitting `obtain()` into its own
`pg_cron` job) -- see [[project_next_issue_345]] for the full reasoning on why #344 was chosen over it.
