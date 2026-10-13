---
name: project-boardy-pilot
description: Boardy.ai is the first production pilot user of pg_partition_magician
metadata: 
  node_type: memory
  type: project
  originSessionId: c67c06b5-62f4-4da1-93f9-11b179177c83
  modified: 2026-08-24T19:29:29.758Z
---

Boardy.ai is the first production user of pg_partition_magician, per `notes/pilot-boardy-ai.md`
(draft as of last read). Terms: pgpm is not a Supabase product, not covered by any Supabase
SLA/support contract, no warranty (Apache 2.0), best-effort support from David personally during the
pilot. It has never run in production anywhere else — Boardy is the first.

Contact on Boardy's side: Indranil.

**How to apply**: treat any recommendation involving schema changes, dropped constraints, or lost
guarantees (see [[project-boardy-searchhistory-cuid]]) with extra weight given the no-warranty,
first-ever-production framing — verify empirically before proposing rather than assuming a tradeoff is
acceptable for their tables.
