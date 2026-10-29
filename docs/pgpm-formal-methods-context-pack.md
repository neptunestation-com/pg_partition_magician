# pgpm formal methods program: context pack

For Claude Code, working in `neptunestation-com/pg_partition_magician`. Read this whole file, then
`docs/adversarial-review.md`, `CLAUDE.md`, and every record under `docs/reviews/` before writing anything.

House style applies to everything this program commits: no em dashes, markdownlint at the pinned
version, a guard has a mutation, assert identity rather than cardinality.

## 1. Why this program exists

The adversarial review loop works. Across passes 2 to 13 it has found and fixed several hundred
defects, with measured precision, seed recall, coverage and lens rotation. It is also expensive: a
loop (pass plus fix phase) is budgeted at about 27M agent tokens, and pass 12 alone spent 11.12M
tokens for 42 findings, 4 of them Tier 1 (roughly 0.27M tokens per finding and 2.8M per Tier 1,
before the fix phase). The maintainer estimates about $12 per closed bug overall.

Two facts in the record say where a cheaper lever should aim:

1. **The Tier 1 defects cluster into a small number of shapes.** The late-survivor set names them:
   lock-then-reread (check under one view, act under another), the in-flight concurrent DDL class
   (a partition pending `DETACH ... CONCURRENTLY`), a pre-lock read, a sibling copy of a fixed
   mechanism, an older-install state, a derived name assumed free. Recent Tier 1s fit the same mould:
   regrain copying through a REPEATABLE READ caller's snapshot (pass 12), readers of a retirement
   mark left asymmetric (pass 12), archive keys colliding under the store's path normalisation
   (pass 12), untransmute's gate passing a detach-pending partition (pass 11, #1157), the hypertable
   cutover reading the copy before its lock (pass 11), a forged `pgpm_seq` letting the swap drop a
   row (pass 10), the archive's recorded-chunk check comparing by count (pass 10).
2. **Fixes are the injection channel.** The record repeatedly finds Tier 1 on the previous fix
   phase's surface ("young"), and the per-PR mode exists to close that channel.
3. **Making an invariant explicit closes a class that per-site fixes keep reopening.** Pass 13
   (`docs/reviews/2026-10-22-pass13.md`) is the clearest case. Its Tier 1s were regrain_step's swap
   DETACH by a name rendered before a lock wait (#1362, old) and an upgrade-path state on the lever
   phase's own surface (#1363, young), and the record names the class: seven Tier 1 to 3 findings
   plus the re-finds of #1355 and #1358 were statements naming a relation by a name rendered before
   a wait. The lever phase before it had fixed the sites its enumeration named, and the pass found
   the enumeration incomplete. In the fix phase, #1392 (#1365) took nine per-PR rounds, each
   finding one more place where an unanchored (pre-#421) `pgpm.part` row was resolved by name, four
   of them Tier 1. Both classes closed only when the invariant was stated and enforced
   mechanically: `_lock_oid` / `_effect_or_raise` with `scripts/check_by_name_after_wait.py` (#1409),
   and the single resolver `pgpm._part_rel` with `scripts/check_part_row_by_name.py` (#1392 round 7).
   That is `ResolveByRecord` (4.3) enforced by hand. This program does the same thing on purpose,
   before the rounds are spent, and for invariants a lint cannot read.

Nearly every Tier 1 above is a violation of one of a handful of **data-custody invariants**
(no committed row is lost, no row is applied twice, nothing is dropped that is not provably
archived, the only copy of archived data is never overwritten) under an **interleaving or
environment action** the author did not enumerate. Enumerating interleavings and environment
actions exhaustively is exactly what a model checker does, and it does it in CPU time, not tokens.

The lever phases already behave like proto-formal methods: "one preflight every entry point
inherits", "exhaustiveness checks", "conformance suites", "recorded identity". This program makes
the invariants behind those levers explicit, checks the protocol designs against them
exhaustively at small scope, and binds the PL/pgSQL to the model.

## 2. What this program is not

- **Not a verifier for PL/pgSQL.** None exists, and none is to be built. The code is verified
  indirectly: the design is model-checked, and the code is tied to the design by an executable
  invariant oracle and by trace validation (sections 5 and 6).
- **Not a replacement for the adversarial loop.** It is a new lever and a new source of claims
  under the same rules. A model counterexample is a **hypothesis** until it has an executable
  reproduction that survives a verifier, exactly as `docs/adversarial-review.md` defines.
- **Not a proof of correctness.** TLC checks finite, small instances. The value rests on the
  small-scope hypothesis (most concurrency defects appear with two or three actors and a handful of
  rows) and on the model being faithful. Both are measured, not assumed (section 8).
- **Not aimed at every tier.** Tier 4 (docs) and most identifier-quoting, encoding and resource-cliff
  defects are out of scope for the model. The invariant oracle does help Tier 5 (section 5).

## 3. Layers

| layer        | what                                                                                  | tool                                                    | binds to code by                         |
|--------------|---------------------------------------------------------------------------------------|---------------------------------------------------------|------------------------------------------|
| A            | protocol specs with custody invariants and an explicit environment                    | TLA+ (PlusCal where it reads better), TLC               | B and C                                  |
| B            | the same invariants as SQL over the live catalog and pgpm's tables                    | a `pgpm` test-schema function set                       | running inside every test and bench tick |
| C            | trace validation: recorded abstract states from real runs checked as legal spec steps | TLC trace checking, or a generated step checker         | pgpm.log plus abstract state snapshots   |
| D (optional) | executable reference model of grid and encoding arithmetic                            | Python + Hypothesis, Dafny only if Phase 0 justifies it | differential testing against the SQL     |

Layer A finds design defects. Layer B finds code that violates the invariants in any test that
reaches the state, including tests written for other purposes. Layer C finds code that takes a
step the design does not permit, which is how model and code drift is caught.

## 4. Layer A: the specs

### 4.1 Modelling rules

- **One atomic step per transaction.** A procedure that COMMITs internally is a PlusCal process
  with one label per transaction. Statements inside one transaction are one step, because
  Postgres makes them atomic. This is the main reason the model stays small.
- **Snapshots are state, not an implementation detail.** Model each session's isolation level
  and snapshot. READ COMMITTED takes a fresh view per statement, REPEATABLE READ per transaction.
  A read records the view it used; a later act under a lock may only rely on reads taken under that
  lock. Pre-lock reads and caller-snapshot defects become reachable states this way.
- **Locks are a conflict matrix over the modes pgpm actually takes.** Derive the subset from the
  code. Waiting is blocking; lock timeouts are a nondeterministic failure.
- **Relations have identity and a name, separately.** Model oid and name as distinct, with
  environment actions that rename, drop, and create a namesake. Any action that resolves by name is
  then visibly distinct from one that resolves by recorded identity.
- **Attachment is a state machine**: attached, detach-pending (concurrent detach interrupted or in
  flight), detached, dropped.
- **The archive store is an abstract key-value store** with the real key-normalisation function
  (leading slash collapse and anything else the S3-compatible stores do) and last-writer-wins
  overwrite. Uploads can fail or partially succeed per the strategy's contract.
- **Initial states include older installs.** `Init` must admit every catalog shape a supported
  upgrade path can leave behind, not only fresh installs. Derive these from `docs/reviews/`
  findings tagged with the upgrade lens and from the frozen versions.
- **Rows are abstract tokens** with a key value, a committed flag and a provenance. Payload is
  never modelled.

### 4.2 The environment (the part that finds the bugs)

Every spec composes pgpm's processes with these, each enabled unless the spec documents why not:

- **App writers**: insert, update, delete, including writes that land past the grid, writes
  during a cutover scan, and writes with explicit identity values (`OVERRIDING SYSTEM VALUE`).
- **Operator hand actions** the docs or runbook allow or do not forbid: detach, detach
  concurrently, attach back, rename, drop, create a namesake, set `session_replication_role`, call
  a pgpm procedure directly, call one from inside a REPEATABLE READ transaction, edit `pgpm.config`.
- **A stranger** holding only the privileges a non-owner role can have (sequence `setval` on a
  default-privileged scratch sequence was a Tier 1).
- **Crash or cancel** between any two transactions of any procedure, and re-run afterwards.
- **A second pgpm run** (two cron ticks, or a tick racing a manual call).

### 4.3 Invariants (starting set; Phase 0 refines it)

Write each as a TLA+ state predicate and give it a stable name; layer B reuses the names.

- `NoLostRow`: every committed row not deleted by the app and not removed by retention policy is
  present in exactly one attached partition, or the monolith, or a scratch relation the protocol
  will provably swap in.
- `NoDuplicateRow`: no row is applied twice (drain batches, delta replay, regrain copy).
- `DropOnlyCovered`: a relation holding rows is dropped only when those rows are contained in
  archive objects attributed to that relation's recorded identity and range.
- `ArchiveNoClobber`: an archive object that is the only copy of some rows is never overwritten by
  content that omits them.
- `ResolveByRecord`: every destructive action targets the relation identified by recorded identity;
  checked by making namesakes reachable.
- `RoutableWithinGrid`: a write within the documented ceiling is never refused (Tier 2 shape).
- `NoWedge` (liveness, use sparingly and with fairness on pgpm's processes only): from every
  reachable state, maintenance can make progress or reports a documented refusal.

Every invariant must come from a documented contract (README, `docs/guide.md`, `docs/reference.md`)
or a filed Tier 1/2 finding. Cite the source in a comment beside it. **Never derive an invariant
from what the code does.**

### 4.4 Protocols to model

Phase 0 decides the order from data. Candidates: regrain (copy, delta capture, swap), the
archive-then-retain custody chain, transmute and untransmute, obtain and extend_to, the
hypertable drain and cutover. Model each protocol in its own module over a shared base module of
relations, rows, locks, snapshots and the environment, so a fix to the base reaches every protocol.

### 4.5 Scope and performance

State the constants of every TLC config in the spec's header comment (for example 2 partitions,
3 rows, 2 sessions, 1 namesake). Use symmetry sets for rows and sessions. Target a full check under
10 minutes on a laptop per protocol; anything slower gets a smaller default config plus a nightly
large one. Pin the `tla2tools.jar` version and run it from a container so CI and laptops agree.

## 5. Layer B: the invariant oracle

Implement the section 4.3 invariants as SQL in a test-only schema (never installed by
`install.sql`), for example `pgpm_formal.check_invariants(p_parent regclass)` returning one row per
violation with the invariant's name and the offending identities.

To make `NoLostRow` checkable on a real database, tests need a ledger of what the app committed.
Provide a test helper that records every fixture write (key, identity, intent) in a side table, so
the oracle can compare expected and actual **by identity**, never by count.

Wire it in:

1. As a global postcondition at the end of every pgTAP file and after every bench tick. Every
   existing test then checks the structural invariants (`ResolveByRecord`, `DropOnlyCovered`
   against the archive ledger, `ArchiveNoClobber`), which is the cheapest new coverage available.
   It also directly attacks Tier 5 (assertions that pass for the wrong reason), because the oracle
   asserts identity everywhere whether or not the test author did. Two limits, both to be stated in
   `formal/README.md` and counted in the record rather than discovered later:
   - **Scope.** Test files share databases (per-file database isolation was shelved for cost), so
     a postcondition over the whole database would report one file's leftover state as another
     file's violation. Scope each check to the parents the file created, which the fixture ledger
     or a per-file registration helper records. The oracle's report names the scope it judged.
   - **Row custody needs the ledger.** `NoLostRow` and `NoDuplicateRow` can only be judged where
     the fixtures wrote through the ledger, and no existing test does. Until fixtures are migrated,
     the oracle reports those two as `not judged` for the file, never as a pass. A green run that
     judged nothing is exactly the defect `CLAUDE.md` opens with. Report the share of files where
     each invariant was actually judged, as the oracle's liveness witness.
2. In every bench harness that drives concurrency, at each observation point.
3. Per `CLAUDE.md`: the oracle is a guard, so each invariant check gets a mutation in
   `bench/mutations/` and must fail against it under `./test.sh discriminate`. Pair it with a
   liveness witness (the oracle saw the state it claims to judge).

Whether pgpm should also check some of these at runtime before destructive actions (re-verify
coverage under the lock immediately before a DROP) is a product decision for the maintainer. Propose
it with evidence; do not land it unasked.

## 6. Layer C: trace validation

The point is to catch the code taking a step the spec forbids, which is how the model is kept
honest and how sibling-copy defects show up.

1. Define an **abstraction function** in the test schema, `pgpm_formal.abstract_state()`, that
   projects the concrete database (catalog, `pgpm.config`, the archive ledger, the fixture ledger,
   the archive store listing) into the spec's variables, as JSON.
2. In test and bench runs, snapshot the abstract state at each transaction boundary of pgpm's
   procedures (`pgpm.log` already marks operations; add only test-side instrumentation). A test
   cannot run code between a procedure's internal COMMITs, so the capture point has to be inside
   them. The proposed mechanism is a constraint trigger on `pgpm.log`
   (`create constraint trigger ... after insert ... deferrable initially deferred for each row`),
   installed only by the test schema, that records `abstract_state()` keyed by
   `pg_current_xact_id()` and keeps one row per transaction. A deferred trigger fires at the
   transaction's commit, after its last statement, so the snapshot is the transaction-end state that
   section 4.1 makes one step. A plain `AFTER INSERT` trigger would not be: the swap logs
   `regrain_attach` inside its attach loop, before the remaining children are attached and the source
   is dropped, so it would record a half-done swap as a step the atomic model forbids. A transaction
   that logs several rows fires the trigger once per row at commit, all seeing the same end state;
   the per-transaction key coalesces them. pgpm never runs `SET CONSTRAINTS`, so nothing makes the
   trigger fire early; a test that does must not be traced. A rolled-back transaction leaves no
   snapshot, which is correct, since it is not a step. A transaction that writes no `pgpm.log` row
   is invisible to it.
   Enumerate those transactions per procedure, count them in the coverage metric (section 8), and
   treat each one as a gap in the trace rather than as a step that was checked.
3. Check each recorded trace against the spec: either TLC trace validation (a trace module that
   constrains behaviours to the recorded sequence) or a step checker generated from the spec's
   next-state relation. A trace that is not a behaviour of the spec is a claim: either the code is
   wrong or the spec omits a real behaviour, and the verifier decides which.
4. Add a randomized chaos driver that interleaves app writes, operator actions and crashes against
   a real container and feeds the trace checker. This is the cheap high-volume mode once layers A to
   C exist.

## 7. Phases, budgets and exit criteria

Do not disturb a pass in progress. Phase 0 can run beside one; later phases should land as a lever
phase in the existing loop's sense, through the per-PR mode.

Where this sits in the loop: after pass 13's fix phase (record PR #1421, main 057d080),
`stop_check.py` reads `stop: ceiling`. The budget the maintainer set through pass 13 is spent and
pass 14 is the maintainer's call. This program is proposed as the **fallback-mode lever**, the work
done instead of another full pass, not as an addition to one. The maintainer decides whether it
replaces pass 14 or runs beside it, and Phase 0's report should recommend which.

**Phase 0: catalogue (about 1 to 2M tokens).** Read every pass record. Build
`docs/formal/tier12-catalogue.md`: one row per Tier 1 and Tier 2 finding across all passes and
verified backlogs, with its issue, pass, age, lens, the protocol it lives in, the invariant it
violates (from 4.3, or a new one), the environment action that triggers it, whether a
finite-state model of the design could express it at all, and whether a **class lever has since
closed its mechanism** (a resolver, a preflight every entry point inherits, a lint such as
`check_by_name_after_wait.py` or `check_part_row_by_name.py`), naming the lever. For a closed
class, a model adds less finding value and mainly protects the lever's assumptions. Weigh the
modelling order by the open mass, and report both shares. Report: share of Tier 1/2 per protocol,
share expressible in a model, and the proposed modelling order. Use `gh` to read issues. Stop and
present the catalogue to the maintainer before Phase 1.

**Phase 1: first spec plus retrodiction (budget set by the maintainer after Phase 0).** Specify
the top protocol. Then back-test: for every historical Tier 1/2 on that protocol, write a **model
mutation** in `formal/mutations/` that reintroduces the defect's mechanism at the design level
(remove the re-read under lock, resolve by name, read before the lock, allow the RR snapshot) and
confirm TLC reports a violation of the right invariant. This is the model's analogue of seed recall
and of `./test.sh discriminate`. Exit: retrodiction recall of at least 0.8 on that protocol, and the
unmutated spec either passes or every counterexample is triaged.

**Phase 2: counterexamples to claims.** Turn each TLC counterexample on the current design into an
executable reproduction (multi-session shell or bench harness; pgTAP cannot give a second
session). Hand it to a verifier under the existing rules. File findings with tier, age and lens
`formal`. A counterexample that cannot be reproduced is classified as model defect, abstraction gap,
or unreproducible-in-practice, and counted (section 8).

**Phase 3: layer B.** Build the oracle and the fixture ledger, wire them into every track, add
mutations, and record every pre-existing test the oracle now fails (each is a claim).

**Phase 4: layer C.** Abstraction function, trace capture, trace checking, then the chaos driver.

**Phase 5: extend and standardise.** Model the next protocols in the Phase 0 order. Extend the
per-PR mode: a PR that changes a modelled protocol must update the spec in the same PR, pass TLC,
and keep every model mutation failing. The spec diff is part of the PR's claim and gets verified.

**Phase 6 (optional): layer D.** Only if Phase 0 shows Tier 1/2 mass in grid arithmetic, zones or
encodings: an executable Python reference for grid floors, steps, uuidv7/ULID/text orderings and
zone handling, differential-tested against the SQL with Hypothesis. Escalate to Dafny or Lean proofs
of the reference only if the maintainer asks.

## 8. Evaluation

Formal methods mostly prevent defects rather than find them, so the evaluation measures validity,
yield and prevention separately. Record all of it in `docs/formal/record.md`, per phase, in the same
spirit as the pass records.

| metric                     | definition                                                                                                         | why                                                                                 |
|----------------------------|--------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| retrodiction recall        | historical Tier 1/2 on modelled protocols that a model mutation turns into a TLC violation, over those expressible | is the model capable of seeing the defects that matter; the analogue of seed recall |
| expressible share          | Tier 1/2 a finite model could express, over all Tier 1/2 (Phase 0)                                                 | the program's ceiling                                                               |
| forward yield              | verified findings from counterexamples, oracle failures and trace failures, by tier and age                        | new defects found                                                                   |
| model fell rate            | counterexamples or trace failures that fell in verification, over those with a reproduction                        | the model's own precision; a rising rate means model drift                          |
| cost per finding           | agent tokens spent on the program, over findings; per Tier 1 separately; TLC CPU time reported beside it           | compare with pass 12: about 0.27M tokens per finding, 2.8M per Tier 1               |
| one-time vs recurring cost | tokens to build specs and oracle vs tokens per PR to maintain them                                                 | the amortisation argument                                                           |
| fix-induced Tier 1 rate    | young Tier 1/2 per merged fix PR, on modelled vs unmodelled protocols, from the next passes' age tags              | the prevention signal; the symptom that started this program                        |
| modelled-slice yield       | in the next adversarial passes, findings per unit on modelled vs unmodelled surface, with seeds planted in both    | does the next pass find less where the model is                                     |
| coverage                   | units of `install.sql` mapped to a spec action, over units in modelled protocols                                   | what the model claims to cover                                                      |

Report the comparison to the adversarial loop honestly, including where the program costs more.

**Kill criteria.** Stop and report if Phase 1 retrodiction recall is below 0.5 after one revision
of the model, or if the model fell rate exceeds 0.5, or if Phase 0 shows the expressible share below
a third. Each means the model is not seeing this codebase's defects and more modelling is reaching.

## 9. Rules for working on this program

- The spec states the **intended** design from the documented contracts. When code and spec
  disagree, do not edit the spec to match the code without a written justification citing a
  contract; a disagreement is a claim for a verifier.
- Every model mutation is kept and must keep failing, like `bench/mutations/`.
- A counterexample counts only once it reproduces against a real database.
- Every abstraction choice (what is not modelled, scope constants, fairness assumptions) is written
  in the spec header. An unstated abstraction is a defect in the spec.
- Keep specs readable by the maintainer: comments that tie each action to its procedure and
  transaction, each invariant to its source.
- Separation of roles still applies: the author of a spec does not verify its counterexamples.
- Add a `formal` track to `./test.sh` (and to `ci`) that runs TLC on every spec at its default
  config and checks every model mutation still fails.

## 10. Layout

```text
formal/
  README.md              how to run, what is modelled, scopes, abstractions
  specs/Base.tla         relations, rows, locks, snapshots, environment
  specs/<Protocol>.tla   one per protocol, with .cfg files (default and nightly)
  mutations/             one model mutation per historical Tier 1/2, named by issue
  traces/                trace-validation modules and captured traces (gitignored raw output)
docs/formal/
  tier12-catalogue.md    Phase 0 output
  record.md              metrics per phase
scripts/formal/          trace capture, step checker, chaos driver, counterexample-to-repro helpers
tests/formal/            the oracle, fixture ledger, abstraction function (test-only schema)
```

## 11. First actions

1. Read `docs/adversarial-review.md`, `CLAUDE.md`, every `docs/reviews/*.md`, `docs/guide.md`,
   `docs/reference.md`.
2. Run Phase 0 and produce `docs/formal/tier12-catalogue.md`, with the proposed modelling order
   and the expressible share.
3. Stop. Present the catalogue and a Phase 1 budget proposal to the maintainer.
