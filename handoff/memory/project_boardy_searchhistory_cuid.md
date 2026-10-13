---
name: project-boardy-searchhistory-cuid
description: "Boardy.ai pilot table SearchHistory uses a text cuid PK; verified time-correlated, decision is to add a cuid control_kind to pgpm and partition on id directly"
metadata: 
  node_type: memory
  type: project
  originSessionId: c67c06b5-62f4-4da1-93f9-11b179177c83
  modified: 2026-08-25T15:20:03.563Z
---

Boardy.ai (see [[project-boardy-pilot]]) has a `public."SearchHistory"` table whose primary key `id`
is a Prisma `cuid()` (classic CUID v1, confirmed by Indranil — not `cuid(2)`), stored as `text`. Five
other tables hold live foreign keys into `SearchHistory(id)`: `"SearchResult"`, `bandit_strategy."BanditRewards"`,
`"Match"`, `"ProactiveMatchingRunContactResult"`, `"AutomatchRunContactResult"`.

**Verified empirically, on Boardy's real data** (2026-08-24):

- `pgpm.check_time_monotonic('public."SearchHistory"', 'id', 'createdAt', 2000)` → fraction `1.0000`
  (1999/1999 sampled pairs monotonic). Lexicographic order on `id` tracks `createdAt` order perfectly.
- A separate value-closeness check (decode the cuid's embedded ms timestamp, compare to `createdAt`)
  → p50 skew 1ms, p95 skew 137ms, max skew 2.564s across 2000 sampled rows. `id`'s embedded timestamp
  is not just order-correlated but value-close to `createdAt`.

**Why monotonicity holds**: classic cuid's timestamp field is `Date.now().toString(36)`, NOT
zero-padded by spec (corrected an earlier wrong assumption in-thread that it was fixed-width by
design). It works today only because base36 digit-width for a ms-epoch timestamp is constant across
~1972–2059 (36^7 to 36^8) — every real cuid ever generated falls in that 8-char-wide plateau. This is
an accepted, dated boundary (same shape as the uuidv7 48-bit ceiling, issue #299), not a design
guarantee — matters for the encode-direction ceiling guard in the planned adapter, not for anything
already shipped.

**Decision**: partition `SearchHistory` directly on `id` (zero schema change, zero FK impact, keeps
referential integrity and duplicate-detection intact) once pgpm supports it, rather than widening the
PK to `(id, createdAt)` (would cascade into all 5 referencing tables, since a foreign key's referenced
columns must exactly match a unique constraint's column set) or going keyless (blocked outright by the
5 live FKs — Postgres refuses to drop the PK while they exist).

**Shelved**: replacing `createdAt` with a Postgres generated column derived from decoding `id`. Not
wrong in principle (value-closeness now confirmed), but not on Boardy's critical path, and Postgres
can't convert an existing populated column into a generated one without a full-table rewrite under
ACCESS EXCLUSIVE (no `ALTER COLUMN ... ADD GENERATED`). Revisit only if Boardy independently wants the
schema hygiene.

**How to apply**: this is the concrete motivating case for adding a `cuid` control_kind to pgpm
(built and in PR review as of 2026-08-25 — see [[project-pgpm-text-time-control-kind]]).
Don't assume other Boardy tables share this shape; the FK-dependency and monotonicity checks are
table-specific and were only run against `SearchHistory`.
