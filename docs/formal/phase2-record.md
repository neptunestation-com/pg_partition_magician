# Formal methods: Phase 2 record (reproductions)

Phase 2 of the program in `docs/pgpm-formal-methods-context-pack.md`, run on 2026-11-04 against main `032a17a`.
Phase 1 (`docs/formal/record.md`) left nine things the model asserts that only PostgreSQL can settle: two claims
from counterexamples of the unmutated spec (C1, C2) and seven masks, where the model says a later guard covers
an earlier guard's hole. Phase 2 reproduced each one in PostgreSQL, judged it, and filed what it found.

## Method

- **Not by the spec's author.** Five fresh agents wrote the reproductions from a shared brief and the Phase 1
  record, one per claim or group of masks. A separate verifier re-ran each result and tried to break it. The
  author of the spec only coordinated.
- **Real dependencies.** Every reproduction ran in a private container (`pgpm_test:17-archive`) with real
  pg_cron, and those that touch the archive ran against MinIO. A shell harness drove more than one session, which
  pgTAP cannot.
- **A mask is judged both ways.** The mutant that puts the original guard back must leave the defect
  unreachable. A positive control that also removes the later guard must reach it. A mask holds only if both do.
- **Findings are filed** under the lens `formal`, with tier and age, and the PR that fixes one goes through the
  same per-PR verification as any other.

## Headline

| Item | Phase 1 said | Phase 2 found | Filed |
| --- | --- | --- | --- |
| C1 | the recall's re-attach races a launched detach run | **confirmed, Tier 1**, with real pg_cron and with no operator involved | #1438 |
| C2 | a tracked rename makes recorded chunks orphans, and retire drops rows nothing vouches for | **not reproduced: a model defect**; two smaller rename problems found on the way | #1440 |
| M452 | #564's tick-time check covers the lifted block | **mask broken** on the tick path | none: main keeps the original guard |
| M454w | #975 turns the wedge into a skip | **mask broken**: the skip is a permanent stall that `status()` does not show | #1439 |
| M502 | #975's recorded-chunk check covers non-injective keys | mask holds | none |
| M977 | #1336 b8 covers offset-less bounds in another zone | mask holds | none |
| M1159 | the step's zero-row check covers the script's parent read | mask holds, but by a different guard than the model names | none |
| M1259 | later guards cover an unvouched mark | mask holds, but by a different guard than the model names | none |
| M1363 | #975 covers a retired chunk's narrow read | **mask broken** for a custom `archive_fn` | none: main keeps the original guard |

One of the two claims and three of the seven masks were wrong in the model's favour: the model said something was
safe that is not. A broken mask is not a live defect while main keeps the original guard. It means the defence in
depth the model counted is not there, so removing the original guard would ship the defect. Only M454w has a live
consequence, because an older install can already hold the row the original guard now prevents. Counting C2 as the model's error too, Phase 1's untested assertions were right **5 of 9** times (C1 and the four masks that hold).
The four that held all hold for a reason the model can state; two of those hold for a reason it does not
currently state.

## The claims

### C1: confirmed, Tier 1 (#1438)

`_retain_recall`'s re-attach branch returned the `pgpm_detach` job to idle, re-attached the partition and cleared
its mark in one transaction. pg_cron reads a job's command from a cache that only a commit refreshes, so a run it
launched before that commit, or even after the uncommitted idle, still carried the armed
`DETACH ... CONCURRENTLY`. Queued on the parent behind the `ATTACH`, it detached the partition again. The row
then read as attached with no mark, the rows went unserved, and `status()` counted nothing.

The verifier widened the window beyond what the model drew. The model needed an operator's hand detach. In
PostgreSQL no operator is needed: pgpm's own run detaches, `set_retain` loosens, and the tick's re-attach races
the next cadence's run. Nothing later notices: neither `_detach_reap`, nor `maintain_all`, nor a re-run of
`install.sql`.

The fix, PR #1441, is **parked after four verification rounds** (see below).

### C2: not reproduced, a model defect

The reproducer drove C2's shape against main: a tracked rename during a retire's lock wait, the operator script
archiving under the new name, and the next archive step. It did not lose rows. Main is safe because every
producer of a ledger row resumes from the current `(name, oid)` coverage, and `_refuse_recorded_chunk_overwrite`
refuses to write over a recorded chunk. So the orphan rule never discards coverage that a row still needs. The
model let the operator script write chunks without that resume, which the script does not do. A mutant tree
that removes the resume loses ids 1 to 32 into an unrecorded object, so the check discriminates. The reproducer
and its verifier found two smaller problems with the operator guide's rename recipes while trying to break it,
filed as #1440 (Tier 2): a name swap that leaves the ledger behind wedges archiving, and the in-flight rename
recipe leaves the ledger out. Neither loses rows.

## The masks

### Broken: M452, M454w, M1363

- **M452.** #564's check runs inside `retire`. On the tick path `_enforce_write_blocks` re-blocks
  the partition before `retire` runs that check. With the block lifted and coverage kept, a row written into the
  window is lost. Called directly, `retire` holds the line; through the tick it does not.
- **M454w, #1439 (Tier 2).** A `(lo, lo)` ledger row (a pre-#454 install, or an archive function returning
  `covered_hi = lo`) is refused by #975 as a recorded chunk on every tick. Even after `set_archive_fn` is
  corrected, the step logs `skip_archive` four times and retires nothing. `retain_drop_failures` stays 0 and
  `retain_backlog` stays flat. The model said this mask was the weakest: it turns a wedge into a stall, and no
  invariant names the stall. In PostgreSQL the stall is permanent and invisible to `status()`.
- **M1363.** #975's recorded-chunk check lives only in `pgpm_archive`'s encoders. A custom `archive_fn` keyed
  by `lo` relies on the core's hold alone. With the narrow read of a retired chunk's bounds put back, it writes
  over two existing objects (`PUT`s that land) and only then fails on the ledger's primary key.

### Holding: M502, M977, M1159, M1259

- **M502** and **M977** hold for the guard the model names. In each, the double mutant (the later guard removed
  as well) reaches the harm.
- **M1159** and **M1259** hold, but the guard that stops them first is `_archive_hold_partition`, not the
  zero-row check or the step guard the model names. This is the fidelity gap the Phase 1 read flagged at #1335
  bullet 3 (`CandAtt`): the model abstracts the hold away, so it credits the next guard in line. Both positive
  controls reach the harm.

## Corrections to the model

1. **Masks M452, M454w and M1363 were over-claimed.**
   - M452: the model checks `retire`'s guard in isolation, and the tick reorders it after the write-block step.
   - M454w: a stall no invariant names was counted as a mask.
   - M1363: the recorded-chunk check was modelled as the core's, but it belongs to one archive function.
2. **C2 is a model defect.** The operator script was modelled without its resume from current coverage.
3. **`CandAtt` (#1335 b3) should model `_archive_hold_partition`.** Its absence credited M1159 and M1259 to
   later guards.
4. **C1's precondition was too strong.** The model needed an operator's detach; pgpm's own run suffices.

Each of these is a change to the spec for a Phase 3, not made here.

## The C1 fix: four verification rounds, parked

PR #1441 went through four rounds of per-PR verification. Each closed what the last found and opened something
else. That is the clearest result of Phase 2: the model's claim was right, and the obvious fix is not.

| Round | Head | What it did | What verification found |
| --- | --- | --- | --- |
| 1 | `091ddf3` | the re-attach keeps the mark; a later tick clears it | the attached branch clears in the idling transaction (T1); the kept mark holds the one-detach slot (T2 regression, twice) |
| 2 | `13cb136` | a transaction-local flag; the slot follows the armed job | the mark is still cleared too early by background-worker pg_cron, a `schedule()` re-run, and a caller that cannot read the job (T1, four ways) |
| 3 | `5e69d11` | never clear a recalled mark (`recalled_at`); refuse a caller that cannot see the job | `BYPASSRLS` sees the job but cannot change it (T1); a role that unscheduled its own job is refused for good (T2 regression) |
| 4 | `715aef4` | record the dispatcher; refuse unless superuser, job owner or dispatcher | an owner without `EXECUTE` on `cron.alter_job` (T1); a mark kept for good makes a later hand detach look like pgpm's own, and `retire` drops it (T1 regression); a job transferred after dispatch (T2) |

Two of the designs were the maintainer's choice by form, after round 2 and round 3. Each round's acceptance
set carried every earlier round's reproductions, so no round regressed an earlier fix; the regressions were
new.

The fix rests on two judgements pgpm cannot make reliably:

- **Whether the caller can idle the job.** pg_cron's privileges and row policy have defeated each predictive
  test: visibility, `BYPASSRLS`, job ownership and dispatcher. pg_cron revokes `EXECUTE` on `cron.alter_job`
  from `PUBLIC`, and a superuser can transfer a job between roles.
- **How long a recalled mark must be kept.** Clearing it on any reading that the job is idle loses a late
  detach. Keeping it for good mistakes the operator's later hand detach for pgpm's.

The redesign proposed on #1438, for a later session:

- **Verify the idle by its effect** instead of predicting it: attempt the idle without swallowing its error,
  read the command back, and refuse unless the job is confirmed idle or confirmed absent.
- **Bound the kept mark** by evidence from pg_cron: keep it until `cron.job_run_details` shows a run that
  started after the recall's commit, then clear it.

The 15 reproductions from the four rounds are its acceptance set.

## Cost

| Measure | Phase 2 |
| --- | --- |
| Budget | working 2M, ceiling 3M, raised to 3.6M by the maintainer after round 3 |
| Tokens, by estimate | about 3.1M: reproductions and their verification about 1.2M; the C1 fix and its four verification rounds about 1.9M (finder and claims verifier about 0.35M per round) |
| Wall clock | one day |

Most of the spend went on the fix, not the reproductions. A reproduction is bounded by the claim it tests; a fix
for a claim about pg_cron's semantics is bounded only by how many role setups the verifiers can build.
