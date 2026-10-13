---
name: project-next-issue-417
description: "Issue #417 MERGED (PR #419, 2026-09-22): DEGRADE_COLS 15->25 plus an opposite-direction precondition; also fixed perf.yml's enumerated path filter"
metadata:
  node_type: memory
  type: project
  originSessionId: 93fb0226-89ab-406f-9393-8c9a443119bb
  modified: 2026-09-22T21:47:59.657Z
---

**[Issue #417](https://github.com/dventimisupabase/pg_partition_magician/issues/417) is CLOSED,
[PR #419](https://github.com/dventimisupabase/pg_partition_magician/pull/419) squash-merged as
`0cb4476` on 2026-09-22.** All 15 checks were green.

What shipped in `bench/upgrade_in_place.sh`: `DEGRADE_COLS` went 15 -> 25 entries, plus a second
precondition running the OPPOSITE direction (read the backfill lines out of the install file about
to be run, fail naming any the list omits). Mutation `upgrade_degrade_list_drift` added.
`./test.sh discriminate` is now 21 guards, was 20.

**The non-obvious design point, worth keeping:** the new precondition is deliberately
one-directional, and that is what keeps it non-circular. `upgrade_no_column_backfill` mutates by
DELETING a backfill line; a missing backfill LINE is not a missing LIST entry, so the new check
still passes under that mutant and the catalog-hash assertion is still what fails it (verified by
running it, not reasoned about). The CONVERSE check ("every list entry has a backfill line") would
fail under that mutant for a reason that is not the defect, so it must never be added.

**Verified empirically, in case it comes up again:** dropping the `pgpm.transmute_inflight` owner
columns and the seven `text_time` columns changes nothing else the guard exercises. The `DROP ...
CASCADE` only cascades through `pgpm.partitions` -> `pgpm.part.attached`; `pgpm.config` and
`pgpm.transmute_inflight` have no dependent views or indexes. The catalog hash still matches the
oracle. That was PR #415's open question and the answer is no.

**Found on the way, fixed in the same PR, and generalizable:**
`.github/workflows/perf.yml`'s path filter ENUMERATED the guards it covers, and four of the thirteen
the perf track runs were not on it (`transmute_cutover_order`, `upgrade_in_place`,
`frontier_drought`, `regrain_outgoing_fk_lock`). A change to `bench/upgrade_in_place.sh` alone
triggered no perf job at all. It is #417's own defect one level up: a hand-maintained list of what
to check, drifting behind what exists, with nothing reporting it. Now `bench/*.sh` -- a shape, not a
list. **OPEN FOLLOW-UP, not filed as an issue:** `lockview.yml` still enumerates seven
`bench/lock_view*` files and is a candidate for the same treatment; not touched because it was
outside #417's scope and which files that track actually drives was not verified. See
[[feedback_proactive_related_code_analysis]].

`RELEASING.md` said "there are fourteen such lines" against 25; dropped rather than re-counted, same
rot reason. It now also states that a new backfill line needs a `DEGRADE_COLS` entry.
