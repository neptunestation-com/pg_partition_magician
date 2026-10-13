---
name: feedback-deterministic-isolation-over-timing-races
description: "When a bench/test probe needs to contend a specific code path and not an earlier one, prefer exploiting which processing set a function reads from over racing a timer/poll against it"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 5694f88a-674e-4e28-aad2-1589847c6607
  modified: 2026-09-14T07:04:04.454Z
---

Prefer a deterministic isolation mechanism (arrange the fixture so a lock/condition is
*structurally* incapable of affecting the wrong code path) over a reactive one (poll for a signal,
then race to act before the code under test gets there).

**Why:** while fixing `bench/regrain_swap_timing.sh` (issue #345/#378, PR #379), a reactive design
-- poll `pg_locks` for a lock that appears when the code under test enters its critical section,
then race to grab a conflicting lock before the next statement does -- lost the race consistently.
Acquiring a fresh `ACCESS EXCLUSIVE` table lock measured ~13-40ms in that environment, bigger than
the whole window being targeted at any realistic fixture size, and no amount of warming up the
poll query's plan cache or pre-warming the lock acquisition itself closed the gap. Widening the
fixture enough to "win" the race introduced an unrelated confound (an O(n) preamble scan whose
cost scaled with the widened fixture, inflating the *uncontended* baseline past the pass threshold
too) -- a false positive that would have been reported with confidence.

The fix that actually worked exploited a structural fact about the code under test: two functions
(`suspend_incoming_fks`/`restore_incoming_fks`) each read from a disjoint processing set (rows
with `restored_at IS NOT NULL` vs `IS NULL`). Arranging the fixture so one specific row sat in
exactly one of those sets made a lock pre-acquired *before the whole operation even started*
structurally incapable of affecting the first function and guaranteed to affect the second one --
no timing, no polling, no race, and it can never flake.

**How to apply:** before reaching for a poll-then-race probe to isolate contention to one part of
a multi-step operation, look for a structural lever in the code under test (a state flag, a
processing-set predicate, an ordering guarantee) that makes the isolation true *by construction*
instead of *most of the time*. Reserve timing-based probes for cases with no such lever, and even
then, verify the uncontended baseline at the same fixture size doesn't already explain the
"contended" result before trusting it -- see [[project_next_issue_345]] for the full incident.
