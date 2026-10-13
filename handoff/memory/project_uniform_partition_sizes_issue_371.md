---
name: uniform-partition-sizes-issue-371
description: "Speculative 'uniform partition sizes' feature explored via why/how discussion, filed as issue #371 (enhancement, unscoped, may never be built)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8d1d3d0f-dd9e-4e28-ab08-0f41eafad3ef
  modified: 2026-09-13T19:30:39.162Z
---

Issue #371 (https://github.com/dventimisupabase/pg_partition_magician/issues/371) captures a
speculative design discussion about offering uniform (row-count-targeted) partition sizes as an
alternative to today's control-value-width partitioning. **Nothing prompted it** -- no user or
customer asked; the idea came from David thinking through "how" before "why" was established.

**Why:** thin and speculative. Hypothetical benefits (bounded per-partition maintenance cost,
right-sized whole-partition archival, easier capacity planning) exist on paper, but today's
band-aids (`archive_byte_budget` chunking, `regrain_max_blocks`/`regrain_batch`) already absorb
most of the real operational pain without this. Breaks the calendar-partition retention mental
model. Strongest (if any) for time-based control kinds; for `id`/`bigint`, existing fixed-step
partitioning is probably already "close enough" to uniform row count for typical low-gap-rate
serial/bigint PKs.

**How (sketch):** a rolling, purpose-built empty DEFAULT partition as the "current" partition,
converted to a bounded child once `pg_class.reltuples` (after an explicit `pgpm._analyze()`, not a
per-insert trigger) indicates the row-count target is reached. Conversion: swap in a fresh empty
DEFAULT first (one transaction), THEN add a `NOT VALID` bound constraint to the now-detached old
table and `VALIDATE`/`ATTACH` it as bounded (phased like `_transmute`'s existing pattern) --
critically NOT the reverse order, which races against concurrent writes (`NOT VALID` rejects new
violating rows immediately).

**Important distinction from history:** issue #288 (2026-08-17, commit `c254144`) already removed
an EARLIER DEFAULT-partition mechanism from pgpm, but that one reused an existing (potentially
monolith-sized) table as the DEFAULT and drained it row-by-row over an unbounded period. #371's
proposal is different in kind (small purpose-built table, atomic whole-table conversion, no
row-by-row drain) -- two of #288's three bugs (#269 DML-vs-mid-copy race, #284 lock-held-across-
unbounded-scan) don't have a direct analog. But two costs DO carry over because they're about a
DEFAULT partition existing at all, not about the old drain: (1) `DETACH ... CONCURRENTLY` is
refused whenever ANY default partition exists (a bare PG rule) -- this design always has one live,
so `retire`'s concurrent-detach path for FK-referenced partitions (#268's fix) is permanently
blocked for any table using this mode; (2) a DEFAULT partition is invisible to
archive/retain/write-block machinery, so a backdated write outside all bounded ranges lands there
silently instead of hard-failing as today -- narrower than #286's old blast radius (this DEFAULT is
short-lived, so the invisible window is bounded) but still a real regression from today's fail-fast
behavior.

**Status:** filed as an enhancement issue, unscoped, explicitly may be triaged and never
implemented. If asked to pick this up again, read issue #371 in full -- it has the complete
why/how ledger, not just this summary.
