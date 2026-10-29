# Formal methods: Phase 1 record (custody)

Phase 1 of the program in `docs/pgpm-formal-methods-context-pack.md`, run on 2026-10-29 under the budget the
maintainer set in `docs/formal/tier12-catalogue.md` ("Decided by the maintainer"). It built a TLA+ model of the
archive-then-retain custody chain, checked it with TLC, and asked whether the model would have caught the
custody chain's own history. What is built, and how to run it, is in `formal/README.md`.

## Headline

Recall **34 of 37 = 0.92** (Tier 1 25/28, Tier 2 9/9), against an exit criterion of 0.8. Counting as misses the
three mutations caught only after a model change retrodiction itself forced, strict recall is 31/37 = 0.84. Two
of the three misses are synchronous-export root causes filed under custody in the catalogue and not modelled,
so over what the model covers recall is 34/35. The checkpoint (at least 5 of the first 10 mutations caught)
passed at 8 of 10.

Every counterexample of the unmutated spec is triaged. Two are **claims** for Phase 2 (C1, a recall re-attach
racing a launched detach run; C2, a tracked rename making recorded chunks orphans so that retire drops rows
nothing vouches for), and one is an **open question** for the maintainer (Q1). The model also caught itself
passing vacuously once, and the track now runs liveness witnesses before it trusts a clean check.

## What was built

| Piece | Where |
| --- | --- |
| The shared world: identity apart from name, attachment states, session rendering, the non-transactional store, the operator's hand actions | `formal/specs/Base.tla` (A1 to A10) |
| The custody chain: write block, archive step (split around the strategy call), ledger, key claims, `retire()` on both paths, the `pgpm_detach` dispatch, the recall, `_detach_reap`, the operator script | `formal/specs/Custody.tla` (C1 to C9, H_C1, H_C2, K1 to K8) |
| Six configs: two that must check clean, one liveness, two that must keep a claim, all in scope 2 partitions, 4 positions, 3 rows, 4 oids, 2 schemas, 3 names, zones -1..1, 2 environment steps | `formal/specs/*.cfg` |
| Liveness witnesses, with a mutation proving they discriminate | `WitTwoChunks` and four more in `Custody.tla`; `mutate.py witness` |
| Retrodiction harness: 36 mutations over the 37 custody root causes (two are not modelled), including one per-PR probe | `formal/mutations/mutate.py` |
| TLC v1.7.4 by sha256, on eclipse-temurin by digest | `formal/tlc.sh` |
| A `formal` track in `./test.sh` and `./test.sh ci`, and its workflow | `test.sh` `run_formal`; `.github/workflows/formal.yml` |
| A counterexample reader | `scripts/formal/trace_diff.py` |

## Retrodiction

The exit criterion is recall of at least 0.8 over custody's expressible Tier 1 and 2 root causes (table A of the
catalogue, excluding the synchronous exports): **37 root causes**, 28 Tier 1 and 9 Tier 2. Each mutation rewrites
the guard a fix put in place back to the shape that shipped the defect, and counts as caught only when the
unmutated spec checks clean under the same config **and** the mutant violates the invariant that defect broke.

| Set | Root causes | Caught | Missed |
| --- | --- | --- | --- |
| Tier 1 | 28 | 25 | #453; B9-1062b2 and B9-1064 (not modelled) |
| Tier 2 | 9 | 9 | none |
| **All** | **37** | **34 (0.92)** | 3 |

There are 36 mutations: one per mechanism over 35 of the root causes (#454 has two mechanisms, #502 and #823
share one), and M1259r4, a per-PR verification finding on #1259's own fix, as an extra probe. It is caught.
The two not modelled root causes are listed by `mutate.py --list` with the reason, so they stay visible.

**M453 is missed and stays recorded as missed.** `_detach_reap` finalizing a live concurrent detach needs the
model to tell a detach still running from one whose session died, and the model has no sessions that die
(fidelity M9). A model change that starts catching it fails the track until the table is updated.

### How the numbers were reached, including what changed the model on the way

Recall is reported on the final spec, and the final spec is not the one the mutations first ran against. Three
mutations were caught only after a change that retrodiction itself showed was needed. Each change was made
against the contract, not to catch the mutation, and each is flagged here so that the recall is not read as
three free catches:

- **M1160** first missed because NoWedge's conjunct "a live partition is never held over its own chunk" only
  checked chunks with a recorded `child_oid`, and the pre-upgrade chunks #1160 is about are matched by name.
  The conjunct did not say what its own comment said. It is now a ghost on the upgrade's transition (`heldOwn`),
  following the contract's attribution rule, after the fidelity read showed a state-based version also fired on
  states the contract permits (fidelity M12).
- **M1030b3** first missed because abstraction C1 made the operator script's strategy archive the whole
  remainder every time, which the byte-budget contract does not promise. A strategy may stop early and say how
  far it got, and only then can an unchecked `covered_hi` hide unarchived rows. C1 now says so.
- **M778** (a liveness mutation) first could not run, because the unmutated spec violated `NoLostRowLive`
  three times over. Two were fairness artefacts in the model: hypothesis H_C1 was a guard that only blocked,
  and an operator's started `DETACH ... CONCURRENTLY` could not finish without spending environment budget
  (now Base A10). The third is open question Q1 below. M778's config now leaves renames out.

Two mutants were broken rather than caught or missed, and were fixed before counting: M1054b2 (the model keyed
a ledger row's object by its lo's raw text rather than its instant) and M1335b10 (a by-name drop resolving to
nothing). Two composites were wrong about history and corrected: M1335b3 is a single-guard mutation (#1335 b3
was found inside #1259's own fix, so #1259's step guard was already there), and M454w needs #975's guard
removed too, since it postdates #454.

### Masking: defence in depth the model asserts

Where a later fix added a second guard over the same hole, the single-guard mutation is also run. When it comes
back clean, the model is claiming the later guard covers the earlier one's hole. Each such claim is worth a
Phase 2 reproduction:

| Mutation | Original guard put back | Later guard that covers it |
| --- | --- | --- |
| M452 | the block lifted with coverage kept | #564's tick-time check of the block |
| M454w | `covered_hi = p_lo` recorded | #975's recorded-chunk check in the strategy (turns the wedge into a skip every tick, a stall no invariant names) |
| M502 | object keys not injective in lo | #975's recorded-chunk check |
| M977 | offset-less `covered_hi` in another zone | #1336 b8's reading of offset-less bounds |
| M1159 | the script archiving a detached partition through the parent | the step's own `#1159` zero-row check |
| M1259 | a mark without the dispatch record vouching | #1259's step guard, #1335 b3, #1159 and the post-strategy re-check |
| M1363 | a retired chunk's offset-less bounds read narrow | #975's recorded-chunk check |

M454w's mask is the weakest of these: the later guard does not prevent the defect, it converts a wedge into a
silent stall, which is a liveness question the model does not yet ask of the archive.

## Counterexamples of the unmutated spec, triaged

Every counterexample the unmutated spec produced was classified (not reproduced; reproduction is Phase 2, and not
by the spec's author). Most were the model being wrong:

| Class | Count | Examples |
| --- | --- | --- |
| Model defect: the spec said something the contract does not | 14 | `copied` counted rows no chunk attested; `forget_missing` left its bookkeeping; a hand detach of a dispatched partition counted as the operator's; retire's detach path left the job armed; the operator script's duplicate key counted as a tick wedge |
| Abstraction gap, closed | 4 | a queued pg_cron run versus `DROP TABLE` on the parent; a run naming no table; the job model re-done as launch, resolve-and-pend, finalize |
| Fairness artefact, closed | 2 | H_C1 as a pure block; an operator's concurrent detach unable to finish |
| Documented limitation | 1 | the substitute detach `reference.md` "What retire checks" describes |
| Open question | 1 | Q1, below |
| **Claim** for Phase 2 | 2 | C1 and C2, below |

### Claim C1: the recall's re-attach races a launched detach run

`_retain_recall`'s re-attach branch returns the `pgpm_detach` job to idle, attaches the partition back and
clears the mark in one transaction, with no check for a run of the command already in flight. The attached
branch has that check (`pg_locks` and `pg_stat_activity`). So a run pg_cron launched before the idle, queued
behind the attach's lock on the parent, detaches the partition again with nothing vouching for it. The
partition's rows leave the parent and no retirement owns them.

The counterexample (`CustodyFK-asis.cfg`, 8 states): retire dispatches the detach; pg_cron launches a run; the
operator detaches the partition by hand (it stays pgpm's retirement, per `reference.md` `retire`); `set_retain`
loosens; the recall re-attaches it; the launched run detaches it again. NoLostRow and ResolveByRecord both
fail. Hypothesis H_C1 assumes the re-attach waits as the attached branch does.

### Claim C2: a tracked rename turns recorded chunks into orphans, and retire drops rows nothing vouches for

The archive step's orphan rule discards the coverage "an untracked name holds over a tracked partition's range"
by **name**. After a rename that carries `pgpm.part` with the table (the old guide's recipe), the partition's
own recorded chunks carry the old name and become orphans, even though their `child_oid` is the tracked
partition's. If the operator script has meanwhile archived the rest under the new name, the discard leaves a
gap below a `max(hi)` that still reads as fully covered, and `retire()` drops rows that only an unrecorded
object holds.

The counterexample (`Custody-asisC2.cfg`, 9 states): the step archives [0,1); a retire begins and, during its
lock wait, the operator renames the partition with its `pgpm.part` row; the operator script archives [1,2)
under the new name; the next archive step discards [0,1) as an orphan; retire drops. The rows of [0,1) are in
object 0, which no ledger row records any more, so nothing attests it as the only copy and the recorded-chunk
check cannot protect it. #1335 bullet 4 was struck on the premise that a missing middle chunk needs a hand edit
of the ledger; this path needs none. Hypothesis H_C2 assumes the orphan rule spares a chunk whose `child_oid`
is tracked.

C2 appeared as a full counterexample only once DropOnlyCovered was stated as the pack states it (rows in objects
attributed to the dropped relation's identity), on the fidelity read's advice. Under the looser "rows in some
object" the same path checked clean.

### Open question Q1 (for the maintainer, not a claim)

A partition pgpm's detach took out of the parent, whose retirement retention then stops reaching, is re-attached
by the recall. If the operator renames that detached table first, the recall, which resolves by name, never finds
it, and the rows stay out of the parent for good (they are not lost: the renamed table holds them). The contract
says what the recall does but not what a hand rename of a retirement in custody means. Either it makes the
table the operator's, and the docs should say so, or the recall should resolve by its recorded oid.
`CustodyLive.cfg` and M778 leave renames out until this is decided.

## Independent fidelity read

A second agent read the spec against the contracts, never the code, and did not see the triage. It reported
33 items: 6 high, 14 medium, 13 low.

| High item | Disposition |
| --- | --- |
| H1 the archive step was one atomic step, so a concurrent detach could not overtake the strategy's read, and the documented re-check after the strategy returns had no guard and no mutation | **Fixed**: the step is two steps (C9), the re-check is tagged `G1259r4`, mutation `M1259r4` |
| H2 DropOnlyCovered accepted rows found in any object | **Fixed**: only rows a live chunk of the dropped relation records, in the object it names (`Vouched`); this is what surfaced C2 |
| H3 the custody exemption in NoLostRow had nothing checking it | **Fixed**: `CustodyLive.cfg` checks `NoLostRowLive` in the track |
| H4 the run's dispatch record was chosen by `CHOOSE`, which could call a C1 landing a substitute | **Fixed**: the job carries the relation whose dispatch armed it |
| H5 Init lacks a null `child_oid` row and a mark at upgrade time | **Open**: known gap K1 |
| H6 no schema rename in the environment | **Open**: known gap K2 |

Of the mediums, M7 (ArchiveNoClobber over any object), M11 (the script's strategy) and M12 (the NoWedge conjunct
too strong) were fixed, and M9 and M10 explained misses M453 and M454w. The rest are the known gaps K3 to K8 in
the spec's header, stated so that a clean check is not read as covering them. The full report is not kept in
the repository; its high items are above and every open item is a K entry.

## A vacuous pass, caught

While H_C2 was being added, a parenthesisation slip in the orphan rule made every recorded chunk an orphan on
the next tick. The archive never completed a partition, so no drop with archiving on was reachable, and every
config checked clean, the default one at 2.2M states. It showed up only because six drop-dependent mutations
missed at once. This is the repository's oldest lesson (CLAUDE.md, "Assertions that pass for the wrong
reason") in a model. The track now runs liveness witnesses first: a second chunk of one partition, a drop of
archived rows on each path, a dispatched detach, a read a detach overtook, and rows in custody must all be
reachable. A mutation that kills the archive must make the progress witnesses unreachable, so the witness check
is itself shown to discriminate.

## Not done in Phase 1

- **The 24 custody per-PR verification rounds** (the catalogue's second, reported set) were not retrodicted.
- **The nightly config** (EnvBudget 3) was not added: the default scope is 2 environment steps, and the five mutations that need 3 carry their own budget in their
config. A full EnvBudget 3 run of the default configs was not attempted within the budget; it is the obvious
next scope to buy when a mutation or a claim needs it.
- **Symmetry sets** are not used: the oids, rows and names are not interchangeable in this model (the shapes pin
  particular ones), so a symmetry reduction would be unsound without restructuring Init.
- **Privileges** (Base A8) and **snapshots** (K3) are out, as stated.

## Cost

| Measure | Phase 1 |
| --- | --- |
| Tokens | about 1.2M of the 3.2M budget (ceiling 4.5M): 0.85M in the main thread, 0.35M in the blind re-classification and fidelity agents |
| TLC CPU, one full `./test.sh formal` | 31,236 s (8.7 CPU-hours: user 30,808 s, sys 428 s), 39 minutes wall on 16 cores, 4.5 GB peak resident |
| Of which the liveness config | 28 minutes wall; the rest of the track, every mutation included, is about 11 |

On a 4-core runner the track should take two to three hours, which is why its workflow runs on a PR touching the
model and not on every merge group.
