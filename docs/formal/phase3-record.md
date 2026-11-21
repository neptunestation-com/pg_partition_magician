# Formal methods: Phase 3 record (the invariant oracle)

Phase 3 of the program in `docs/pgpm-formal-methods-context-pack.md` is layer B: the custody spec's invariants
written as SQL over a real database, judged after every pgTAP file and at the custody bench guards. It ran on
2026-11-20 and 2026-11-21. The design is `docs/formal/phase3-design.md` (merged as #1485), and the oracle, the
ledger and the wiring are PR #1486.

The maintainer's decisions (2026-11-20): the oracle alone, with no model changes; an opt-in row ledger; 2.5M
tokens, ceiling 3.5M; one fresh verifier per claim the oracle raises. The checkpoint: stop and report if the
oracle judges custody in under half the custody files, or if over half of its first failures fall in
verification.

## Headline

- **pgpm showed no new defect.** The oracle's first full run (CI on #1486, head `c655348`) raised seven claims,
  the same seven on PostgreSQL 15, 16, 17 and 18 and on every install channel. Seven fresh verifiers judged
  them: four were oracle defects and three were states the test files build on purpose. None was a defect of
  pgpm's.
- **The checkpoint tripped.** All seven first failures fell in verification, against a limit of half. The oracle
  judged custody in 121 of the 131 custody files, so the other half of the checkpoint held. The maintainer chose
  to fix the four oracle defects, declare the three built states, write this record and stop.
- **The oracle discriminates.** For every invariant but `NoDuplicateRow`, a mutation that puts a real custody
  defect back makes the oracle report it, by identity, through `bench/formal_discriminate.sh`. Taking each check
  out of the oracle fails its self-test.
- **It runs in report mode.** A violation is logged, never fails a file. A track fails only when the oracle
  itself breaks: an invariant it should reach judged nothing, the oracle raised, or a baselined custody file
  left no ledger.

## What was built

| Work item | What | Where |
| --- | --- | --- |
| W1 | the design note | `docs/formal/phase3-design.md` (#1485) |
| W2 | schema `pgpm_formal`: the row ledger, drop/ALTER/create history by event triggers, `check()`, `judged()`, `expect()`; a self-test and three measurements | `tests/formal/oracle.sql` and its tests |
| W3 | the ledger in 121 of 131 custody files; the oracle installed by every runner of one | `tests/formal/custody_files.txt`, `migrate_baseline.py` |
| W4 | a report per file on the core, archive and timescale tracks and at nine bench guards; the per-track summary and witness; the archive bucket decoded independently | `test.sh` `oracle_report`, `tests/formal/summarize.py`, `load_store.py`, `bench/formal_check.sh` |
| W5 | a guard that fails on an undeclared violation, and 14 mutations | `bench/formal_discriminate.sh`, `bench/mutations/mutate.py` |
| W6 | the first full run's seven claims, verified; the four oracle fixes and the 11 declarations | this record; `e3a184f`, `12b7f0c`, `ec42504` |

## Measured

- **Attribution.** A drop is pgpm's when the call stack at the `sql_drop` trigger has a `function pgpm.` frame.
  That was right in 12 of 12 cases, including drops reached through `DO` blocks and pgTAP wrappers, after a
  COMMIT in a procedure, and under `SET ROLE`. The top-level statement text, the first design, was wrong in 5.
- **Cost.** `check()` with every row baselined: median 39.7 ms per file, 1.9% of the retention files' run time;
  the event triggers add about 3%. On CI the core track's oracle time was 27.8 s over 371 files. The largest file,
  tests/59, took 5.8 s, because every retained row's control value is decoded through `_col_to_native`.
- **Baseline.** For all ten control kinds the baseline records exactly the rows written, under a non-UTC zone and
  an unusual DateStyle.
- **Bench.** Nine of eleven candidate guards behaved identically with and without the oracle installed and were
  wired. Two were excluded, with reasons, in the design note.

## The first full run

Per invariant, core track on PostgreSQL 17 (psql channel); the other eleven core runs match it.

| Invariant | Files judged | Identities judged | Violations |
| --- | --- | --- | --- |
| `NoLostRow` | 97 | 473,945 | 3 |
| `NoDuplicateRow` | 97 | 473,945 | 0 |
| `DropOnlyCovered` | 30 | 65,056 | 50,000 |
| `ResolveByRecord` | 191 | 1,427 | 9 |
| `NoWedge` | 62 | 62,592 | 1 |

`ArchiveNoClobber` is judged on the archive track: 322 ledger identities in 8 files, 6 violations. The timescale
track reported none. The oracle raised no error anywhere.

## The claims

Each claim went to a fresh verifier that had not seen the oracle's author's reading. It reproduced the report on
a private container and built the decisive state itself.

| Claim | File | Invariant | Verdict | Decisive fact | Action |
| --- | --- | --- | --- | --- | --- |
| F-01 | tests/223 | `ResolveByRecord` | deliberate | part B stages an operator's empty DEFAULT partition; untransmute's documented DROP of the parent takes it, and refuses when it holds a row | 1 declaration |
| F-02 | tests/276 | `NoWedge` | oracle defect | the file's closing `drop owned by` removes the parent; the oracle read the in-flight regrain copy as wedged | a copy under a gone parent is not judged |
| F-03 | tests/327 | `ResolveByRecord` | deliberate | each part kills an operator's DETACH CONCURRENTLY and calls `_detach_reap`, which finishes it under a pgpm frame | 4 declarations; the oracle is not changed, because after a FINALIZE it cannot tell whose detach it was |
| F-04 | tests/348 | `ResolveByRecord` | oracle defect | uninstall drops `_pgpm_delta` and `_pgpm_dest` by the COMMENT marker pgpm writes on them, which the oracle never read | the oracle reads the marker |
| F-05 | tests/389 | `NoLostRow` | oracle defect | the rows were retired in archived chunks; their keys have no native value, so the oracle reported them before reading any chunk | an undecodable key is matched by text order against the encoded bounds |
| F-06 | archive/40 | `ArchiveNoClobber` | deliberate | the file's cleanup deletes exactly the six objects, before the harness reads the bucket | 6 declarations |
| F-07 | tests/59 | `DropOnlyCovered` | oracle defect | the rows were retained before the file set an archive strategy; the oracle judged past drops against today's | each drop is judged against the strategy in force when it was logged |

Each fix has a self-test case that stays clean for the state the verdict calls correct and fails with the fix
reverted, and a must-still-catch case reported by identity. Each revert is kept as a mutation of the oracle
(`oracle_nowedge_gone_parent_judged`, `oracle_comment_record_unread`, `oracle_unshaped_key_unplaced`,
`oracle_droponlycovered_todays_strategy`), which `bench/formal_oracle_selftest.sh` must fail. The self-test grew
to 100 assertions and passes on PostgreSQL 15, 17 and 18. The F-07 fix needed no trigger on `pgpm.config`, which
would be a dependency pgpm's uninstall refuses: the `sql_drop` trigger records whether a strategy was set when
pgpm dropped each partition, since `retire()` drops before it deletes the `pgpm.part` row.

After the fixes, on PostgreSQL 17: all 106 core custody files and all 22 archive custody files pass with 0
undeclared violations and 0 unused declarations, and the `DropOnlyCovered` and `NoLostRow` guards still fail
their pgpm mutations (tests/64 and tests/130; tests/110, 120 and 136). The timescale custody files were left to
the PR's timescale job; F-04's comment record matters most there.

The declaration for F-01 names no parent: the DEFAULT is in no pgpm anchor, so the violation has none, and a
declaration naming `public.fv223` went unused.

## What the oracle got wrong, and what that says

Before the first full run, the oracle had already been corrected 13 times by running it: four in W2, seven in W3,
and two from Codex's review of #1486 (a keyless row's copies, and JSON-annotated Parquet leaves). W6 found four
more. The pattern is the same each time. The oracle judges an end state, and each defect is a mechanism by which
pgpm, or a test, legitimately reaches a state the oracle's reading forbids:

- history the oracle reads as current: today's horizon and today's strategy applied to yesterday's drops;
- records pgpm keeps where the oracle does not look: a COMMENT marker, an encoded bound;
- cleanup that removes what the oracle came to judge: a dropped parent, deleted objects.

Report mode was the right default for that reason. Enforcement would have failed seven files for the oracle's
mistakes and none for pgpm's.

## Limits that stand

- **Transient violations are out of reach.** A state that a later step repaired before the file ended is layer
  C's (trace validation, Phase 4).
- **pg_cron's DDL counts as pgpm's.** Any DDL a pg_cron job runs is attributed to pgpm, an operator's own job
  included.
- **`NoDuplicateRow` has no pgpm-side mutant** on the core or archive tracks: no path there can make a duplicate
  visible. The real one (#1158) is on the timescale track, and needs a ledger in tests/timescale/db/64 and a
  timescale mode in the guard.
- **Ten custody files are not judged.** Seven drop every parent they build before the check runs, two uninstall
  pgpm, and one keeps its table in a LATIN1 sibling database.
- **One narrow place where pgpm grades itself.** Control values are decoded with pgpm's own `_col_to_native`; the
  per-kind measurement is what checks it.
- **Cost on large files.** Per-row decoding makes `check()` take seconds on files with tens of thousands of
  retained rows.

## Not done in Phase 3

- **Enforcement.** The oracle stays in report mode. Turning a violation into a failing file is a decision for
  the maintainer, now that the first full run is clean.
- **Runtime checks inside pgpm** before a destructive step. Nothing in the first run argues for one, since pgpm
  showed no defect.
- **The four Phase 2 model corrections and claims C3 and C4** (#1460, #1462), out of scope by decision.

## Process

- **Landing.** #1485 (the design) merged first, separately. #1486 needed three rounds on CI before its first green
  run: premise labels in two files a new guard made wrapper-run, a bench guard that ran a baselined file without
  installing the oracle, and the two Codex findings.
- **Nested agents.** W3's agent split its work across six agents of its own, and their spend was invisible until
  they reported: W3 cost about 1.6M against a planned 0.9M. From W4 on, every brief forbade nested agents and set
  a hard cap.

## Cost

| Measure | Phase 3 |
| --- | --- |
| Budget | working 2.5M, ceiling 3.5M |
| Tokens, by estimate | about 3.6M, over the ceiling: W2 0.17M, W3 1.64M (six nested agents 1.40M), W4 0.32M, W5 0.26M, the seven W6 verifiers 0.60M, the W6 fixes 0.24M, and coordination, the design, the CI fixes and this record about 0.4M |
| Wall clock | about one and a half days |
