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
Every check reads the catalog, `pgpm.*` and the oracle's own tables, and returns one row per violation:
`(invariant, parent_table, identity, detail)`. A run also returns one row per invariant with its judged count,
which is the oracle's liveness witness (below).

### Row ledger (opt-in)

Recording every fixture write would mean rewriting about 170 custody files' inserts. Instead, a file opts in
with one call after it loads its fixture:

- `pgpm_formal.baseline(parent regclass)` records the identity of every row then visible through the parent:
  its primary key, or the full row's text where there is none, with its control value.
- `pgpm_formal.wrote(parent, ...)` and `pgpm_formal.deleted(parent, ...)` record a row the test writes or
  deletes AFTER the baseline, where the file does that on purpose.

The custody files are the ones that set a retention horizon or an archive strategy: about 120 core files and
the 53 archive files. Adding `baseline` to them is mechanical and is scripted, then read file by file. A file
that never calls it reports `NoLostRow` and `NoDuplicateRow` as `not judged`, never as a pass.

### Drop history

A test-only `sql_drop` event trigger in the template records every dropped table's oid, schema and name, the
transaction id, and whether the top-level statement running it was a pgpm entry point (a `call pgpm.` or
`select pgpm.` statement, read from `pg_stat_activity` for the backend). That is enough to say, after the
fact, that pgpm dropped relation X. It cannot see the rows X held. Whether the trigger fires before or after
pgpm deletes its own record of X, in the same transaction, is measured in W2 before `ResolveByRecord` relies on
it.

### Registered operator relations

`pgpm_formal.operator_owns(regclass)` marks a relation the test created as the operator's, such as a namesake
or a table attached by hand. `ResolveByRecord` reads it.

## The checks

| Invariant | SQL form | Reads | Not judged |
|---|---|---|---|
| `NoLostRow` | every baseline row not deleted by the test and not aged out (control value at or past the horizon, or retention never ran on its range) is visible through its parent, in a relation `operator_owns` names, or in a partition pgpm holds in custody (`pgpm.part` with a live retirement) | ledger, catalog, `pgpm.part`, `pgpm.config` | files without a baseline; rows written by sessions the test did not record |
| `NoDuplicateRow` | no baseline identity is visible twice through the parent or across parent and custody | ledger, catalog | files without a baseline; keyless tables whose duplicate rows are equal (counted by multiplicity there) |
| `DropOnlyCovered` | with an archive strategy set, every baseline row that is gone and was below the horizon is named by a retired ledger chunk whose range holds it and whose `child_oid` is a relation the drop history shows pgpm dropped | ledger, `pgpm.archive_ledger`, drop history | object contents (that is `ArchiveNoClobber`'s); files without an archive strategy |
| `ArchiveNoClobber` | every retired chunk's object still holds every row the chunk recorded | the store listing below | every track but the archive track |
| `ResolveByRecord` | no relation `operator_owns` names is gone or detached, unless the test did it; every drop the history attributes to pgpm is of a relation pgpm recorded | drop history, `operator_owns`, catalog | a wrong DETACH that a later step undid |
| `NoWedge`, state conjuncts | a retired chunk's relation is gone; no regrain copy outlives its source; no retirement mark stands with neither a pending detach nor a job holding its command | `pgpm.archive_ledger`, `pgpm.part`, catalog, `cron.job` where readable | the event conjuncts (a collision, a spurious refusal, a raised step, a silent candidate, a wasted turn, an upgrade holding its own chunk): layer C's |

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

1. the `sql_drop` trigger sees pgpm's drops with the attribution right, including drops inside procedures
   that COMMIT;
2. the oracle's cost per file is small next to the file (measured on the core track; the budget is a few
   percent of the suite's time);
3. the baseline reads the same rows the file wrote, through the parent, for every control kind.

## Out of scope

The four Phase 2 corrections to the model and claims C3 and C4 (#1460, #1462) stay where they are, as decided.
Runtime checks inside pgpm before a destructive step are a product decision: if the oracle's results argue for
one, the record proposes it with the evidence, and nothing lands unasked.
