---
name: project-list-hash-partitioning-exploration
description: "Issue #440 (2026-09-24): exploratory design notes on transmuting into LIST/HASH partitioning; unscoped, may never be built; conversion generalizes, lifecycle does not"
metadata:
  node_type: memory
  type: project
  originSessionId: b1231edc-c421-43fe-90c9-8f8c2972390b
  modified: 2026-09-25T02:10:52.666Z
---

On 2026-09-24 the user asked, as a conversation with no code, how pgpm might add LIST and HASH
transmute alongside RANGE. The analysis was captured verbatim as **issue #440** (enhancement, unscoped).
Nothing is planned. The user's own framing: range was built first as the obvious, lowest-difficulty
case; list/hash "raise the stakes", and they are "not saying it can or cannot be done".

**Conclusions recorded in #440** (start from these, not from scratch):

- The one-time conversion generalizes: hash via `MODULUS 1, REMAINDER 0` + a `satisfies_hash_partition`
  CHECK (parent must exist first, so phase order shifts); list via `IN (<all distinct values>)`.
- The split reuses copy/swap/drop + change capture. Hash split = modulus doubling (same op as regrain).
  List split is all-at-once (overlap forbids per-value attach while the monolith covers the value).
- **The hot-source problem is the shared hard part**: a hash/list monolith never freezes, so the swap
  is a brief write-blocking cutover (the `from_hypertable_cutover` shape), not range's zero-block regrain.
- Hash has no lifecycle at all (a one-shot tool). List's lifecycle hinges on DEFAULT: the recommended
  stance is NO DEFAULT + explicit `register_value`; DEFAULT + reactive migration is a per-tenant write
  outage trap (ATTACH scans DEFAULT under ACCESS EXCLUSIVE; a NOT VALID CHECK is enforced on new rows
  immediately) and is the drain machinery #288 removed.
- If built: hash first (smallest complete package), list second, as an optional module like
  pgpm_hypertable/pgpm_archive, never inside the range engine. Composite partitioning is a named
  non-goal.
- Unverified claims flagged in the issue: hash CHECK implication at ATTACH, MODULUS 1 acceptance,
  SPLIT PARTITION availability in PG18, cutover lock cost at real write rates.

**Why:** the user said "good analysis" and asked for it captured; the value is the reasoning about what
does NOT carry over, which is invisible in the code.

**How to apply:** if list/hash comes up again, read #440 first. Do not propose a DEFAULT-based list
design. Do not treat this as scoped work; it is on the same footing as [[project_uniform_partition_sizes_issue_371]]
(speculative, may never be built). Related: [[project_issue_343_observability_plan]] (same session).
