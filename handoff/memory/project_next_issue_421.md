---
name: project-next-issue-421
description: "The three name-identity anchors #421/#428/#429, all MERGED 2026-09-23; what the issue texts got wrong, and the two anchor asymmetries that look like bugs but are deliberate"
metadata: 
  node_type: memory
  type: project
  originSessionId: b6ac82fd-d962-4333-84ac-b096028f2af0
  modified: 2026-09-23T18:37:03.526Z
---

**[#421](https://github.com/dventimisupabase/pg_partition_magician/issues/421) MERGED** as `e9b1f2e`
(PR #427, 2026-09-23). `pgpm.part.child_oid`, recorded where a partition enters the catalog and
backfilled on upgrade, checked once per candidate at the top of `_archive_step`, refusing with
`fail_archive_identity`. Design was chosen by the user from two options: recorded OID column over a
structural `pg_inherits`-plus-bounds check, and archive-path-only scope.

**The issue text mis-states the exposure, and tracing it is the expensive part to repeat.** #421
says the substitute's rows "are exported to S3 under the partition's key". They are not, for any
shipped strategy: `pgpm.archive_to_s3_ndjson`/`_parquet` read off `p_parent` **by OID** over
`[lo, hi)` and ignore `p_child` entirely (their own comment says so). Only `archive.to_s3`, the
synchronous hand-called function, reads the child by name, and it returns `void` so
`set_archive_fn`'s type check rejects it as an `archive_fn`.

The chain that IS reachable, and it ends in destruction rather than a wrong bucket object:

1. `_enforce_write_blocks` -> `_install_write_block` resolves `%I.%I` by name and creates the
   `pgpm_write_block` trigger **on the substitute**. Maintenance manufactures its own candidate;
   without this step a substituted name fails `_is_write_blocked` and is skipped.
2. `_next_archive_chunk` sizes the chunk from the substitute (an empty one yields the whole
   remaining range at once, "trivially covered").
3. Ledger row -> `_archive_fully_covered` true -> `retire` runs `drop table %I.%I` and **destroys
   the substitute**, deleting the `pgpm.part` row, while the real partition survives untracked.

**#428 MERGED** (`98f09a7`, PR #430) and **#429 MERGED** (`9a8d8b2`, PR #431), both 2026-09-23. All
three checks compare against `pgpm.part.child_oid`; `fail_write_block_identity`,
`fail_archive_identity` and `fail_retain_identity` all count in `status().retain_drop_failures` and
none clears itself.

**TWO ASYMMETRIES THAT LOOK LIKE INCONSISTENCIES AND ARE NOT.** Each has a mutation whose whole job
is to fail when someone "fixes" it, so read those before changing either:

1. **`retire` checks `retiring_oid` and `child_oid` independently, never `coalesce`d.**
   `retiring_oid` is itself resolved by NAME out of `pg_inherits` at dispatch time, so it ADOPTS a
   substitution that landed before the dispatch; coalesce would pick the adopted one and pass
   forever. Mutation `retire_identity_coalesced_anchors`, caught only by part B of `tests/103`.
2. **`_install_write_block` fires on `is not null and <>`, not `is distinct from`**, so a name
   resolving to NOTHING does not trip it. There is no wrong relation to act on, and the null case
   already has accurate tested handling (`::regclass` raises -> `skip_write_block` with the real
   error, #360). Firing on null also stops `tests/94`'s poison raising, silently retiring that
   file's loop-isolation coverage. Mutation `write_block_refuses_missing_relation`. CI caught this
   the hard way: the first #429 attempt fired on null and broke `tests/94`, where updating the
   expected value would have gone green while leaving three assertions passing trivially.
   Relatedly, `_remove_write_block` is deliberately NOT anchored at all, so pgpm can lift a trigger
   a pre-#429 version stranded on a substituted relation (mutation `write_block_remove_anchored`).

**The guards overlap now, and `tests/102` had to be rebuilt to survive #429.** Its substitute used
to be write-blocked by `_enforce_write_blocks`, which #429 refuses, so `_archive_step` would never
reach it and #421's guard would have gone VACUOUS, not merely weaker (measured: 0
`fail_archive_identity` rows, mutation undetectable). The trigger is now created directly in the
test, modelling a pre-#429 install, which is also the standing argument for why #421's check is not
redundant: `_is_write_blocked` stays name-based on purpose. Its mutation now fails 7 assertions
rather than the original 10, because #430's `retire` check also refuses.

See [[project_pgpm_security_hardening_campaign]] for where these sit in #346's lineage, and
[[feedback_proactive_related_code_analysis]] for why the trace went past the named function at all.
