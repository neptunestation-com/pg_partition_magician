# Tier 1 and Tier 2 catalogue (formal methods, Phase 0)

The Phase 0 output of the formal methods program (`docs/pgpm-formal-methods-context-pack.md`, sections 7 and 11).
This file has one row per Tier 1 and Tier 2 finding in the record, and the shares that decide whether to model, what
to model first and what the base module has to contain. It ends with a Phase 1 budget proposal. Phase 1 has not
started. This document is for the maintainer to decide on.

Read against `main` at `057d080` (the pass-13 fix-phase record, #1421), 2026-10-29.

## Headline

| measure | root causes | findings |
|---|---|---|
| Tier 1 and 2 in the record (shipped code) | 182 (94 T1, 88 T2) | 222 (101 T1, 121 T2) |
| expressible in a finite model, strict (Y) | 0.50 | 0.50 |
| expressible, counting abstract (Y + A) | **0.72** | 0.72 |
| Tier 1 expressible (Y + A) | **0.82** | 0.83 |
| Tier 1 expressible, pass 9 onward and the backlogs verified since pass 7 | **0.97** (33 of 34) | |
| mechanism closed since by a lint-enforced class lever | 0.13 | 0.11 |
| open expressible mass (Y or A, lever not closed) | 108 (0.59) | 134 (0.60) |
| found inside fix PRs by per-PR verification (not shipped, counted apart) | | 54 (35 T1, 19 T2), 0.89 expressible |

The kill criterion for Phase 0 is an expressible share below a third. The measured share is 0.50 strict and 0.72
generous, and it is higher where it matters: 0.82 of the Tier 1, and 33 of the 34 Tier 1 root causes found from pass
9 onward. The defects a model cannot express (grid and zone arithmetic, encoders, PostgreSQL feature coverage) were
mostly drained by passes 1 to 4. What the loop is still finding is almost entirely the kind a model checker
enumerates.

**Proposed modelling order: archive-then-retain custody, then regrain, then the hypertable migration, then
transmute and untransmute, then obtain and the grid.** The order and the reasons are under
[Modelling order](#modelling-order).

## Sources and counting

- **Passes 2 to 13**: every row of tier 1 or 2 in each record's Findings table (`docs/reviews/*.md`), 145 rows.
  Pass 3's table carries no issue numbers; they come from its Root causes list (#563 to #601).
- **Pass 1** (`notes/2026-09-24-bug-hunt.md`, which is not in the repository): its data-loss tier as filed, #441
  to #465 (25 issues, from `gh`). Pass 1's own tier 1 was looser than the method's later rubric: #441 and #457, for
  example, are wedges. They are kept at tier 1 as filed. Its 21 tier-2 bullets come from the pass-1 reconciliation
  table in the pass-11 record. That table truncates each bullet, so each is classified as the later issue that fixed it.
- **Verified backlogs**: every Tier 1 or 2 bullet that a verifier confirmed before a pin. That covers the adjacent
  observations of the pass 7 to 12 fix phases (#872, #873, #878, #950, #952, #955, #1030, #1037, #1039, #771, #1141,
  #1334, #1335, #1336), the lever-phase adjacent lists (#1054, #1055, #1057, #1062, #1064, #1357, #1358), the
  pass-11 backlog round (#705 B01-03, #709 B02-01), the pass-1 reconciliation's new Tier 1 (#1241) and the lever-10
  candidate (#627). 31 rows.
- **Per-PR rounds** ([table B](#b-found-inside-fix-prs-by-per-pr-verification)): the Tier 1 and 2 verdicts that per-PR
  verification gave on fix PRs (the lever phases before passes 10 to 13, and the fix phases of passes 10 to 13),
  54 rows. These are the injection channel measured directly. Many of them were on a PR head and never on `main`.
  They are kept out of the headline shares and reported on their own. Rounds whose records give no tier
  (#1199, #1213, #1295's four rounds) are not counted.
- **Root cause** means the issue number, and a backlog bullet counts as its own. Re-reports of one issue are rows in
  table A but collapse to one root cause. The shares are given in both units, and they barely differ.

Each row's protocol, invariant, environment action, expressibility and lever were assigned by one reader (the Phase 0
author) from the record's one-line finding and, where that was thin, the issue. None of it has been verified. See
[Limits of this catalogue](#limits-of-this-catalogue).

## Taxonomy

### Protocols

| code | protocol | covers |
|---|---|---|
| CU | archive-then-retain custody | write block, `_archive_step` and strategies as callers, the ledger, `retire()`, the concurrent detach dispatch and `_detach_reap`, the DROP, the object store, the synchronous exports (`archive.to_s3*`) |
| RG | regrain | prepare, capture trigger and delta, copy, reconcile, swap, cancel, the snapshot wait |
| TM | transmute and untransmute | the three phases, the claim, abort and reap, incoming-key preserve and restore, carried DDL |
| GR | obtain and the grid | `obtain`, `extend_to`, `_part_name` labels, zones, grid arithmetic, the setters that move the grid |
| HT | hypertable migration | `from_hypertable_copy`, drains, cutover, handoff to transmute |
| EN | archive encoders | NDJSON and Parquet value encoding, signers |
| MT | the maintenance sweep | `maintain_all`, per-step lock and statement budgets, sweep bookkeeping |
| IN | install, upgrade, uninstall | as a protocol of its own (upgrade as an initial state is the UP environment action) |

### Invariants

The seven from the context pack's 4.3, plus four that the data needed. Each new one cites its contract, as 4.3
requires.

| invariant | statement | source |
|---|---|---|
| NoLostRow | (4.3) | |
| NoDuplicateRow | (4.3) | |
| DropOnlyCovered | (4.3) | |
| ArchiveNoClobber | (4.3) | |
| ResolveByRecord | (4.3) | |
| RoutableWithinGrid | (4.3) | |
| NoWedge | (4.3) | |
| **NoStaleRow** (new) | every row served through the parent is its latest committed version, and no row the app deleted is served again | reference.md (regrain: mid-regrain DML is honoured); #449, #496, #497 |
| **WritesNotRefused** (new) | a write that the table's grants and its documented state permit is not refused by a pgpm artefact (a bound, block, trigger or scratch relation left behind or ungranted) | guide.md (a refusal leaves the table untouched); #496, #508, #509 |
| **CarriedAttributes** (new) | a conversion, swap or reverse keeps the table's documented attributes: trigger enabled state, grants, publications, replica identity, policies, keys, dependants | reference.md (transmute: the parent takes over the table's row triggers, grants, RLS); #277, #499, #566, #706 |
| **ArchiveFaithful** (new) | an archived object holds each row's exact value | README (supported types); #461, #567, #781 |

NoStaleRow is the row-version half of NoLostRow. The pack's NoLostRow (a row is present) does not see a reverted
UPDATE or a resurrected DELETE, and those are regrain's main Tier 1 shapes (13 of its 39 root causes). It needs rows
modelled as (key, version) tokens rather than keys alone. That fits 4.1's "rows are abstract tokens with a key value,
a committed flag and a provenance".

CarriedAttributes and ArchiveFaithful are recorded for completeness and are **not proposed for layer A**: their
defects are about which PostgreSQL features or value encodings a routine enumerates, which no finite protocol model
can know. Layer B can check CarriedAttributes as a catalog diff before and after; ArchiveFaithful is layer D.

### Environment actions

Codes from 4.2, with five the data split out: SG, DV, RL, RC and SB.

| code | action | root causes (T1) |
|---|---|---|
| DV | a data value or schema shape at an edge (uuid aggregates, NaN, BC, 63-byte names, DST zones, numeric scale, collations, NOT VALID constraints) | 45 (17) |
| OD | operator DDL: rename, SET SCHEMA, detach, attach, drop, a namesake, ALTER COLUMN, DISABLE TRIGGER, ADD FK | 38 (27) |
| OC | operator call: a setter, `pgpm.config` edit, a direct procedure or strategy call, a re-run | 24 (9) |
| SG | session GUCs differ between the writing and the reading session (TimeZone, DateStyle, search_path, extra_float_digits) | 15 (11) |
| CR | crash, cancel or failure between transactions, then a re-run or resume | 10 (6) |
| W | a concurrent application write (including TRUNCATE) | 10 (8) |
| ST | a stranger or a non-owner writer: privileges, RLS, views | 9 (4) |
| UP | a state an older install left (the initial state) | 8 (4) |
| RL | a long reader holding a lock or a snapshot | 6 (1) |
| none | the defect needs no environment action (serial composition of pgpm's own steps) | 6 (1) |
| RC | a resource limit (lock table, statement_timeout) | 4 (0) |
| P2 | a second pgpm run (two ticks, a tick and a manual call, two drains) | 3 (2) |
| WR | a write under `session_replication_role = replica` | 2 (2) |
| RR | a caller in REPEATABLE READ | 1 (1) |
| SB | the object store's own behaviour (key normalisation, unconditional PUT) | 1 (1) |

Many root causes need two actions (a rename during a lock wait is OD plus a wait). The table counts the one that is
decisive. Table A gives one code per row on the same rule.

### Expressibility

- **Y**: a finite model built under 4.1 and 4.2 reaches the defect directly, as an interleaving, an environment
  action, a crash point, the split between identity and name, or the attachment state machine.
- **A**: reachable only if the base module includes a deliberate abstraction it would otherwise leave out: a
  session-dependent render and parse, a non-injective naming or key function, a resource budget, a per-role
  visibility filter. The model then protects the design rule ("store the canonical form", "names are injective"),
  not the arithmetic behind any particular collision.
- **N**: needs value-level arithmetic, an encoding, or an enumeration of PostgreSQL features. Out of scope for
  layer A; a candidate for layer D or for layer B's catalog checks.

### Class levers

**Closed** means a lint fails CI on a new instance of the mechanism. Those are the only levers that close a class
in the pack's sense. **Partial** means a shared helper exists, but nothing checks that every site calls it. Most of
the record's levers are partial. The verified backlogs keep re-finding their missed sites: issue #1335 bullet 10
beside #1295, #1336 bullet 8 beside #1305, #1030 bullet 3 beside #454.

| lever | what | state |
|---|---|---|
| L-BYNAME | `_lock_oid`, `_effect_or_raise`, `_drop_by_oid`; `scripts/check_by_name_after_wait.py` over the three install files and `uninstall.sql` (#1409) | closed |
| L-PARTREL | `pgpm._part_rel`, one resolver for a `pgpm.part` row's name; `scripts/check_part_row_by_name.py` (#1392); `_child_nsp` before it | closed |
| L-ARCHCHILD | `archive._resolve_child`, then the oid only; `scripts/check_archive_child_by_oid.py` (#1064, #1205) | closed |
| L-ARCHKEY | one function assembles and claims every object key, in one canonical spelling; `scripts/check_archive_object_keys.py` (#822, #872 b5, #1260) | closed |
| L-KEYINJ | the key function is injective in the chunk's bounds (sign, era); no check | partial |
| L-TSTEXT | `_ts_text`, `_native_bound_key`, `_native_bound_reach`: store and read instants in a session-independent form | partial |
| L-ALWAYS | triggers ENABLE ALWAYS; `_is_write_blocked` and capture judge `tgenabled = 'A'`; coverage under a weaker block discarded | partial |
| L-DISPATCH | `pgpm.part.detach_dispatched_oid`, `_part_built`, `_part_detached_by_hand`: a mark counts only with its dispatch record | partial |
| L-PENDING | `_refuse_detach_pending` (untransmute); retire's own rule (#1250); #705's `_part_built` note still open | partial |
| L-RECCHUNK | `_refuse_recorded_chunk_overwrite`, ledger `child_oid`, retired-chunk marks, `_over_retired_chunks` | partial |
| L-CONTRACT | `_archive_contract_breach` on a strategy's `covered_hi` | partial |
| L-DRIFT | `_regrain_shape_drift`, `_regrain_source_drift` and the source mark: restart a run whose copies went stale | partial |
| L-SCRATCH | `_scratch_mint` (owner-only ACL), `_scratch_rel` by recorded oid | partial |
| L-GRANT | `_regrain_capture_grant` and the definer capture | partial |
| L-STRICT | `_refuse_strict_isolation`, `_regrain_refuse_strict_isolation` | partial |
| L-RLS | `_refuse_filtered_reads` | partial |
| L-SNAPWAIT | `pgpm._snapshot_wait` (#1253), with its documented limit #1256 | partial |
| L-ARGS | `_refuse_bad_transmute_arguments`, `_time_unit_contract`, `_retain_nonnegative` and the setters' shape checks | partial |
| L-NAME | `_part_name` refuses past 63 bytes, sub-day labels in UTC, `_obtain_name` | partial |
| L-BUDGET | lock budgets in `obtain`, `extend_to` and the regrain swap | partial |
| L-CARRY | the carried-DDL enumerations of transmute and the hypertable cutover | partial |
| L-FKDEF, L-OIDDEP, L-FLOORDIV, L-UNINST | `_fk_definition`, `_refuse_oid_bound_dependants`, `_floor_div`, `_uninstall_drop` | partial |

A blank lever cell in table A means no lever beyond the site's own fix: 71 of the 182 root causes (39 percent).

## Shares

### By protocol (root causes)

| protocol | root causes | T1 | T2 | share | Y | A | N | lever closed | lever partial | lever none | open expressible (Y+A, not closed) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| CU | 53 | 37 | 16 | 0.29 | 32 | 10 | 11 | 12 | 29 | 12 | 30 |
| RG | 39 | 23 | 16 | 0.21 | 25 | 8 | 6 | 5 | 23 | 11 | 28 |
| TM | 36 | 10 | 26 | 0.20 | 14 | 6 | 16 | 2 | 18 | 16 | 18 |
| GR | 17 | 3 | 14 | 0.09 | 2 | 9 | 6 | 0 | 9 | 8 | 11 |
| HT | 18 | 11 | 7 | 0.10 | 11 | 5 | 2 | 2 | 8 | 8 | 14 |
| EN | 12 | 7 | 5 | 0.07 | 2 | 0 | 10 | 1 | 0 | 11 | 1 |
| MT | 4 | 0 | 4 | 0.02 | 3 | 1 | 0 | 0 | 0 | 4 | 4 |
| IN | 3 | 3 | 0 | 0.02 | 2 | 1 | 0 | 1 | 1 | 1 | 2 |
| all | 182 | 94 | 88 | 1.00 | 91 | 40 | 51 | 23 | 88 | 71 | 108 |

### By protocol (findings, re-reports counted)

| protocol | findings | T1 | T2 | share | Y | A | N | lever closed | lever partial | lever none | open expressible (Y+A, not closed) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| CU | 64 | 39 | 25 | 0.29 | 39 | 10 | 15 | 14 | 34 | 16 | 35 |
| RG | 46 | 27 | 19 | 0.21 | 30 | 8 | 8 | 5 | 28 | 13 | 33 |
| TM | 43 | 11 | 32 | 0.19 | 18 | 7 | 18 | 2 | 23 | 18 | 23 |
| GR | 28 | 3 | 25 | 0.13 | 3 | 16 | 9 | 0 | 16 | 12 | 19 |
| HT | 19 | 11 | 8 | 0.09 | 11 | 6 | 2 | 2 | 9 | 8 | 15 |
| EN | 13 | 7 | 6 | 0.06 | 2 | 0 | 11 | 1 | 0 | 12 | 1 |
| MT | 6 | 0 | 6 | 0.03 | 5 | 1 | 0 | 0 | 0 | 6 | 6 |
| IN | 3 | 3 | 0 | 0.01 | 2 | 1 | 0 | 1 | 1 | 1 | 2 |
| all | 222 | 101 | 121 | 1.00 | 110 | 49 | 63 | 25 | 111 | 86 | 134 |

Columns: Y, A and N are expressibility. Closed, partial and none are lever state. "Open expressible" counts rows a
model can express (Y or A) whose class no lint closes. That is the mass the modelling order is weighed by, as section
7 of the pack asks. The closed rows are not wasted modelling: for them a model protects the lever's assumptions
(for example, that a lock by oid pins the relation but not its schema) rather than finding new instances.

### By invariant (root causes)

| invariant | root causes | T1 | Y | A | N |
|---|---|---|---|---|---|
| NoWedge | 51 | 2 | 18 | 10 | 23 |
| NoLostRow | 24 | 24 | 14 | 4 | 6 |
| WritesNotRefused | 19 | 1 | 10 | 1 | 8 |
| RoutableWithinGrid | 17 | 2 | 3 | 10 | 4 |
| ResolveByRecord | 16 | 13 | 13 | 3 | 0 |
| NoStaleRow | 14 | 14 | 12 | 2 | 0 |
| DropOnlyCovered | 13 | 13 | 9 | 3 | 1 |
| ArchiveNoClobber | 12 | 12 | 8 | 4 | 0 |
| CarriedAttributes | 10 | 7 | 2 | 3 | 5 |
| ArchiveFaithful | 5 | 5 | 1 | 0 | 4 |
| NoDuplicateRow | 1 | 1 | 1 | 0 | 0 |

The five custody invariants (NoLostRow, NoStaleRow, DropOnlyCovered, ArchiveNoClobber, ResolveByRecord) hold 76 of
the 94 Tier 1 root causes, and 69 of those 76 are expressible. The seven that are not are retention arithmetic
(#451, #565, #649, #627), collation routing (#568), the hypertable dimension kind (#458) and an encoder alias
(#821). NoWedge is the largest invariant by count but is
almost all Tier 2, and nearly half of it is arithmetic or a missing aggregate (N). The pack's caution on liveness
fits the data: check NoWedge as a safety property ("no reachable state in which a maintenance step fails on every
tick without a documented refusal"), with an explicit list of documented refusals as its parameter, and do not lead
with it.

### By pass

| pass | rows | expressible (Y + A) |
|---|---|---|
| 1 | 46 | 32 |
| 2 | 31 | 22 |
| 3 | 30 | 14 |
| 4 | 19 | 14 |
| 5 to 8 | 37 | 26 |
| 9 to 13 | 28 | 25 |
| backlogs verified before the pins of passes 8 to 13 | 31 | 26 |

Grouped by root cause: passes 1 to 8 give 126 root causes, 0.66 expressible (0.73 of their Tier 1). Pass 9 onward,
with the backlogs, gives 56 root causes, 0.86 expressible, and 33 of their 34 Tier 1. The one exception is #627,
the retain horizon's fall-back round trip, which is zone arithmetic.

### Age and lens

The age and lens tags start with pass 10. Pass 10's and 11's were backfilled. In passes 10 to 13's own tags, 5 of
the 11 Tier 1 findings are young (on the previous fix or lever phase's surface) and 6 are old. Of the 21 Tier 2, 2
are young and 8 old. The backlogs are the fix phases' adjacent observations, so they sit on fix surface by
construction. Their ages in table A are this reader's attribution, marked `*` (22 young, 7 old, 2 sibling copies of a
mechanism fixed at another site: #1335 b10, #1336 b8). Add the 35 Tier 1 that per-PR verification found inside fix
PRs before they landed (table B), and the fix channel is the largest source of Tier 1 in the late record. That is
the prevention signal section 8 of the pack measures. Lenses before pass 10 are the reader's attribution within
that pass's declared set, marked `*`. They are not tags.

## What the data says

1. **The open mass is in two protocols.** Custody (30 open expressible root causes, 23 Tier 1) and regrain (28, 19
   Tier 1) together hold 58 of the 108 open root causes and 42 of the 60 open Tier 1. The hypertable migration is
   third (14, 9 Tier 1). Its copy, delta and snapshot wait share regrain's mechanism, so a regrain model carries
   most of it. Transmute has mass (18) but mostly Tier 2. Obtain and the grid are mostly A (naming and zone
   abstractions), 1 open Tier 1.
2. **The per-PR rounds point the same way, harder.** 47 of the 54 Tier 1 and 2 verdicts on fix PRs are custody (24) or
   regrain (23), and 0.89 are expressible. The two longest verification loops were custody and regrain: #1253's
   snapshot wait (ten rounds, 12 Tier 1 and 3 Tier 2 regressions on its own heads) and #1392's unanchored-row
   resolver (nine rounds). Each round found one more state the fixer had not enumerated. A model's job is to
   enumerate those states before round 1.
3. **Operator DDL is the commonest Tier 1 trigger.** It is the decisive action for 27 of the 94 Tier 1 root causes:
   renames, SET SCHEMA, hand detaches, namesakes, columns changed mid-regrain. The base module's identity and name
   split (4.1) and an operator process with the full DDL repertoire carry most of the program's value.
4. **Session dependence is the third commonest Tier 1 trigger**, after operator DDL (27) and data-value edges
   (17). 11 Tier 1 root causes (#455, #459, #464,
   #465, #500, #501, #570, #781, #977, #1336 b8, #1363) are a value written in one session's TimeZone, DateStyle or
   search_path and read in another's. They recur after their lever (L-TSTEXT): #1336 b8 and #1363 came after #977,
   and #1363 is young, on the lever phase's own fix. The base module should model a stored value as text plus the
   rendering session, with a parse that depends on the reading session. That is the abstraction behind the A
   verdicts in CU. Without it, layer A cannot see the class that produced pass 13's young Tier 1.
5. **The closed levers closed one invariant.** 16 of the 23 lint-closed root causes are ResolveByRecord (10) or
   ArchiveNoClobber by name (6). The custody, staleness and coverage invariants have helpers but no exhaustiveness
   check. A model with mutations is the exhaustiveness check a lint cannot be for them, because they are properties
   of interleavings, not of statement shapes.
6. **Layer D has real mass, mostly Tier 2 and mostly early.** 51 root causes are N, 27 of them under boundary
   arithmetic and types. 17 are Tier 1: encoder value faithfulness (5: #461, #465, #567, #781, #821), carried
   attributes and key semantics (5: #445, #457, #499, #566, #780), retention arithmetic (4: #451, #565, #649,
   #627), collation routing (2: #456, #568) and the hypertable dimension kind (#458). Only #627 is from pass 9
   onward. That
   meets section 7's bar for Phase 6 (Tier 1/2 mass in grid arithmetic, zones and encodings). It is a separate,
   cheaper lever (Python with Hypothesis, differential against the SQL), and it should not delay layer A.

## Modelling order

Weighed by open expressible mass, with Tier 1 first and per-PR mass as the tie-breaker:

| order | protocol | open expressible root causes (T1) | per-PR rounds | why here |
|---|---|---|---|---|
| 1 | **CU custody** | 30 (23) | 24 | largest open Tier 1 mass; four of its five invariants (DropOnlyCovered, ArchiveNoClobber, NoLostRow, ResolveByRecord) are exactly 4.3's; the young Tier 1 of passes 11 to 13 and the backlogs live here (#1159, #1259, #1363, #1141 b1, #1336 b8); its environment is OD, SG, OC (direct strategy calls) and SB, which forces the base module to carry identity and name, session rendering and the store from the start |
| 2 | **RG regrain** | 28 (19) | 23 | second by mass, and the classic shape for TLA+ (capture, copy, reconcile, swap); needs NoStaleRow, snapshots per isolation level (#1241, #1258) and drift (L-DRIFT); #1253's ten rounds are its retrodiction set for the snapshot wait |
| 3 | **HT hypertable migration** | 14 (9) | 1 | reuses regrain's capture and wait modules; adds drains racing the cutover (#1158, #1218) and the count-only conservation class (#653) |
| 4 | **TM transmute and untransmute** | 18 (5) | 0 | mostly Tier 2 (WritesNotRefused after a failed phase, the reaper); its Tier 1 (#443, #1157, #872 b2) are custody-shaped and partly covered by modules 1 and 2 |
| 5 | **GR obtain and the grid** | 11 (1) | 0 | mostly A; the naming injectivity and lattice rules may be better served by layer D than by TLC |
| later | MT sweep | 4 (0) | 0 | small NoWedge module over the sweep's budgets; cheap once Base exists |
| not modelled | EN encoders | 1 (1) | 0 | layer D |

Custody is a broad module. For Phase 1, scope it to the automatic chain (the write block, the archive step with the
strategy as an untrusted caller, the ledger and its marks, the detach dispatch and reap, retire, the drop, and the
store). The synchronous exports (#463, #464, #976, #872 b5, #1030 b1, 5 root causes) can follow in Phase 5.

### What the base module has to contain (from the data, not from preference)

1. Relations with oid, schema and name separate, and operator actions that rename, SET SCHEMA, drop, create a
   namesake, detach (plain and concurrent, including interrupted) and attach. These drive 38 root causes, 27 of them
   Tier 1.
2. The attachment state machine with a pending state, and the dispatch through pg_cron as its own asynchronous
   process that can fail (#724, #893, #1157, #1259, #705, #1250's rounds).
3. Trigger enabled state (ALWAYS, ORIGIN, DISABLED) and a replica-role writer (#450, #651, #654, #892).
4. A stored value as (text, rendering session), parsed per reading session. This is the SG abstraction, behind 15 root
   causes and 11 Tier 1.
5. Snapshots per isolation level, a long reader, and snapshot export and import (#1241, #1258, #1253's rounds).
6. Initial states from older installs: origin-only blocks, unanchored `pgpm.part` rows (pre-#421), offset-less
   bounds (pre-#977), in-flight runs across an upgrade (#650, #878 b2, #892, #1160, #1392's rounds).
7. The object store as a key-value map with a normalising key function and unconditional PUT (#502, #822, #823,
   #1260).
8. Privileges at three levels (owner, granted writer, stranger) and a per-role visibility filter for RLS (#825, #873,
   #974, #1070).

## Limits of this catalogue

- **One reader classified every row**, from one-line findings. Expressibility in particular is a judgement. Before
  Phase 1 builds on these shares, an independent reader should classify a random sample of about 40 root causes
  blind, and agreement should be reported. That costs about 150k tokens, and it is in the Phase 1 budget below.
- **Pass 1's tiers are its own.** Its data-loss tier includes wedges, and its tier-2 rows are classified as their
  fixing issue because the bullets are not in the repository.
- **Lens and age before pass 10 are not tags.** The `*` lenses are the reader's attribution within the pass's
  declared set. Ages are blank where the record has none.
- **Lever state is read from the tree and the records, not verified site by site.** "Closed" means a lint exists for
  the mechanism, not that the lint would fail on each historical site. Phase 1's retrodiction covers the model's
  side. The lints' own mutations cover theirs.
- **The per-PR table is incomplete.** Rounds with no stated tier are missing. Pass 12's fix phase names few round
  tiers (#1299, #1312 only).
- **Root cause by issue number undercounts and overcounts.** #503 bundles five reports of one label mechanism. #1335
  carries three distinct bullets here. The two counting units are both given so the effect is visible: it is small.

## Phase 0 cost

About 0.3M tokens, one agent, no subagents: reading the 12 records' findings, backlog and per-PR sections, the
context pack, the method doc's tier rubric, 25 issue titles, and the lever helpers in the three install files. That
is under the 1M to 2M the pack estimated, because the records' tables are structured enough to extract mechanically.
The cost is what the [limits](#limits-of-this-catalogue) above describe: one reader, no verification.

## Phase 1 budget proposal

**Recommendation: run the program as the fallback-mode lever in place of pass 14, not beside it.** `stop_check.py`
reads `stop: ceiling`. The data says the remaining Tier 1 are of the expressible kind. Pass 13 cost 5.5M tokens per
Tier 1 found. A pass beside Phase 1 would spend that again on the same two protocols the model is about to
enumerate. A pass after Phase 2, with seeds planted on both modelled and unmodelled surface, is what measures
modelled-slice yield (section 8). That is the better use of pass 14.

**Scope**: `formal/specs/Base.tla` (items 1 to 8 above, with symmetry sets) and `formal/specs/Custody.tla` (the
automatic chain), default and nightly configs, the pinned `tla2tools.jar` in a container, a `formal` track in
`./test.sh` and `ci`, and retrodiction over custody's expressible Tier 1 and 2 root causes in table A, excluding the
synchronous exports: **37 root causes** (28 Tier 1, 9 Tier 2), plus the 24 custody per-PR rounds as a second,
reported set. One model mutation per distinct mechanism, mapped to every issue it reintroduces, kept
in `formal/mutations/`.

| item | tokens |
|---|---|
| blind re-classification of a 40-root-cause sample (agreement reported) | 0.15M |
| Base module (identity and names, attachment and dispatch, triggers, sessions and rendering, snapshots, older-install Init, store, privileges) | 0.6M |
| Custody module and invariants, header comments citing each contract | 0.5M |
| TLC configs, container, `formal` track, README with scopes and abstractions | 0.25M |
| retrodiction: about 25 distinct mechanisms over the 37 root causes, at about 30k each with a TLC run | 0.75M |
| triage of the unmutated spec's counterexamples (classified, not yet reproduced: that is Phase 2) | 0.4M |
| an independent spec-fidelity read (a second agent reads the spec against the contracts, not the code) | 0.25M |
| record (`docs/formal/record.md`), PR, per-PR verification of the `formal` track | 0.3M |
| **total** | **3.2M**, ceiling **4.5M** |

For scale: one pass is about 11M and a loop about 27M, so 3.2M is about 0.3 of a pass, and less than one pass-13
Tier 1 (5.5M).

**Checkpoint at 1.5M**: Base plus Custody checking clean or with triaged counterexamples at the default config,
and the first 10 mutations run. If fewer than 5 of those 10 produce the right invariant's violation, stop and
report. That is the pack's kill criterion (recall below 0.5), applied early.

**Exit** as the pack states it: retrodiction recall of at least 0.8 on custody's expressible set, and every
counterexample of the unmutated spec triaged. TLC CPU time reported beside the tokens.

**Not in Phase 1**: reproducing counterexamples against PostgreSQL (Phase 2), the oracle (Phase 3), regrain's
module (Phase 5 in the pack's numbering, second in this order), layer D.

### Decisions for the maintainer

1. Replace pass 14 with this program, or run it beside a pass (recommended: replace).
2. The Phase 1 budget: 3.2M with a 4.5M ceiling and the 1.5M checkpoint, or another figure.
3. Custody first, as the data says, or regrain first. Regrain is the more textbook model and has #1253's ten rounds
   as a ready retrodiction set, but less open Tier 1.
4. Whether the four new invariants are accepted (NoStaleRow and WritesNotRefused for layer A; CarriedAttributes
   and ArchiveFaithful recorded for B and D only).
5. Whether Phase 6 (layer D) is approved now for zone, grid and encoder arithmetic, as a separate, cheaper track
   (51 N root causes, 17 Tier 1).

**Decided by the maintainer, 2026-10-29:**

1. The program replaces pass 14. Pass 14 runs after Phase 2, seeded on both modelled and unmodelled surface.
2. Phase 1 budget: 3.2M tokens, ceiling 4.5M, checkpoint at 1.5M (stop if fewer than 5 of the first 10 mutations
   produce the right violation).
3. Custody first.
4. All four invariants accepted as proposed: NoStaleRow and WritesNotRefused in layer A, CarriedAttributes for the
   layer-B oracle only, ArchiveFaithful for layer D only.
5. Layer D deferred until Phase 1 reports.

## A. Shipped findings, by pass

Columns: **pass** is a number, or a backlog label: `7b` to `12b` for a fix phase's verified adjacent list, `9L` to
`12L` for a lever phase's list, `P1r` for the pass-1 reconciliation. **lens**: CL concurrency and locks, TZ time and
zones, BA boundary arithmetic and types, UI upgrade and install paths, IN identity and names, OE operator error, FI
failure injection, RC resource cliffs, CD contracts versus documentation, FS fresh surface; `*` marks an attributed
lens, not a tag. **expr**: Y, A, N as above. The finding text is shortened from the record. The record and the issue
are authoritative.

| id | pass | tier | issue | age | lens | finding | protocol | invariant | environment | expr | class lever |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1-441 | 1 | 1 | #441 |  | UI* | upgrade from 0.3.0 leaves stale overloads; schedule() and the tick's restore fail "is not unique" | IN | NoWedge | UP | A |  |
| 1-442 | 1 | 1 | #442 |  | UI* | uninstall leaves regrain's capture trigger, function and delta in the user's schema, still firing | IN | WritesNotRefused | CR | Y | L-UNINST |
| 1-443 | 1 | 1 | #443 |  | CL* | untransmute check-then-act without the lock drops rows committed to a forward partition during its run | TM | NoLostRow | W | Y |  |
| 1-444 | 1 | 1 | #444 |  | FI* | preserved incoming FKs dropped in phase 1, recorded only in phase 3; a phase 2/3 failure loses them | TM | CarriedAttributes | CR | Y |  |
| 1-445 | 1 | 1 | #445 |  | CD* | a PK excluding the control column is confined to the monolith; duplicate ids accepted | TM | CarriedAttributes | DV | N |  |
| 1-446 | 1 | 1 | #446 |  | BA* | reconcile derives the first fine child's name without the swap's clamp; changes discarded, swap reverts and resurrects | RG | NoStaleRow | DV | A |  |
| 1-447 | 1 | 1 | #447 |  | CL* | swap's residual reconcile stops at 100 iterations and drops the source with changes pending | RG | NoStaleRow | W | Y |  |
| 1-448 | 1 | 1 | #448 |  | OE* | aged-skip decided once per sub-range; loosening retain mid-regrain drops kept rows | RG | NoLostRow | OC | Y |  |
| 1-449 | 1 | 1 | #449 |  | CL* | TRUNCATE during a regrain not captured; the swap resurrects every truncated row | RG | NoStaleRow | W | Y | L-DRIFT |
| 1-450 | 1 | 1 | #450 |  | CL* | `session_replication_role` = replica bypasses capture and write block (ENABLE ORIGIN) | RG | NoStaleRow | WR | Y | L-ALWAYS |
| 1-451 | 1 | 1 | #451 |  | OE* | negative `p_retain` accepted; first tick drops every partition including the live one | CU | NoLostRow | OC | N | L-ARGS |
| 1-452 | 1 | 1 | #452 |  | CL* | coverage not invalidated when a write block is lifted; rows written meanwhile dropped unarchived | CU | DropOnlyCovered | W | Y | L-ALWAYS |
| 1-453 | 1 | 1 | #453 |  | CL* | `_detach_reap` finalizes a LIVE concurrent detach, not only an abandoned one | CU | NoLostRow | P2 | Y |  |
| 1-454 | 1 | 1 | #454 |  | CD* | `_archive_step` trusts `covered_hi` unvalidated; an overshooting strategy authorises a drop | CU | DropOnlyCovered | OC | Y | L-CONTRACT |
| 1-455 | 1 | 1 | #455 |  | TZ* | grid arithmetic in the caller's TimeZone; zone mismatch with `pg_cron` leaves a permanent hole | GR | RoutableWithinGrid | SG | A | L-TSTEXT |
| 1-456 | 1 | 1 | #456 |  | BA* | `text_time` bounds compare under the column's collation; KSUID recipe misroutes under `en_US` | GR | RoutableWithinGrid | DV | N |  |
| 1-457 | 1 | 1 | #457 |  | BA* | one future-dated uuidv7/`text_time` row pins the monolith's hi years out | TM | NoWedge | DV | N |  |
| 1-458 | 1 | 1 | #458 |  | CD* | `from_hypertable` migrates ZERO rows on an integer-time dimension or a non-dimension time column | HT | NoLostRow | DV | N |  |
| 1-459 | 1 | 1 | #459 |  | TZ* | `from_hypertable` on a timestamp dimension east of UTC loses the oldest chunk's first hours | HT | NoLostRow | SG | A |  |
| 1-460 | 1 | 1 | #460 |  | CL* | append-only catch-up drops rows arriving at or below the watermark | HT | NoLostRow | W | Y |  |
| 1-461 | 1 | 1 | #461 |  | BA* | Parquet DECIMAL encoder corrupts negative values in numeric(p&gt;=17) | EN | ArchiveFaithful | DV | N |  |
| 1-462 | 1 | 1 | #462 |  | CL* | Parquet reads each column in a separate statement; a concurrent write misaligns rows | EN | ArchiveFaithful | W | Y |  |
| 1-463 | 1 | 1 | #463 |  | BA* | `archive.to_s3` drops rows that tie on the control column at a page boundary | CU | DropOnlyCovered | DV | Y |  |
| 1-464 | 1 | 1 | #464 |  | IN* | `to_s3_parquet` resolves `p_child` through `search_path` and archives a same-named decoy | CU | ResolveByRecord | SG | Y | L-ARCHCHILD (closed) |
| 1-465 | 1 | 1 | #465 |  | TZ* | Parquet shifts timestamp values by the session TimeZone | EN | ArchiveFaithful | SG | N |  |
| 1-P1A-01 | 1 | 2 | #574 |  | FI* | resume with a different step or anchor (fixed by #574) | TM | RoutableWithinGrid | CR | Y | L-ARGS |
| 1-P1A-02 | 1 | 2 | #573 |  | FS* | sequence ownership left on the monolith (fixed by #573) | TM | NoWedge | DV | N |  |
| 1-P1A-03 | 1 | 2 | #510 |  | IN* | derived names truncated at 63 bytes (fixed by #510) | GR | RoutableWithinGrid | DV | A | L-NAME |
| 1-P1A-04 | 1 | 2 | #509 |  | FI* | `transmute_abort` refuses the owner's own session (fixed by #509) | TM | WritesNotRefused | CR | Y |  |
| 1-P1A-05 | 1 | 2 | #509 |  | OE* | transmute re-run on a managed table (fixed by #509) | TM | WritesNotRefused | CR | Y | L-ARGS |
| 1-P1B-01 | 1 | 2 | #514 |  | CL* | `lock_timeout` not re-applied before auto-regrain (fixed by #514) | MT | NoWedge | RL | Y |  |
| 1-P1B-02 | 1 | 2 | #708 |  | CL* | reapers wait unbounded for their lock (fixed by #657, #708) | TM | NoWedge | RL | Y |  |
| 1-P1B-03 | 1 | 2 | #590 |  | CL* | auto-regrain candidate search outside the step's handler (fixed by #590) | MT | NoWedge | RL | Y |  |
| 1-P1B-04 | 1 | 2 | #498 |  | IN* | incoming FK definition replayed under another `search_path` (fixed by #498) | TM | ResolveByRecord | SG | A | L-FKDEF |
| 1-P1C-01 | 1 | 2 | #513 |  | BA* | a run of ties stops the archive chunk (fixed by #513) | CU | NoWedge | DV | N |  |
| 1-P1C-02 | 1 | 2 | #507 |  | BA* | max()/min() over uuid (fixed by #507) | CU | NoWedge | DV | N |  |
| 1-P1C-03 | 1 | 2 | #511 |  | FS* | ledger rows survive a regrain swap (fixed by #511) | CU | NoWedge | none | Y | L-RECCHUNK |
| 1-P1C-04 | 1 | 2 | #454 |  | CD* | a (lo, lo) ledger row collides with the next tick's (fixed by #454) | CU | NoWedge | OC | Y | L-CONTRACT |
| 1-P1C-05 | 1 | 2 | #519 |  | FS* | retire() leaves a retired cell's regrain copies (fixed by #519) | CU | NoWedge | none | Y |  |
| 1-P1D-01 | 1 | 2 | #578 |  | BA* | int ceiling overflow aborts obtain (fixed by #578) | GR | RoutableWithinGrid | DV | N |  |
| 1-P1D-02 | 1 | 2 | #787 |  | FS* | hypertable cutover does not carry owner, grants, RLS, policies (fixed by #787) | HT | CarriedAttributes | ST | A | L-CARRY |
| 1-P1D-03 | 1 | 2 | #949 |  | CD* | tracking delta not granted to the hypertable's writers (fixed by #949, #979) | HT | WritesNotRefused | ST | Y | L-GRANT |
| 1-P1D-04 | 1 | 2 | #816 |  | BA* | hypertable shapes refused only after the swap (now Tier 3, open #816) | HT | WritesNotRefused | DV | N |  |
| 1-P1D-05 | 1 | 2 | #552 |  | IN* | hypertable working names over 63 bytes (fixed by #552) | HT | NoWedge | DV | A | L-NAME |
| 1-P1E-01 | 1 | 2 | #520 |  | BA* | SigV4 signer encoding (fixed by #520) | EN | NoWedge | DV | N |  |
| 1-P1E-02 | 1 | 2 | #586 |  | BA* | Parquet infinity timestamps (fixed by #586) | EN | NoWedge | DV | N |  |
| 2-F1-08 | 2 | 1 | #499 |  | FS* | cutover replays triggers without tgenabled; a DISABLED trigger fires again and rewrites rows | TM | CarriedAttributes | DV | N | L-CARRY |
| 2-F10-07 | 2 | 1 | #500 |  | TZ* | native bounds stored in the writer's DateStyle; a tick under ISO reads them wrong and drops live partitions | CU | NoLostRow | SG | A | L-TSTEXT |
| 2-F5-03 | 2 | 1 | #498 |  | IN* | incoming FK recorded unqualified, replayed under `pg_cron`'s `search_path` against a namesake | TM | ResolveByRecord | SG | A | L-FKDEF |
| 2-F6-02 | 2 | 1 | #501 |  | TZ* | archive encoders ignore `partition_tz` on a naive column, upload the wrong rows, report full coverage | CU | DropOnlyCovered | SG | A |  |
| 2-F6-03 | 2 | 1 | #502 |  | BA* | object key drops the sign of lo; chunks -10000 and 10000 share a key, one overwrites the other | CU | ArchiveNoClobber | DV | A | L-KEYINJ |
| 2-F9-03 | 2 | 1 | #496 |  | IN* | parent renamed mid-regrain: capture writes the old delta name, reconcile reads the new one, swap loses changes | RG | NoStaleRow | OD | Y | L-SCRATCH |
| 2-F9-04 | 2 | 1 | #497 |  | CL* | reconcile deletes delta rows &lt;= watermark including one committed after its apply; UPDATE reverted | RG | NoStaleRow | W | Y |  |
| 2-F1-04 | 2 | 2 | #504 |  | TZ* | date key, day step, non-UTC zone: monolith bound wrong, VALIDATE fails, NOT VALID CHECK left rejecting today | TM | WritesNotRefused | SG | A | L-ARGS |
| 2-F1-05 | 2 | 2 | #510 |  | IN* | `_part_name` truncates at 63 bytes; obtain skips every forward cell by name | GR | RoutableWithinGrid | DV | A | L-NAME |
| 2-F1-06 | 2 | 2 | #504 |  | TZ* | naive hourly cells either side of fall-back render equal; empty range bound every tick | GR | RoutableWithinGrid | DV | N |  |
| 2-F1-07 | 2 | 2 | #509 |  | OE* | re-running transmute on a converted table adds the bound to the live parent | TM | WritesNotRefused | CR | Y | L-ARGS |
| 2-F10-02 | 2 | 2 | #507 |  | BA* | `_next_archive_chunk` uses max(uuid); every tick `skip_archive`, never retired | CU | NoWedge | DV | N |  |
| 2-F10-03 | 2 | 2 | #513 |  | BA* | a unit holding a chunk's worth of rows stops the chunk at lo; never archived further | CU | NoWedge | DV | N |  |
| 2-F10-05 | 2 | 2 | #508 |  | FS* | untransmute of a write-blocked monolith leaves `pgpm_write_block` on the restored table | TM | WritesNotRefused | none | Y |  |
| 2-F10-06 | 2 | 2 | #511 |  | FS* | regrain of a partly archived child keeps the source's ledger rows; pkey collision every tick | CU | NoWedge | none | Y | L-RECCHUNK |
| 2-F10-08 | 2 | 2 | #511 |  | CD* | guide's rename procedure orphans ledger rows; pkey collision every tick | CU | NoWedge | OD | Y | L-RECCHUNK |
| 2-F10-10 | 2 | 2 | #512 |  | IN* | `v_nsp`::regnamespace on a quoted schema name raises every tick | CU | NoWedge | DV | N |  |
| 2-F2-03 | 2 | 2 | #505 |  | TZ* | month floor/next disagree in a DST-gap zone; regrain swap overlaps forever | RG | NoWedge | DV | N |  |
| 2-F2-04 | 2 | 2 | #507 |  | BA* | regrain copy seeds its watermark with max(uuid) | RG | NoWedge | DV | N |  |
| 2-F2-05 | 2 | 2 | #503 |  | TZ* | `set_partition_tz` moves day labels onto neighbours; obtain skips by name, a hole | GR | RoutableWithinGrid | OC | A | L-NAME |
| 2-F2-06 | 2 | 2 | #503 |  | TZ* | Azores fall-back: two day cells share a label; a hole every autumn | GR | RoutableWithinGrid | DV | A | L-NAME |
| 2-F3-03 | 2 | 2 | #514 |  | CL* | maintain does not re-apply `lock_timeout` before auto-regrain; the swap's ACCESS EXCLUSIVE queue blocks the table | MT | NoWedge | RL | Y |  |
| 2-F4-03 | 2 | 2 | #508 |  | CD* | untransmute returns the monolith with `pgpm_write_block` still on it | TM | WritesNotRefused | none | Y |  |
| 2-F8-03 | 2 | 2 | #504 |  | TZ* | `set_partition_tz` on a naive column shifts new bounds against old ones; a hole | GR | RoutableWithinGrid | OC | A |  |
| 2-F8-04 | 2 | 2 | #503 |  | TZ* | Sydney day labels collide at fall-back; a hole | GR | RoutableWithinGrid | DV | A | L-NAME |
| 2-F8-05 | 2 | 2 | #503 |  | TZ* | zone change renames cells onto neighbours; obtain skips the first new cell | GR | RoutableWithinGrid | OC | A | L-NAME |
| 2-F8-06 | 2 | 2 | #506 |  | TZ* | transmute resumed in a different TimeZone records the new zone; obtain half-overlaps the monolith | TM | RoutableWithinGrid | CR | A | L-ARGS |
| 2-F9-06 | 2 | 2 | #496 |  | CD* | capture trigger runs as the writer; the delta has no grants; app writes refused for the whole regrain | RG | WritesNotRefused | ST | Y | L-GRANT |
| 2-F9-08 | 2 | 2 | #507 |  | BA* | regrain copy resume via max(uuid) | RG | NoWedge | DV | N |  |
| 2-F9-09 | 2 | 2 | #503 |  | TZ* | New York fall-back: two day cells share a label; Monday writes refused | GR | RoutableWithinGrid | DV | A | L-NAME |
| 2-F9-10 | 2 | 2 | #515 |  | BA* | `set_regrain` '30 days' on a month grid accepted; nosubdiv every tick, children behind it never regrained | RG | NoWedge | OC | N |  |
| 3-F1-09 | 3 | 1 | #566 |  | FS* | transmute does not carry publication membership; forward partitions silently not replicated | TM | CarriedAttributes | none | N | L-CARRY |
| 3-F2-07 | 3 | 1 | #568 |  | BA* | ICU numeric collation accepted for cuid; rows routed a month early, retain drops them early | GR | NoLostRow | DV | N |  |
| 3-F3-04 | 3 | 1 | #569 |  | FI* | janitor reaps capture but keeps copies after a hand-cleared cursor; swap resurrects and reverts | RG | NoStaleRow | CR | Y | L-DRIFT |
| 3-F3-06 | 3 | 1 | #570 |  | TZ* | reconcile round-trips captured keys through bare ::text; IST misfiles a DELETE, swap resurrects | RG | NoStaleRow | SG | A | L-TSTEXT |
| 3-F4-03 | 3 | 1 | #564 |  | OE* | block dropped by hand, a write, retire() trusts stale coverage and drops it | CU | DropOnlyCovered | OD | Y | L-ALWAYS |
| 3-F4-06 | 3 | 1 | #565 |  | BA* | retain '-1 year 360 days' passes the sign check; horizon in the future drops live rows | CU | NoLostRow | OC | N | L-ARGS |
| 3-F5-02 | 3 | 1 | #567 |  | BA* | Parquet decodes negative numeric scale as 2046; every value archived as zero | EN | ArchiveFaithful | DV | N |  |
| 3-F6-02 | 3 | 1 | #563 |  | FI* | hypertable cutover commits the swap, then transmute refuses; FKs and sequence position lost | HT | CarriedAttributes | CR | Y |  |
| 3-F9-03 | 3 | 1 | #569 |  | FI* | restart branch gated on cursor; copies with no capture behind them swapped in | RG | NoStaleRow | CR | Y | L-DRIFT |
| 3-F1-01 | 3 | 2 | #573 |  | FS* | serial sequence left OWNED BY the monolith; retention's DROP fails every tick | TM | NoWedge | DV | N |  |
| 3-F1-03 | 3 | 2 | #574 |  | FI* | transmute re-run with a different step resumes the old bound; a permanent hole | TM | RoutableWithinGrid | CR | Y | L-ARGS |
| 3-F1-04 | 3 | 2 | #575 |  | IN* | reaper matches the claim by name; a rename mid-conversion leaves the bound with no claim | TM | WritesNotRefused | OD | Y | L-BYNAME (closed) |
| 3-F1-06 | 3 | 2 | #576 |  | FS* | preserve FKs from a partitioned referencer iterates clones; every cutover fails, bound left | TM | WritesNotRefused | DV | N |  |
| 3-F1-08 | 3 | 2 | #577 |  | CL* | untransmute VALIDATEs preserved FKs under ACCESS EXCLUSIVE; a scan under the lock | TM | NoWedge | none | A |  |
| 3-F10-02 | 3 | 2 | #571 |  | BA* | tie extension reads min(uuid); archiving wedged | CU | NoWedge | DV | N |  |
| 3-F2-02 | 3 | 2 | #581 |  | BA* | negative step accepted; unsatisfiable bound committed, table rejects writes | TM | WritesNotRefused | OC | N | L-ARGS |
| 3-F2-03 | 3 | 2 | #582 |  | BA* | sub-minute step: two cells one name; every other cell never built | GR | RoutableWithinGrid | OC | A | L-NAME |
| 3-F2-04 | 3 | 2 | #583 |  | TZ* | `set_partition_tz` checks only the newest bound; the monolith can never be regrained | RG | NoWedge | OC | N |  |
| 3-F2-05 | 3 | 2 | #581 |  | TZ* | date column with hourly step accepted; bound left rejecting today | TM | WritesNotRefused | OC | N | L-ARGS |
| 3-F2-06 | 3 | 2 | #584 |  | TZ* | doubled fall-back midnight: floor above its input; VALIDATE fails every run | GR | NoWedge | DV | N |  |
| 3-F2-08 | 3 | 2 | #582 |  | BA* | 20-digit id labels truncated to 19; obtain skips the cell at 10^19 | GR | RoutableWithinGrid | DV | A | L-NAME |
| 3-F3-03 | 3 | 2 | #585 |  | IN* | parent renamed mid-regrain: the in-progress child re-rendered under the new name; swap overlaps forever | RG | NoWedge | OD | Y | L-PARTREL (closed) |
| 3-F4-04 | 3 | 2 | #578 |  | BA* | int ceiling overflow in CREATE TABLE aborts the whole obtain; grid stops growing | GR | RoutableWithinGrid | DV | N |  |
| 3-F4-07 | 3 | 2 | #571 |  | BA* | tie extension min(uuid) (second report) | CU | NoWedge | DV | N |  |
| 3-F4-09 | 3 | 2 | #579 |  | RC* | `maintain_all` shares one `statement_timeout` across parents; the tail is starved forever | MT | NoWedge | RC | A |  |
| 3-F5-06 | 3 | 2 | #587 |  | RC* | GZIP encode creates temp tables per call; a tick exhausts the lock table | EN | NoWedge | RC | N |  |
| 3-F5-09 | 3 | 2 | #586 |  | BA* | Parquet timestamptz infinity raises; partition and everything behind it wedged | EN | NoWedge | DV | N |  |
| 3-F8-01 | 3 | 2 | #572 |  | UI* | after the #503 upgrade a legacy label holds the next cell's name; obtain skips it | GR | RoutableWithinGrid | UP | A | L-NAME |
| 3-F8-03 | 3 | 2 | #571 |  | BA* | tie extension min(uuid) (third report) | CU | NoWedge | DV | N |  |
| 3-F9-04 | 3 | 2 | #580 |  | CL* | regrain() holds the capture lock across the copy; deadlock with any writer at the swap | RG | NoWedge | W | Y |  |
| 4-F2-07 | 4 | 1 | #649 |  | BA* | retain 'NaN' passes the id sign check; one tick drops every partition | CU | NoLostRow | OC | N | L-ARGS |
| 4-F3-03 | 4 | 1 | #650 |  | UI* | regrain in flight across the upgrade never gets the TRUNCATE guard; swap resurrects truncated rows | RG | NoStaleRow | UP | Y | L-DRIFT |
| 4-F4-03 | 4 | 1 | #651 |  | UI* | coverage recorded under an origin-only block kept after the flip to ALWAYS; replica-written row dropped | CU | DropOnlyCovered | UP | Y | L-ALWAYS |
| 4-F4-07 | 4 | 1 | #652 |  | OE* | retire() drops a partition an operator detached to keep (unreferenced path) | CU | ResolveByRecord | OD | Y | L-DISPATCH |
| 4-F6-02 | 4 | 1 | #653 |  | CL* | hypertable conservation check by count; a delete and a late append cancel, a row lost and one resurrected | HT | NoLostRow | W | Y |  |
| 4-F6-05 | 4 | 1 | #654 |  | CL* | hypertable capture origin-only; a replica-role UPDATE in the window is reverted | HT | NoStaleRow | WR | Y | L-ALWAYS |
| 4-F6-06 | 4 | 1 | #655 |  | IN* | derived delta name equals a 63-byte parent's own name; cancel TRUNCATEs, untransmute and uninstall DROP the table | RG | ResolveByRecord | DV | A | L-SCRATCH |
| 4-F1-02 | 4 | 2 | #656 |  | CL* | transmute reseeds identity from a preflight read; concurrent ids re-issued, inserts fail | TM | WritesNotRefused | W | Y |  |
| 4-F1-08 | 4 | 2 | #657 |  | CL* | reaper drops the bound with no `lock_timeout`; one reader parks it and the table queues | TM | NoWedge | RL | Y |  |
| 4-F1-11 | 4 | 2 | #658 |  | OE* | dangling `pgpm.dropped_fk` record; untransmute and regrain die every time | TM | NoWedge | OD | Y |  |
| 4-F10-06 | 4 | 2 | #664 |  | BA* | finite timestamptz past int64 micros raises in Parquet every tick | EN | NoWedge | DV | N |  |
| 4-F2-02 | 4 | 2 | #659 |  | BA* | KSUID decode rounds with numeric division; VALIDATE fails every run | TM | WritesNotRefused | DV | N | L-FLOORDIV |
| 4-F2-03 | 4 | 2 | #660 |  | TZ* | `set_partition_tz` mid-regrain accepted; swap refuses on every attempt | RG | NoWedge | OC | A |  |
| 4-F2-04 | 4 | 2 | #661 |  | BA* | a malformed `text_time` id becomes the frontier; obtain raises every tick | GR | RoutableWithinGrid | DV | N |  |
| 4-F2-06 | 4 | 2 | #659 |  | BA* | `_grid_floor` rounds with numeric division; floor above its input | GR | WritesNotRefused | DV | N | L-FLOORDIV |
| 4-F4-04 | 4 | 2 | #662 |  | CL* | `sweep_turn_at` UPDATE outside any handler; a held config row stops the sweep | MT | NoWedge | OC | Y |  |
| 4-F4-05 | 4 | 2 | #662 |  | CL* | `obtain_retry_after` UPDATE escapes 55P03; obtain sweep stops | MT | NoWedge | OC | Y |  |
| 4-F4-06 | 4 | 2 | #663 |  | UI* | upgraded Tokyo day grid: fallback name &gt; 63 bytes raises; obtain fails every tick | GR | RoutableWithinGrid | UP | A | L-NAME |
| 4-F6-07 | 4 | 2 | #665 |  | CL* | hypertable cutover's ACCESS EXCLUSIVE with no `lock_timeout` blocks the table behind a reader | HT | NoWedge | RL | Y |  |
| 5-F3-02 | 5 | 1 | #723 |  | IN* | reconcile writes a completed child by recorded NAME; a renamed-aside copy and a stranger take the writes | RG | ResolveByRecord | OD | Y | L-PARTREL (closed) |
| 5-F4-03 | 5 | 1 | #724 |  | CL* | retention loosened while a concurrent detach is dispatched; cron detaches, nothing re-attaches | CU | NoLostRow | OC | Y | L-DISPATCH |
| 5-F2-01 | 5 | 2 | #725 |  | CL* | `set_partition_tz` takes no lock obtain holds; concurrent uncommitted cells leave a hole | GR | RoutableWithinGrid | P2 | Y |  |
| 5-F2-06 | 5 | 2 | #726 |  | IN* | orphan guard regex matches only 19-digit labels; an orphan holds a forward cell's name | GR | RoutableWithinGrid | CR | A | L-NAME |
| 5-F4-05 | 5 | 2 | #727 |  | IN* | after SET SCHEMA every step resolves partitions in the parent's schema; retention wedged | CU | NoWedge | OD | Y | L-PARTREL (closed) |
| 5-F5-02 | 5 | 2 | #728 |  | CD* | LATIN1 database: text signer hashes UTF8 but sends server bytes; store refuses every tick | EN | NoWedge | DV | N |  |
| 6-F1-05 | 6 | 1 | #780 |  | OE* | untransmute hands back conversion-time publication membership, not the parent's | TM | CarriedAttributes | OC | N | L-CARRY |
| 6-F1-07 | 6 | 1 | #779 |  | OE* | a view follows the oid into the monolith; after transmute it returns only monolith rows | TM | CarriedAttributes | DV | A | L-OIDDEP |
| 6-F4-01 | 6 | 1 | #778 |  | OE* | after SET SCHEMA `_retain_recall` resolves in the parent's schema; detach stays armed, rows vanish | CU | NoLostRow | OD | Y | L-PARTREL (closed) |
| 6-F5-02 | 6 | 1 | #781 |  | BA* | NDJSON under `extra_float_digits` = 0 archives float8 rounded | EN | ArchiveFaithful | SG | N |  |
| 6-F8-01 | 6 | 1 | #778 |  | FI* | same as F4-01 (second report) | CU | NoLostRow | OD | Y | L-PARTREL (closed) |
| 6-F1-06 | 6 | 2 | #782 |  | FS* | REPLICA IDENTITY not carried; UPDATE/DELETE past the monolith fail | TM | CarriedAttributes | DV | N | L-CARRY |
| 6-F10-02 | 6 | 2 | #778 |  | FI* | same as F4-01 (third report, wedge view) | CU | NoLostRow | OD | Y | L-PARTREL (closed) |
| 6-F2-05 | 6 | 2 | #788 |  | TZ* | `_next_archive_chunk` round-trips control values through ::text; IST skips the child forever | CU | NoWedge | SG | A | L-TSTEXT |
| 6-F3-01 | 6 | 2 | #783 |  | TZ* | clamped regrain sub-ranges named by UTC date; two cells one name, `skip_regrain` forever | RG | NoWedge | DV | A | L-NAME |
| 6-F3-02 | 6 | 2 | #784 |  | BA* | `set_regrain` '10.0' on bigint stored; every tick fails creating the first cell | RG | NoWedge | OC | N | L-ARGS |
| 6-F3-03 | 6 | 2 | #785 |  | OE* | ADD COLUMN mid-regrain; copies lack the column, reconcile fails forever | RG | NoWedge | OD | Y | L-DRIFT |
| 6-F4-02 | 6 | 2 | #786 |  | RC* | `set_obtain` lookahead larger than the lock table; obtain dies every tick | GR | RoutableWithinGrid | RC | A | L-BUDGET |
| 6-F6-06 | 6 | 2 | #787 |  | FS* | hypertable cutover does not carry GRANTs; every role loses access | HT | CarriedAttributes | ST | A | L-CARRY |
| 7-F3-07 | 7 | 1 | #824 |  | CL* | column dropped and re-added mid-regrain; drift signature unchanged, stale values swapped in | RG | NoStaleRow | OD | Y | L-DRIFT |
| 7-F3-10 | 7 | 1 | #824 |  | CL* | ALTER COLUMN TYPE USING rewrite mid-regrain fires no capture; pre-rewrite values swapped in | RG | NoStaleRow | OD | Y | L-DRIFT |
| 7-F5-03 | 7 | 1 | #821 |  | IN* | `row_to_json`(t) binds a column named t; only that column archived, retire drops the only copy | EN | DropOnlyCovered | DV | N |  |
| 7-F5-05 | 7 | 1 | #822 |  | IN* | object key by current schema.relname with an unconditional PUT; a namesake table overwrites the only copy | CU | ArchiveNoClobber | OD | Y | L-ARCHKEY (closed) |
| 7-F5-06 | 7 | 1 | #823 |  | BA* | object stem drops the BC era; BC and AD chunks share a key | CU | ArchiveNoClobber | DV | A | L-KEYINJ |
| 7-F6-01 | 7 | 1 | #825 |  | FI* | `from_hypertable` by a non-BYPASSRLS owner of a FORCE RLS hypertable copies only visible rows | HT | NoLostRow | ST | A | L-RLS |
| 7-F2-04 | 7 | 2 | #826 |  | IN* | control column renamed; obtain's type lookup by name returns null, syntax error every tick | GR | RoutableWithinGrid | OD | Y |  |
| 7-F4-02 | 7 | 2 | #826 |  | FI* | same as F2-04 (second report) | GR | RoutableWithinGrid | OD | Y |  |
| 8-F3-01 | 8 | 1 | #892 |  | OE* | disabled capture trigger still counts as live; swap reverts UPDATEs and resurrects DELETEs | RG | NoStaleRow | OD | Y | L-ALWAYS |
| 8-F3-04 | 8 | 1 | #892 |  | UI* | origin-only capture survives the upgrade; replica-role writes not captured | RG | NoStaleRow | UP | Y | L-ALWAYS |
| 8-F4-04 | 8 | 1 | #893 |  | OE* | `forget_missing` leaves the detach job armed by name; a re-created namesake's partition is detached | CU | ResolveByRecord | OD | Y | L-DISPATCH |
| 8-F9r-03 | 8 | 1 | #894 |  | FI* | unqualified drop table `pgpm_dbatch` drops a user table through `search_path` | HT | ResolveByRecord | DV | A | L-BYNAME (closed) |
| 8-F13-03 | 8 | 2 | #897 |  | CD* | RLS policy replay on the staging parent fails on a correlated subquery; bound left | TM | WritesNotRefused | DV | N |  |
| 8-F2-02 | 8 | 2 | #895 |  | OE* | NaN id maximum read as the frontier; a monolith [0, NaN) swallows every future id | TM | NoWedge | DV | N | L-ARGS |
| 8-F2-03 | 8 | 2 | #896 |  | OE* | null `p_tt_epoch` accepted; unsatisfiable bound committed | TM | WritesNotRefused | OC | N | L-ARGS |
| 8-F3-03 | 8 | 2 | #898 |  | CD* | outgoing FK added mid-regrain is not drift; validated under the swap's lock | RG | NoWedge | OD | Y | L-DRIFT |
| 8-F3-05 | 8 | 2 | #899 |  | BA* | fractional target on numeric(12,0); every swap fails, run wedged | RG | NoWedge | OC | N | L-ARGS |
| 8-F4-07 | 8 | 2 | #900 |  | BA* | crossing keys compared under the referencing column's collation; detach refused forever | CU | NoWedge | DV | N |  |
| 9-F3-02 | 9 | 1 | #974 |  | IN* | delta's `pgpm_seq` sequence keeps default privileges; a stranger's setval makes the swap drop rows | RG | NoLostRow | ST | Y | L-SCRATCH |
| 9-F4-05 | 9 | 1 | #977 |  | TZ* | offset-less `covered_hi` validated in the tick's zone; retire from New York drops uncovered rows | CU | DropOnlyCovered | SG | A | L-TSTEXT |
| 9-F5-03 | 9 | 1 | #975 |  | OE* | direct strategy call after retire PUTs an empty object over the only copy | CU | ArchiveNoClobber | OC | Y | L-RECCHUNK |
| 9-F5-04 | 9 | 1 | #975 |  | OE* | direct strategy call with a narrower range PUTs a subset over the chunk's key | CU | ArchiveNoClobber | OC | Y | L-RECCHUNK |
| 9-F5-05 | 9 | 1 | #976 |  | IN* | export claim keyed by parent, not relation; a namesake's export overwrites the first | CU | ArchiveNoClobber | OD | Y | L-ARCHKEY (closed) |
| 9-F4-02 | 9 | 2 | #978 |  | OE* | REPLICA IDENTITY index dropped by hand; obtain raises every tick | GR | RoutableWithinGrid | OD | N |  |
| 9-F9-08 | 9 | 2 | #979 |  | IN* | hypertable delta granted once; a writer granted later is refused until cutover | HT | WritesNotRefused | ST | Y | L-GRANT |
| 10-F3-03 | 10 | 1 | #1070 | young | FS | INSERT OVERRIDING SYSTEM VALUE duplicates `pgpm_seq`; reconcile applies early, swap drops a row | RG | NoLostRow | ST | Y | L-SCRATCH |
| 10-F5-03 | 10 | 1 | #1069 | young | FI | recorded-chunk check compares by row count; 179 different rows overwrite the only copy | CU | ArchiveNoClobber | OD | Y | L-RECCHUNK |
| 10-F3-02 | 10 | 2 | #1073 | old | CD | writer through a view lacks INSERT on the delta; writes refused for the whole regrain | RG | WritesNotRefused | ST | Y | L-GRANT |
| 10-F3-05 | 10 | 2 | #1074 | old | BA | key column named `pgpm_seq` collides with the delta's own; prepare fails every tick | RG | NoWedge | DV | A |  |
| 10-F4-05 | 10 | 2 | #1071 | old | BA | fractional `covered_hi` on a bigint grid recorded; every tick raises | CU | NoWedge | OC | N | L-CONTRACT |
| 10-F4-06 | 10 | 2 | #1072 | old | BA | `_obtain_name` catches the 63-byte refusal for one name shape only; obtain unwinds every tick | GR | RoutableWithinGrid | DV | A | L-NAME |
| 11-F1-02 | 11 | 1 | #1157 | old | CL | untransmute's gate reads through the parent; a detach-pending partition is dropped with its rows | TM | NoLostRow | CR | Y | L-PENDING |
| 11-F6-02 | 11 | 1 | #1158 | old | CL | keyless cutover reads the copy before its lock; a drain batch committed between is inserted twice | HT | NoDuplicateRow | P2 | Y |  |
| 11-F9-04 | 11 | 1 | #1159 | young | FS | whole-partition archive script picks a hand-detached partition, records 0 rows covered; retain drops | CU | DropOnlyCovered | OD | Y | L-DISPATCH |
| 11-F14-03 | 11 | 2 | #1160 | young | UI | chunk backfill before origin-only blocks are repaired; every partition held forever | CU | NoWedge | UP | Y | L-ALWAYS |
| 11-F3-02 | 11 | 2 | #1161 | old | RC | regrain swap attaches every child in one transaction with no lock budget | RG | NoWedge | RC | A | L-BUDGET |
| 11-F4-04 | 11 | 2 | #1160 | young | UI | same as F14-03 (second report) | CU | NoWedge | UP | Y | L-ALWAYS |
| 12-F14-01 | 12 | 1 | #1259 | young | FS | failed-dispatch mark plus a hand detach: archive step records coverage, retain drops | CU | DropOnlyCovered | OD | Y | L-DISPATCH |
| 12-F3-02 | 12 | 1 | #1258 | old | OE | regrain() in REPEATABLE READ copies through the caller's snapshot; a committed row is dropped | RG | NoLostRow | RR | Y | L-STRICT |
| 12-F3-04 | 12 | 1 | #1258 | old | OE | `regrain_step` swap under REPEATABLE READ ignores captured keys; an UPDATE reverted | RG | NoStaleRow | RR | Y | L-STRICT |
| 12-F5-02 | 12 | 1 | #1260 | old | OE | key claims compare text; the store folds a leading slash; a namesake overwrites the only copy | CU | ArchiveNoClobber | SB | A | L-ARCHKEY (closed) |
| 12-F3-03 | 12 | 2 | #1261 | old | FS | copy LIKE INCLUDING CONSTRAINTS validates a NOT VALID CHECK; every copy batch fails | RG | NoWedge | DV | N |  |
| 13-F19-02 | 13 | 1 | #1362 | old | CL | regrain swap DETACH names parent and source before its lock wait; a schema swap detaches a stranger's partition | RG | ResolveByRecord | OD | Y | L-BYNAME (closed) |
| 13-F2-03 | 13 | 1 | #1363 | young | UI | offset-less retired bound widened by only 12 h; a UTC-15 session's chunk is not held, its key overwritten | CU | ArchiveNoClobber | SG | A | L-TSTEXT |
| 13-F1-02 | 13 | 2 | #1364 | old | FS | `transmute_abort` drops the bound by a name rendered before its wait; lands on a namesake | TM | ResolveByRecord | OD | Y | L-BYNAME (closed) |
| 13-F4-04 | 13 | 2 | #1365 | old | IN | retire()'s referenced path resolves the child by relname alone; a namesake partition wedges retention | CU | ResolveByRecord | OD | Y | L-PARTREL (closed) |
| B7-872b2 | 7b | 1 | #872 | young* | IN* | `restore_incoming_fks` replays `dropped_fk.definition` naming the old schema; after SET SCHEMA the key lands on a namesake | TM | ResolveByRecord | OD | Y | L-FKDEF |
| B7-872b5 | 7b | 1 | #872 | old* | IN* | manual `archive.to_s3` export keys by schema and name, unconditional PUT; overwrote the only copy | CU | ArchiveNoClobber | OD | Y | L-ARCHKEY (closed) |
| B7-873b1 | 7b | 1 | #873 | young* | CD* | regrain by a non-BYPASSRLS owner of a FORCE RLS table loses every hidden row | RG | NoLostRow | ST | A | L-RLS |
| B7-873b3 | 7b | 1 | #873 | young* | CL* | FORCE RLS committed after the hypertable's up-front check; catch-up and conservation both skip a row | HT | NoLostRow | OD | Y | L-RLS |
| B7-878b2 | 7b | 1 | #878 | young* | UI* | regrain in flight across the #858 upgrade has a null source mark; a value-changing ALTER swaps a stale copy | RG | NoStaleRow | UP | Y | L-DRIFT |
| B8-955b1 | 8b | 1 | #955 | young* | IN* | `from_hypertable_copy` drops an operator's own `<rel>_pgpm_dest` and `_delta` by name | HT | ResolveByRecord | OD | Y | L-SCRATCH |
| B8-950b2 | 8b | 2 | #950 | young* | OE* | regrain delta keeps the prepare tick's owner; after a re-own every tick refused, never swaps | RG | NoWedge | OC | Y | L-SCRATCH |
| B8-952b1 | 8b | 2 | #952 | young* | BA* | numeric(6,-2) key passes the preflight; ATTACH rounds bounds, table half-converted | TM | WritesNotRefused | DV | N | L-ARGS |
| B8-952b2 | 8b | 2 | #952 | young* | UI* | NaN claim left by an older install resumes into [0, NaN) after the upgrade | TM | NoWedge | UP | N | L-ARGS |
| B9-1030b1 | 9b | 1 | #1030 | young* | CL* | `to_s3` claims the key for the child's oid, then reads by name unlocked; a re-created namesake overwrites the export | CU | ArchiveNoClobber | OD | Y | L-ARCHCHILD (closed) |
| B9-1030b3 | 9b | 1 | #1030 | young* | CD* | `archive_partition_whole.sql` writes `covered_hi` with none of #454's check; retire drops unarchived rows | CU | DropOnlyCovered | OC | Y | L-CONTRACT |
| B9-1037b1 | 9b | 2 | #1037 | young* | IN* | hypertable capture inserts into the delta by name; renaming it fails every write | HT | WritesNotRefused | OD | Y | L-BYNAME (closed) |
| B9-1039b1 | 9b | 2 | #1039 | young* | BA* | no precision rule for a step on a timestamp(p) key; '500 milliseconds' wedges the cutover | TM | WritesNotRefused | OC | N | L-ARGS |
| B9-1054b2 | 9L | 2 | #1054 | young* | TZ* | operator script writes a DateStyle-rendered watermark as ledger lo; every tick raises | CU | NoWedge | SG | A | L-TSTEXT |
| B9-1055b1 | 9L | 1 | #1055 | young* | IN* | `_pq_to_parquet` derives a name from the oid, `_pq_snapshot` reads by it; a schema swap exports a namesake's rows | EN | DropOnlyCovered | OD | Y | L-ARCHCHILD (closed) |
| B9-1057b3 | 9L | 1 | #1057 | young* | CL* | capture fast path checks the delta by name unlocked, inserts by name; a namesake takes captured keys | RG | NoStaleRow | OD | Y | L-BYNAME (closed) |
| B9-1062b2 | 9L | 1 | #1062 | young* | CL* | `_resolve_child` reads the schema in one statement and the child by name in the next; a namesake resolves | CU | ResolveByRecord | OD | Y | L-ARCHCHILD (closed) |
| B9-1064 | 9L | 1 | #1064 | young* | IN* | `_owned_key` resolves the relation by name (the next hop of #1062) | CU | ArchiveNoClobber | OD | Y | L-ARCHCHILD (closed) |
| B10-1141b1 | 10b | 1 | #1141 | young* | FI* | coverage reset deletes a retired chunk's ledger row when a namesake is adopted; the only copy overwritten | CU | ArchiveNoClobber | OD | Y | L-RECCHUNK |
| B10-771b3 | 10b | 2 | #771 | old* | OE* | claim taken under SET ROLE records a NULL start; the same session's resume refused, bound stays | TM | WritesNotRefused | ST | Y |  |
| B10-627 | 10L | 1 | #627 | old* | TZ* | retain horizon resolves an ambiguous fall-back wall time to the later instant; drops the live partition | CU | NoLostRow | DV | N |  |
| B11-705 | 11b | 1 | #705 | old* | CL* | a partition pending a concurrent detach counts as attached; retire() acts on it | CU | NoLostRow | CR | Y | L-PENDING |
| B11-709 | 11b | 2 | #709 | old* | BA* | malformed or NULL control values raise in the archive chunk reads | CU | NoWedge | DV | N |  |
| B11-1241 | P1r | 1 | #1241 | old* | CL* | a REPEATABLE READ reader older than the regrain's copies reads the range empty after the swap | RG | NoLostRow | RL | Y | L-SNAPWAIT |
| B12-1335b10 | 12b | 1 | #1335 | sibling* | IN* | retire() checks identity then locks by name; a rename plus a squatter gets the squatter dropped | CU | ResolveByRecord | OD | Y | L-BYNAME (closed) |
| B12-1336b8 | 12b | 1 | #1336 | sibling* | TZ* | `_archive_fully_covered` reads a pre-#977 offset-less live bound in the caller's zone; uncovered rows dropped | CU | DropOnlyCovered | SG | A | L-TSTEXT |
| B12-1335b1 | 12b | 2 | #1335 | young* | OE* | a mark with no dispatch record holds the one-detach slot while its parent is paused | CU | NoWedge | OC | Y | L-DISPATCH |
| B12-1335b3 | 12b | 2 | #1335 | young* | FS* | a pre-archiving detached retirement takes `archive_batch` 1's only turn every tick | CU | NoWedge | none | Y |  |
| B12-1334b8 | 12b | 2 | #1334 | young* | TZ* | `set_partition_tz` moves which labels are in reach; a preserved incoming key stays dropped | TM | CarriedAttributes | OC | A |  |
| B12-1357 | 12L | 1 | #1357 | young* | IN* | uninstall drops pgpm's recorded objects by name | IN | ResolveByRecord | OD | Y | L-BYNAME (closed) |
| B12-1358 | 12L | 1 | #1358 | old* | CL* | regrain copy INSERT by name after a lock wait | RG | ResolveByRecord | OD | Y | L-BYNAME (closed) |

## B. Found inside fix PRs by per-PR verification

Kind: **in surface** means pre-existing on `main` and reached through the PR's surface. **regression** means the PR's
own head introduced it. **PR's own check**, **PR's own wait** and **PR's own witness** mean a hole in the mechanism the
PR added. **sibling** and **outside surface** mean the same mechanism at a site the PR did not touch. Most never
reached `main`. They are the injection channel the program is meant to close.

| id | phase | tier | PR and round | kind | finding | protocol | invariant | environment | expr | class lever |
|---|---|---|---|---|---|---|---|---|---|---|
| R-1046-1 | lever 10 | 1 | #1046 r1 | in surface | whole-partition strategy run under the caller's RLS with no refusal | CU | DropOnlyCovered | ST | A | L-RLS |
| R-1049-1 | lever 10 | 2 | #1049 r1 | outside surface (#1051) | core regrain capture inserts into the delta by name | RG | WritesNotRefused | OD | Y | L-BYNAME (closed) |
| R-1059-1 | lever 10 | 1 | #1059 r1 | PR's own check | the descendant check admits a swap onto one of the parent's own partitions; the chunk encodes 0 rows | EN | DropOnlyCovered | OD | Y | L-ARCHCHILD (closed) |
| R-1112-1 | fix 10 | 1 | #1112 r1 | in surface | recorded-chunk check raced a direct call against the tick | CU | ArchiveNoClobber | P2 | Y | L-RECCHUNK |
| R-1112-2 | fix 10 | 2 | #1112 r2 | regression | a column named s shadowed the Parquet digest's alias | EN | NoWedge | DV | N |  |
| R-1131-1 | fix 10 | 2 | #1131 r1 | in surface | auto-regrain scan trusted attached; a frozen hand-detached child wedged it | RG | NoWedge | OD | Y | L-DISPATCH |
| R-1131-2 | fix 10 | 2 | #1131 r2 | in surface | a regrain in flight when its source is detached by hand is orphaned | RG | NoWedge | OD | Y | L-DISPATCH |
| R-1132-1 | fix 10 | 2 | #1132 r1 | regression | owner without USAGE on its schema: definer capture's LOCK fails, app writes refused | RG | WritesNotRefused | ST | Y | L-GRANT |
| R-1132-2 | fix 10 | 2 | #1132 r2 | regression | owner-only EXECUTE refused TimescaleDB's chunk CREATE TRIGGER after OWNER TO | HT | WritesNotRefused | ST | A | L-GRANT |
| R-1109-1 | fix 10 | 1 | #1109 r1 | in surface | a uuidv7 anchor off the millisecond reached the issue's Tier 1 consequence on the head | GR | RoutableWithinGrid | DV | N | L-ARGS |
| R-1109-2 | fix 10 | 2 | #1109 r1 | in surface | transmute never held a uuidv7 step to whole milliseconds | GR | WritesNotRefused | OC | N | L-ARGS |
| R-1123-1 | fix 10 | 2 | #1123 r1 | in surface | NULL-key delta rows never purged; the swap gate waits forever | RG | NoWedge | DV | A |  |
| R-1152-1 | lever 11 | 1 | #1152 r1 | in surface | archived partition dropped by hand, its row deleted as instructed, namesake adopted: only copy overwritten | CU | ArchiveNoClobber | OD | Y | L-RECCHUNK |
| R-1152-2 | lever 11 | 2 | #1152 r1 | regression | a held partition takes every retain slot at `retain_batch` 1 | CU | NoWedge | none | Y | L-RECCHUNK |
| R-1152-3 | lever 11 | 1 | #1152 r2 | in surface | real upgrade: backfill leaves a hand-dropped partition's chunk oid-less; adopt overwrites the only copy | CU | ArchiveNoClobber | UP | Y | L-RECCHUNK |
| R-1152-4 | lever 11 | 1 | #1152 r3 | in surface | chunk under an unanchored (pre-#421) part row gets neither oid nor mark | CU | ArchiveNoClobber | UP | Y | L-RECCHUNK |
| R-1152-5 | lever 11 | 1 | #1152 r4 | in surface | pre-#421 namesake re-created under its own name: backfill attributes the old chunk to it | CU | ArchiveNoClobber | UP | Y | L-RECCHUNK |
| R-1186-1 | fix 11 | 1 | #1186 r1 | sibling | hand DETACH committed before the strategy read leaves a 0-row coverage row on both archive paths | CU | DropOnlyCovered | OD | Y | L-DISPATCH |
| R-1188-1 | fix 11 | 1 | #1188 r1 | regression | an origin-only block taken as identity on a pre-#421 install overwrote the only copy | CU | ArchiveNoClobber | UP | Y | L-ALWAYS |
| R-1188-2 | fix 11 | 2 | #1188 r1 | in surface | v0.6.0's own `set_retain` lift on upgrade | CU | NoWedge | UP | Y |  |
| R-1189-1 | fix 11 | 2 | #1189 r1 | regression | upgrade: PARALLEL SAFE function with a subtransaction | IN | NoWedge | UP | N |  |
| R-1189-2 | fix 11 | 2 | #1189 r1 | regression | upgrade: index created before its column | IN | NoWedge | UP | N |  |
| R-1250-1 | lever 12 | 1 | #1250 r1 | in surface | an older install's `retiring_at` stamp on an operator's pending partition survives; retire drops it | CU | NoLostRow | UP | Y | L-DISPATCH |
| R-1250-2 | lever 12 | 1 | #1250 r1 | in surface (#705 b3) | unlocked read between retire's checks and its DROP | CU | NoLostRow | OD | Y | L-DISPATCH |
| R-1250-3 | lever 12 | 1 | #1250 r2 | in surface | a mark on a partition whose operator detach finished before the upgrade | CU | NoLostRow | UP | Y | L-DISPATCH |
| R-1250-4 | lever 12 | 1 | #1250 r2 | in surface | no `pg_cron`: failed dispatch leaves a mark, the operator's detach is dropped | CU | NoLostRow | CR | Y | L-DISPATCH |
| R-1250-5 | lever 12 | 1 | #1250 r3 | PR's own witness | pre-fix log row vouches for an adopted mark when cron history is off or purged | CU | NoLostRow | UP | Y | L-DISPATCH |
| R-1250-6 | lever 12 | 1 | #1250 r3 | PR's own witness | history match keyed by the rendered parent name breaks on a rename | CU | ResolveByRecord | OD | Y | L-DISPATCH |
| R-1253-1 | lever 12 | 1 | #1253 r1 | PR's own wait | a NULL `backend_type` for another role's session drops it from the wait | RG | NoLostRow | ST | A | L-SNAPWAIT |
| R-1253-2 | lever 12 | 1 | #1253 r1 | PR's own wait | under regrain() a snapshot opened during the copy phase is not waited for | RG | NoLostRow | RL | Y | L-SNAPWAIT |
| R-1253-3 | lever 12 | 1 | #1253 r1 | PR's own wait | masked `pg_stat_activity` predicate (finder) | RG | NoLostRow | ST | A | L-SNAPWAIT |
| R-1253-4 | lever 12 | 1 | #1253 r2 | PR's own wait | second masked predicate (state, `xact_start`) in the own-xid branch | RG | NoLostRow | ST | A | L-SNAPWAIT |
| R-1253-5 | lever 12 | 1 | #1253 r2 | PR's own wait | an idle waited-for reader released when it runs a statement | RG | NoLostRow | RL | Y | L-SNAPWAIT |
| R-1253-6 | lever 12 | 1 | #1253 r2 | PR's own wait | masked predicate again (finder) | RG | NoLostRow | ST | A | L-SNAPWAIT |
| R-1253-7 | lever 12 | 1 | #1253 r3 | PR's own wait | session list captured once misses a snapshot imported later | RG | NoLostRow | RL | Y | L-SNAPWAIT |
| R-1253-8 | lever 12 | 1 | #1253 r4 | PR's own wait | strict comparison excludes an importer whose xmin equals the oldest running xid | RG | NoLostRow | RL | A | L-SNAPWAIT |
| R-1253-9 | lever 12 | 1 | #1253 r5 | PR's own wait | an importer copies the exported snapshot's xmin, not the exporter's | RG | NoLostRow | RL | Y | L-SNAPWAIT |
| R-1253-10 | lever 12 | 1 | #1253 r5 | PR's own wait | an exporter whose xmin equals the caller's xid is excluded | RG | NoLostRow | RL | A | L-SNAPWAIT |
| R-1253-11 | lever 12 | 1 | #1253 r6 | PR's own wait | lock-chain pass-through lets a reader queued behind a DDL go unwaited | RG | NoLostRow | RL | Y | L-SNAPWAIT |
| R-1253-12 | lever 12 | 1 | #1253 r6 | PR's own wait | a reader between the last write and the swap's commit misses the under-lock reconcile (fell later as documented) | RG | NoLostRow | RL | Y | L-SNAPWAIT |
| R-1253-13 | lever 12 | 2 | #1253 r7 | regression | chained session under `lock_timeout` 0: the poll is a cycle the deadlock detector never sees | RG | NoWedge | RL | Y | L-SNAPWAIT |
| R-1253-14 | lever 12 | 2 | #1253 r8 | regression | two own-xid waiters wait on each other | RG | NoWedge | P2 | Y | L-SNAPWAIT |
| R-1253-15 | lever 12 | 2 | #1253 r9 | regression | three-party cycle no rule breaks (documented limit #1256) | RG | NoWedge | P2 | Y | L-SNAPWAIT |
| R-1299-1 | fix 12 | 1 | #1299 | in surface | second Tier 1 in the recorded-detach hand-off | CU | DropOnlyCovered | OD | Y | L-DISPATCH |
| R-1312-1 | fix 12 | 1 | #1310 (#1312) | outside surface | whole-month `text_time` grid on an off-unit epoch lets a regrain resurrect deleted rows | RG | NoStaleRow | DV | N |  |
| R-1351-1 | lever 13 | 2 | #1351 r2 | in surface | `_mark_gone_chunks` casts a pre-#500 DMY bound bare and raises every tick | CU | NoWedge | UP | A | L-TSTEXT |
| R-1392-1 | fix 13 | 2 | #1392 r1 | in surface | upgrade repair pass for an older install's mark resolves by name | CU | NoWedge | UP | Y | L-PARTREL (closed) |
| R-1392-2 | fix 13 | 1 | #1392 r1 | in surface | #421 `child_oid` backfill adopts the operator's namesake | CU | ResolveByRecord | UP | Y | L-PARTREL (closed) |
| R-1392-3 | fix 13 | 1 | #1392 r2 | in surface | backfill and `_child_nsp` take the sole namesake of another range | CU | ResolveByRecord | UP | Y | L-PARTREL (closed) |
| R-1392-4 | fix 13 | 1 | #1392 r4 | in surface | an older retire() mark on a stranger survives the upgrade | CU | ResolveByRecord | UP | Y | L-PARTREL (closed) |
| R-1392-5 | fix 13 | 2 | #1392 r4 | in surface | same state, wedge consequence | CU | NoWedge | UP | Y | L-PARTREL (closed) |
| R-1392-6 | fix 13 | 2 | #1392 r5 | regression | round 4's repair disowns pgpm's own landed detach | CU | NoWedge | UP | Y | L-PARTREL (closed) |
| R-1392-7 | fix 13 | 1 | #1392 r6 | in surface | regrain's source lookup resolves an unanchored row by name | RG | ResolveByRecord | UP | Y | L-PARTREL (closed) |
| R-1392-8 | fix 13 | 1 | #1392 r8 | regression | round 8's routing gives `regrain_cancel` a cross-schema reach | RG | ResolveByRecord | OD | Y | L-PARTREL (closed) |
