# Formal methods Phase 3: the invariant oracle (design)

Phase 3 is layer B of the context pack (`docs/pgpm-formal-methods-context-pack.md`, section 5): the custody
spec's invariants, written as SQL over a real database and judged after every test file and at the
observation points of the custody bench guards. This note fixes what each check reads, what it can and cannot
judge, and how it is wired, before any of it is built. The maintainer's decisions (2026-11-20): the oracle
alone, with no model changes; an opt-in row ledger; 2.5M tokens, ceiling 3.5M; one fresh verifier per claim.

## What the database can and cannot tell the oracle

The spec states three of its invariants over events: `badDrop`, `lostDrop` and `wrongTgt` are set by the step
that drops or detaches a relation (`DropGhosts`, `JobPhase1` in `formal/specs/Custody.tla`). A real database
keeps no such trace. `pgpm.log`'s `retain_drop` row carries the parent, the range and a row count, but not the
dropped relation's oid or its rows, and once a table is dropped nothing can read what it held.

Two facts make most of that recoverable without new instrumentation in pgpm:

1. **A lost row stays lost.** A row that retention or a wrong drop removed does not come back, and an archive
   object that was overwritten does not regain what it lost. So the harm in `NoLostRow`, `DropOnlyCovered`
   and `ArchiveNoClobber` is visible at the end of a file, provided the oracle knows which rows the test
   committed. That is the row ledger's job.
2. **Every file runs in its own database.** `test.sh`'s `prove_one` clones a template per file and drops the
   clone after `pg_prove`. The oracle runs in that gap and judges the whole clone, so one file's leftovers
   are never read as another's. The exceptions are the two pg_cron files (31 and 78, which run in
   `postgres`) and the hypertable runner, which has its own loop.

What stays out of reach is the transient: a violation that a later step repaired before the file ended, and
which identity a destructive step targeted at the moment it ran. The first is layer C's (trace validation,
Phase 4). The second gets one piece of test-only history, below.

## The schema

`tests/formal/oracle.sql` creates schema `pgpm_formal` in the test template only, never from `install.sql`.
Every check reads the catalog, `pgpm.*` and the oracle's own tables. `pgpm_formal.check([scope])` returns one
row per violation, `(invariant, parent_table, identity, detail)`, and `pgpm_formal.judged()` returns one row per
invariant for the last `check()`: whether it was judged, over how many parents and identities, and how many
violations of it the file declared. That is the oracle's liveness witness (below). (Built in W2 as a separate
function rather than extra rows of `check()`, so a caller that asserts "`check()` is empty" cannot be satisfied
by a summary row, and a summary cannot be mistaken for a violation.) `scope` limits the run to named parents,
for the files that share `postgres`.

Identities, as `check()` reports them and `expect()` matches them: a row is
`jsonb_build_array(<primary key at baseline>)::text`, such as `[42]`, or `to_jsonb(row)::text` for a keyless
table, rendered under pinned settings (UTC, ISO dates, `extra_float_digits = 1`) so a baseline taken in one
session matches a check in another; a relation is `schema.name`; a `NoWedge` state is `chunk <lo>`,
`copy <child_name>` or `mark <child_name>`.

### Row ledger (opt-in)

Recording every fixture write would mean rewriting about 170 custody files' inserts. Instead, a file opts in
with one call after it loads its fixture:

- `pgpm_formal.baseline(parent regclass)` records the identity of every row then visible through the parent:
  its primary key, or the full row's text where there is none, with its control value.
- `pgpm_formal.wrote(parent, where)` and `pgpm_formal.deleted(parent, where)` record the rows the test writes or
  deletes AFTER the baseline, where the file does that on purpose. The predicate is over the parent's columns:
  `wrote` re-reads the matching rows through the parent, `deleted` evaluates it over the ledger's copy of each
  row, so it can be called before or after the DELETE.

The ledger keeps the parent's oid and its name. `transmute` makes the original table the monolith under a new
parent of the same name, so the parent a check reads is resolved then: the root of the original oid while that
is a partition, else the name.

The custody files are the ones that set a retention horizon or an archive strategy, or call a retire, recall or
forget path: 131 files in `tests/formal/custody_files.txt` (105 core, 22 archive, 4 timescale), chosen by grep and
then read. `tests/formal/migrate_baseline.py` proposes each placement and checks the result; every placement was
read and made by hand. 121 are baselined. The other ten say why on their line: seven drop every parent they build
before `check()` can run, two uninstall pgpm, and one manages its only table in another database. A file that never
calls it reports `NoLostRow` and `NoDuplicateRow` as `not judged`, never as a pass.

### Drop history

A test-only `sql_drop` event trigger in the template records every dropped table's oid, schema and name, the
transaction id, and whether pgpm made the drop. Attribution reads the call stack, not the statement text: the
trigger takes `GET DIAGNOSTICS ... = PG_CONTEXT`, and a drop pgpm makes has a `function pgpm.` frame on it,
whatever called pgpm. The backend's top-level statement in `pg_stat_activity` would not do: custody tests reach
pgpm through `DO` blocks and pgTAP wrappers (`lives_ok`, `throws_like`), whose top-level statement is the
wrapper, so pgpm's own drops would read as the test's. That is enough to say, after the fact, that pgpm dropped
relation X. It cannot see the rows X held. The trigger also records whether pgpm's catalog named X when it fired
(`pgpm.part`, `pgpm.config`, `pgpm.scratch`), which `ResolveByRecord` reads.

W2 measured that the catalog is not always enough (below): `retire()` drops before it deletes the `pgpm.part`
row, but regrain's swap deletes the source's row first, so at the trigger nothing in pgpm's catalog names a
coarse child that is not the monolith. So a second test-only trigger, on `ddl_command_end`, records every table
created under a pgpm frame (`CREATE TABLE`, `CREATE TABLE AS`, `SELECT INTO`), and a drop of a relation pgpm
created counts as recorded. Both triggers also note every oid pgpm's catalog anchors at each statement they fire on
(`anchor_seen`), and a drop of one counts as recorded too: an operator's table adopted with `adopt_partition` and
then regrained is neither created by pgpm nor named at its drop, because regrain renames it and deletes its row
first (tests/309 part B). The same trigger records each `ALTER TABLE` with the table's partitions after it,
which is what attributes a `DETACH`. Both triggers are `SECURITY DEFINER`, so a test's drop under `SET ROLE` is
recorded too, and neither ever raises.

### Registered operator relations

`pgpm_formal.operator_owns(rel regclass, parent regclass default null)` marks a relation the test created as
the operator's, such as a namesake or a table attached by hand. `ResolveByRecord` reads it. Its rows count as
kept for `NoLostRow` only for one parent: the one it is a partition of when registered, or `parent` for a table
that is no partition. W2 found the unscoped form wrong: an operator's table with an `id` column hid the lost rows
of every other baselined parent with the same key values.

### Declared violations

`pgpm_formal.expect(invariant, identity, reason, parent default null)` declares one violation the file builds on
purpose (see "Files that build a broken state on purpose"). `check()` leaves a declared violation out and
reports a declaration that matched nothing as `UnusedExpectation`, identity `<invariant>:<identity>`.

## The checks

| Invariant | SQL form | Reads | Not judged |
|---|---|---|---|
| `NoLostRow` | every baseline row not deleted by the test and not aged out (control value at or past the horizon, or no `retain_drop`, `regrain_aged` or `retain_crossing` logged over a range holding it) is visible through its parent, in a relation `operator_owns` names for that parent, in a partition pgpm holds in custody (a `retiring_at` mark with `detach_dispatched_oid` naming it, out of the parent), or in one pgpm's recall released (`retain_disown` logged over its range) | ledger, catalog, `pgpm.part`, `pgpm.config`, `pgpm.log` | files without a baseline; rows written by sessions the test did not record; a parent that is gone (the promise lasts while the parent does) |
| `NoDuplicateRow` | no baseline identity is visible twice through the parent or across parent and custody | ledger, catalog | files without a baseline; keyless tables whose duplicate rows are equal (counted by multiplicity there) |
| `DropOnlyCovered` | with an archive strategy set, every baseline row that is gone and was below the horizon is named by a retired ledger chunk whose range holds it and whose `child_oid` is a relation the drop history shows pgpm dropped | ledger, `pgpm.archive_ledger`, drop history | object contents (that is `ArchiveNoClobber`'s); files without an archive strategy |
| `ArchiveNoClobber` | every retired chunk's object still holds every row the chunk recorded | the store listing below | every track but the archive track |
| `ResolveByRecord` | no relation `operator_owns` names is gone or detached, unless the test did it; every drop the history attributes to pgpm is of a relation pgpm's catalog named (when it dropped it, or at any earlier DDL statement or drop) or pgpm created | drop, `ALTER TABLE` and creation history, `operator_owns`, catalog | a wrong DETACH that a later step undid; a drop of one pgpm partition meant for another (both recorded) |
| `NoWedge`, state conjuncts | a retired chunk's relation is gone; no regrain copy (a not-attached `pgpm.part` row) lies outside every attached partition pgpm records; no retirement mark whose dispatch pgpm recorded stands on a partition still attached and not pending, its anchors agreeing with it (name, `child_oid`, `retiring_oid`), with no recall under way and no `pgpm_detach` job holding its command | `pgpm.archive_ledger`, `pgpm.part`, catalog, `cron.job` where readable (absent: no job can hold it) | the event conjuncts (a collision, a spurious refusal, a raised step, a silent candidate, a wasted turn, an upgrade holding its own chunk): layer C's; a mark with no recorded dispatch, which the next tick re-dispatches or reports (`fail_retain_detach`); a mark whose anchors disagree with the relation, which pgpm refuses on identity every tick (`fail_retain_identity`, tests/204 C, tests/361 D and E); marks where `cron.job` exists but cannot be read |

`ArchiveNoClobber` needs object contents, which SQL cannot read: `pgpm_archive` has no read path, and judging
the archive with its own code would be the code under test grading itself. The archive track's harness lists
and decodes the bucket with the existing Python verifiers and loads `(key, row identity)` into
`pgpm_formal.store` before the oracle runs.

## Files that build a broken state on purpose

51 files write `pgpm.part` or `pgpm.archive_ledger` by hand, mostly to stand in for an older install or a
crash. Some of them will leave a state the oracle rejects, by design. Such a file declares it:
`pgpm_formal.expect(invariant, identity, reason)`. Two rules stop that list rotting into an allowlist:

- a declaration matches one identity, never a whole invariant or file;
- a declaration that matches no violation fails the file, so a fixed defect or a changed test cannot leave
  one behind.

The record counts declarations per invariant.

## Wiring

1. **Core and archive pgTAP.** `prove_one` runs `select * from pgpm_formal.check()` between `pg_prove` and the
   drop. Files 31 and 78 run it on `postgres`, scoped to the parents they created. The hypertable runner gets
   the same call after each file.
2. **Bench.** There is no shared bench library, so a new `bench/formal_check.sh` exposes one function, and the
   custody guards call it at each observation point. Which guards: the ones that drive retention or archiving
   concurrently, chosen and listed in W4, not all 216 that mention either word.
3. **Report first, then enforce.** The first full run (W6) reports and fails nothing, because every
   pre-existing failure is a claim that has not been judged yet. Once the claims are judged, a violation fails
   its file the way a `not ok` does.

## Guards on the oracle

The oracle is a guard, so `CLAUDE.md`'s rules apply to it:

- **Discrimination.** Each check gets a mutation in `bench/mutations/` that puts back the defect it exists to
  catch, chosen from the custody catalogue (a drop before coverage, a resolve by name, a lost delta row). A
  file that exercises the defect must fail under the mutant, through the oracle and not through its own
  assertions. `./test.sh discriminate` requires it.
- **Liveness.** Each run prints, per invariant, how many files it judged and how many identities it checked.
  A judged share of zero for an invariant on a track that should reach it fails the track.

## Measured before it is relied on

Three things this note assumes, each checked in W2 with a test of its own:

1. the `sql_drop` trigger attributes drops right: pgpm's drops reached directly, through a `DO` block, through a
   pgTAP wrapper and inside procedures that COMMIT are pgpm's, and a test's own `DROP TABLE`, in any of those
   wrappers, is not;
2. the oracle's cost per file is small next to the file (measured on the core track; the budget is a few
   percent of the suite's time);
3. the baseline reads the same rows the file wrote, through the parent, for every control kind.

W2 measured all three on PostgreSQL 17 and ran the three files on 15 and 18 as well. All pass on the three.

### 1. Attribution (`tests/formal/oracle_attribution_test.sql`, 26 assertions)

Every drop is recorded twice over: `by_pgpm`, the call-stack attribution the oracle uses, and `by_query`, the
top-level statement the note first proposed, kept only to measure it against. Each case's row is selected by the
dropped table's name, so a case whose drop never happened fails on a null.

| Case | `by_pgpm` | `by_query` | `pgpm.part` row at the trigger | after a COMMIT |
|---|---|---|---|---|
| `select pgpm.retain(...)` | t | t | t | f |
| `call pgpm.maintain(...)` | t | t | t | t |
| `retain()` inside `is()` | t | **f** | t | f |
| `retain()` in a `DO` block | t | **f** | t | f |
| `maintain()` called from a `DO` block | t | **f** | t | t |
| `retain()` inside `lives_ok()` | t | **f** | t | f |
| the test's own `DROP TABLE` | f | f | f | f |
| the test's `DROP` in its own procedure, after a COMMIT | f | f | f | t |
| the test's `DROP` in a `DO` block just after a pgpm call | f | f | f | f |
| the test's `DROP` inside `lives_ok()` | f | f | f | f |
| `BEGIN; select pgpm.retain(...); DROP TABLE x; COMMIT` | t, then f | t, then **t** | t, then f | f |
| a `DROP` under `SET ROLE` to a role with no grant on the history | f | f | f | f |

So the call stack is right in every case and the statement text is wrong in five: four of pgpm's drops through a
wrapper, and a test's drop in the transaction after a pgpm call, where `pg_stat_activity`'s per-transaction
snapshot still shows the earlier statement. The coordinator's change was needed. A drop in a procedure after its
COMMIT still has the procedure's frame on its stack, and the trigger, being `SECURITY DEFINER`, records a drop the
dropping role could not have written itself. Over the file, no table the test made is attributed to pgpm and every
one of pgpm's drops (at least 20) is recorded.

The second question, whether pgpm's record of X still exists when the trigger fires, has two answers:

- `retire()` and `retain()` drop first and delete the `pgpm.part` row after: the row is there (every case above).
- regrain's swap deletes its source's `pgpm.part` row BEFORE the DROP. At the trigger, `pgpm.config.monolith_oid`
  still names a monolith source, but nothing in pgpm's catalog names a coarse child pgpm made itself, nor an
  operator's table adopted into `pgpm.part` (which regrain renames to its `_to_` name first). Hence the creation
  history and the anchor history above. Without them, every regrain of a non-monolith child read as an
  unrecorded drop. Untransmute's drop of the parent is recorded through `pgpm.config`.

### 2. Cost (`tests/formal/measure_cost.sh`)

The 97 core files that set a retention horizon (`p_retain` or `set_retain`), less the two pg_cron files and the
four `test.sh` runs alone, each in its own clone of the template, serially, on PostgreSQL 17 on the Linux box.
After each file, `check()` is timed server side twice: as the files are today, with no baseline (the structural
checks only), and after `baseline()` of every parent pgpm manages at the end, which is the most a migrated file's
`check()` can read, since a file baselines only what it wrote. Every file also runs in a template without the
oracle, which prices the event triggers.

| | median | p90 | max | share of the 97 files' 231.8 s |
|---|---|---|---|---|
| `check()`, no baseline | 4.7 ms | | 21.4 ms | 0.21% |
| `check()`, whole end state baselined | 39.7 ms | | 122.6 ms | 1.91% |
| the same, per file, as a share of that file | 4.10% | 7.4% | 19.8% | |
| the event triggers, per file ((with - without) / without) | 3.0% | 8.4% | 66.6% (noise, below) | 5.4% (3.1% without 253) |

The baselined rows run to a median of 16,011 and a maximum of 66,253 (the demo fixture's managed tables are in
every clone). The four files above 10% are the shortest ones over the largest end state: tests/94, 61, 98 and 110,
about 66,000 rows each, read in about 120 ms against files of 0.6 to 1.1 s. The trigger column is noisy at the
top: tests/253 ran in 13.3 s with the oracle and 8.0 s without it, but in 9.1 s and 7.0 s with it in two earlier
runs, once faster than without; the per-file minimum is -4.7%.

One finding changed the oracle: the first full run measured a maximum of 462 ms (tests/317, 39% of the file) and
428 ms (tests/391, 42%). The per-parent statement's estimate crossed `jit_above_cost` once `pgpm.archive_ledger`
held a few thousand rows, and compiling it cost about 400 ms against 33 ms to run it. `_violations` now sets
`jit = off`, and the run above is with it.

The same run is the first time the oracle judged files it was not written against, and it found the oracle wrong
four times before it found pgpm wrong once (each oracle defect is fixed and covered, see "What W2 and W3 changed"):
tests/239 failed only with the oracle installed (a dependency onto pgpm), and tests/204, 309 and 361 reported
states pgpm reaches by design. What it reports now is one violation in one file: tests/309 part J drops a pgpm
partition, re-creates it under the same name and nulls its `child_oid` to stand in for an older install, and
regrain's swap then drops the test's table by name. That is `ResolveByRecord` exactly as defined, built on
purpose, so the file declares it in W3. No file fails with the oracle installed.

So: within the budget for `check()` (2% of the suite at its most), and the event triggers are the larger cost, at
about 3% median per file.

### 3. Baseline for every control kind (`tests/formal/oracle_baseline_kinds_test.sql`, 52 assertions)

Ten tables, one per control column type: `int`, `bigint`, `timestamptz`, `timestamp`, `date`, `uuid` (v7), and
`text` holding cuid v1, ULID, KSUID and ObjectId. Each holds seven rows labelled by age (13, 11 and 8 months
back, below the 8-month horizon; 4, 2, 1 and 0 within it; the id kinds the same shape on an id grid), written in a
session at `America/Los_Angeles` with `DateStyle = 'SQL, DMY'`, so a rendering that followed the session would
show. For each kind:

- `baseline()` over the plain table records exactly the seven payloads;
- after `transmute` and the retention-aware `regrain_history()`, exactly the four kept rows and the one written
  after (`wrote()`) are visible (LIVENESS), and `regrain_aged` was logged (all ten);
- `check()` names nothing: every aged row decoded below the horizon inside a `regrain_aged` range;
- the partition holding the 2-month row dropped by hand: `check()` names exactly that row's identity, which it
  can only do if the row's control value decoded at or past the horizon.

All ten pass on 15, 17 and 18. One thing the note did not anticipate: for the time kinds pgpm's frontier is the
clock, so the file moves pgpm's unqualified `now()` two months ahead with a `clk.now()` shim ahead of
`pg_catalog` on the `search_path` (the pattern tests/311 uses), rather than writing rows into the future. The
text kinds' and `uuid`'s frontier is data, and the shim does not disturb them.

### What W2 and W3 changed in this note

Each of these is folded into the sections above; the list is here so a reader of the earlier draft can find them.

- **Attribution by the call stack** (Codex on #1485, before W2 began), confirmed by measurement 1.
- **Recorded means named at the drop, named earlier, or created by pgpm.** The catalog at the trigger is not
  enough for regrain's swap (measurement 1), so W2 added the creation and anchor histories.
- **`ALTER TABLE` history.** `ResolveByRecord`'s "detached, unless the test did it" is attributed from a
  `ddl_command_end` record of each `ALTER TABLE` with the table's partitions after it.
- **The oracle must not depend on pgpm.** Its first form took a `pgpm.config` parameter, a `pg_depend` edge onto
  pgpm, and pgpm's uninstall refused; tests/239 failed with the oracle installed and only then. The selftest now
  asserts no such edge, and `check()` judges the drop history alone once pgpm is gone.
- **`operator_owns` is scoped to one parent**, and **a released relation** (`retain_disown`) counts as the
  operator's. Custody needs `detach_dispatched_oid` naming the relation, not only a `retiring_at` mark.
- **`NoWedge`'s mark conjunct is narrower than drafted**: marks with a recorded dispatch, still attached and not
  pending, no recall under way, anchors agreeing. Running the oracle over the retention files found three
  documented refusals it would otherwise report as wedges (tests/204 C, tests/361 D and E).
- **The judged summary is `judged()`**, not extra rows of `check()`, and its `expected` column counts the file's
  declarations per invariant; `check([scope])` takes the parents to judge.
- **A gone parent is not judged** for `NoLostRow`, and a file that loosens its horizon after a drop sees the rows
  that drop took reported as lost: the oracle reads today's horizon, not the one the drop ran under. Such a file
  declares them.
- **The control value is decoded by pgpm's own `_col_to_native`.** That is pgpm's code grading pgpm, in one narrow
  place; measurement 3 checks it against values the test wrote, for every kind, which is what keeps it honest.
- **W3: event triggers ignore temporary tables.** Creating or dropping a temporary table no longer reads pgpm's
  catalog or writes a history row. Before, the triggers took locks inside `archive._pq_snapshot`'s audit window, and
  tests/archive/db/08 failed with the oracle installed and only then.
- **W3: a drop of a hypertable pgpm converts is recorded** through `pgpm.scratch.parent_oid`, so `from_hypertable`'s
  cutover is not reported as an unrecorded drop (every timescale custody file did).
- **W3: `anchor_seen` has no unique key.** Two sessions noting the same oid waited on each other's insert and
  deadlocked (regrain_step against a test's own `ALTER TABLE` in another session, tests/345).
- **W3: the ledger follows its parent past the monolith.** `parent_seen` records the parent each baselined table
  is a partition of, whenever the triggers run. Once transmute's monolith is dropped or released, the name was all
  that was left, and a schema move or a namesake turned every row into a lost one (tests/197, 204, 349, 355).
- **W3: rows are read as `to_jsonb(t.*)`.** `to_jsonb(t)` over `from <parent> t` resolves to a column named `t`, so
  the ledger recorded that column and no control value (tests/archive/db/33 and 48).
- **W3: `retain_crossing` is retention.** `retire()` deletes a retiring partition's referenced rows so the declared
  `ON DELETE` runs, before its dispatched detach lands. `NoLostRow` excused only `retain_drop` and
  `regrain_aged` (tests/231, 253, 266).
- **W3: a retired chunk's bound that does not parse is read at its widest**, as pgpm reads it, instead of raising out
  of `check()` (tests/347 G writes two such bounds on purpose).
- **W3: wiring.** Every runner of a custody file installs the oracle: `test.sh`'s core, cron, archive and
  timescale databases, each `bench/` script that runs one, and `scripts/review/plant_seeds.py`. `check()` is not
  called yet (W4). `.github/workflows/archive.yml`'s path filter does not yet name `tests/formal/oracle.sql`,
  which `run_archive` now reads, so `scripts/check_track_filters.py` fails until W4 adds it.
- **Not measured: a `DETACH CONCURRENTLY` that pg_cron runs** in its own session. Only files 31 and 78 reach it,
  on `postgres`, where W4 must install the oracle; whether the `ddl_command_end` trigger records it there is W4's
  to check before `ResolveByRecord` judges those files.

## Out of scope

The four Phase 2 corrections to the model and claims C3 and C4 (#1460, #1462) stay where they are, as decided.
Runtime checks inside pgpm before a destructive step are a product decision: if the oracle's results argue for
one, the record proposes it with the evidence, and nothing lands unasked.
