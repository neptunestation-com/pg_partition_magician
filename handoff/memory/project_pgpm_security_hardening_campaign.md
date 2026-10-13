---
name: project-pgpm-security-hardening-campaign
description: "pgpm security-hardening campaign #346 CLOSED 2026-09-22; all 7 candidates (#405-#411) resolved; ALL successors closed 2026-09-23: #421/#428/#429/#422 (PRs #427/#430/#431/#432). Campaign fully done."
metadata:
  node_type: memory
  type: project
  originSessionId: 7c02a40b-7b64-4354-bad5-2d03e4773c0f
  modified: 2026-09-23T05:25:06.525Z
---

**[Issue #346](https://github.com/dventimisupabase/pg_partition_magician/issues/346) is CLOSED
(2026-09-22).** It was a scoping pass across four pillars (dynamic SQL injection shape, privilege
posture, name-resolution TOCTOU, dbdev supply chain), motivated by PostgreSQL's own
`SPLIT/MERGE PARTITION` revert (Noah Misch, citing CVE-2014-0062). Its seven ranked candidates were
filed as #405-#411 and are all resolved: #405 (PR #413), #406 (PR #412), #407 (PR #415), #408+#409
(PR #414), #410 (PR #420), #411 (audit performed, closed). **Read #346's closing comment for the
table** rather than re-deriving it.

**Why the user rejected the "it's only PL/pgSQL" exemption, which still governs how to treat this
area:** CVE-2014-0062 was itself a bug in Postgres's own SQL-level DDL machinery (repeated name
lookups without a held lock), not a memory-safety bug, so a pure-SQL codebase is squarely in the
same risk class.

**Three things the campaign turned up that were NOT in the original scope, worth not
rediscovering:**

1. **#410 was half-dormant, not dormant.** Line *dropping* had never fired as scoped; whitespace
   *collapsing* had, rewriting string-literal content in the published dbdev package at 17 lines
   across five multi-line literals. Harmless in all five, which is why nobody noticed. General
   lesson: "dormant" claims scoped against one of a script's rules may not hold for its others.
2. **Pillar 3's `%I.%I => ::regclass` claim does not cover `pgpm_archive`.** Its five constructed
   names are FROM items in data statements and are never cast at all, so the original sample cannot
   have included the archive read path.
3. **The name-carried-identity class is wider than `_dispatch_detach`.** #407 fixed a name handed
   across a SESSION boundary. #421 is the same defect with neither a cron hand-off nor a concurrent
   session: a name persisted in `pgpm.part` and re-resolved by a later tick, reachable by a stale
   row alone.

**[#421 is FIXED](https://github.com/dventimisupabase/pg_partition_magician/pull/427)** (merged
`e9b1f2e`, 2026-09-23): `pgpm.part.child_oid`, recorded where a partition ENTERS the catalog and
backfilled on upgrade, checked once per candidate at the top of `_archive_step`, refusing with a new
`fail_archive_identity` action counted in `status().retain_drop_failures`. See
[[project_next_issue_421]] for what tracing it actually turned up, which was narrower and worse than
the issue's own headline.

**NO SUCCESSORS LEFT OPEN.** #422 merged as `f7125b1` (PR #432, 2026-09-23): the hypertable cutover
now locks the source BY OID (`p_hypertable::text` renders the current name of the relation actually
passed, so the lock lands on it even after a rename) and re-resolves to verify, and does the same
for the DESTINATION against the oid its own existence check found -- the half not in #422's title,
and the worse one, since the destination is renamed INTO the source's name and so BECOMES the
production table rather than merely being dropped.

#411's per-function TOCTOU pass is fully worked through: #421, #428, #429 and #422 are all merged,
every step of the retention lifecycle that acts on a partition by name checks `pgpm.part.child_oid`
first, and the cutover verifies both halves of its swap under lock. See [[project_next_issue_421]]
for the deliberate asymmetries in those checks, which look like inconsistencies and each have a
mutation guarding against being "fixed", and [[project_next_issue_422]] for the cutover's window map
and its test-harness constraints.

None is a privilege-escalation vector (all need ownership-level DDL on the target), so they are
ordinary follow-ups, not a live security incident. Confirmed clean and not to be re-litigated:
schema privilege defaults, SECURITY INVOKER + per-phase rollback, pgpm's bookkeeping tables,
163 of 166 dynamic-SQL sites, and 50 of 63 `pgpm_archive` functions which carry no object identity
at all. See [[project_boardy_pilot]] for the production deployment any fix must account for.
