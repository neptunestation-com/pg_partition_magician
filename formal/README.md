# formal/: TLA+ models of pgpm's protocols

A TLA+ model of pgpm's custody chain (archive, then retain), checked by TLC. The model states the
**intended** design, taken from the documented contracts, and is never derived from the code. It answers
one question: can any interleaving of pgpm's steps with an operator's, an application's or another
session's actions break an invariant pgpm promises? The program behind it is
`docs/pgpm-formal-methods-context-pack.md`, the defect data that chose what to model is
`docs/formal/tier12-catalogue.md`, and what Phase 1 found is `docs/formal/record.md`.

## Layout

| Path | What it is |
| --- | --- |
| `specs/Base.tla` | The shared world: relations with an identity separate from their name, rows, attachment states, session rendering of stored bounds, the non-transactional object store, and the environment's hand actions. Abstractions A1 to A9. |
| `specs/Custody.tla` | The archive-then-retain chain: the write block, the archive step, the ledger, the object store's key claims, `retire()` on both paths, the `pgpm_detach` dispatch, the recall, `_detach_reap`, and `scripts/archive_partition_whole.sql`. Abstractions C1 to C9, hypotheses H_C1 and H_C2, known gaps K1 to K8. |
| `specs/Custody.cfg` | The one-step retire path. Must check clean. |
| `specs/CustodyFK.cfg` | The detach path (a foreign key references the parent). Must check clean. |
| `specs/CustodyLive.cfg` | `NoLostRowLive` under fairness, on the detach path: a retirement retention stops reaching is taken back. Must check clean. |
| `specs/CustodyFK-asis.cfg` | The detach path without hypothesis H_C1. Must be **violated** (NoLostRow): it keeps claim C1 on record. |
| `specs/Custody-asisC2.cfg` | The one-step path without hypothesis H_C2. Must be **violated** (DropOnlyCovered): it keeps claim C2 on record. |
| `mutations/mutate.py` | Retrodiction: puts each historical Tier 1/2 custody defect's mechanism back and requires TLC to catch it. |
| `tlc.sh` | Runs TLC from a pinned jar (by sha256) on a pinned JRE image (by digest). |
| `../scripts/formal/trace_diff.py` | Compacts a TLC counterexample to the actions taken and what each one changed. |

## Running it

```bash
./test.sh formal                                   # the track: clean configs, liveness, the claim configs, retrodiction
formal/tlc.sh formal/specs Custody.tla Custody.cfg # one config, in Docker
FORMAL_LOCAL_JAVA=1 formal/tlc.sh formal/specs Custody.tla Custody.cfg   # the same jar on the host's java
python3 formal/mutations/mutate.py --list          # every mutation, its root causes and its invariant
python3 formal/mutations/mutate.py check M454      # one mutation: the clean run and the mutant run
python3 formal/mutations/mutate.py build M454 DIR  # write the mutant and its config into DIR by hand
scripts/formal/trace_diff.py < tlc-output.txt      # read a counterexample
```

`FORMAL_HEAP` sets the JVM heap (default 4g) and `FORMAL_WORKERS` the TLC worker count (default `auto`).

## Scope

The default configs check every behaviour of this world:

- one managed parent with 2 partitions over 4 grid positions, 3 rows, 4 relation identities, 2 schemas, 3
  relation names, and session zones of -1, 0 and +1 grid positions;
- 2 environment steps per behaviour (an environment step is any action pgpm does not take: an
  application write, an operator's hand detach, a rename, a strategy that misbehaves, and so on), and any
  number of pgpm steps. A statement the environment starts is one step even when it is two transactions,
  so an operator's `DETACH ... CONCURRENTLY` finishes without spending a second;
- nine initial shapes: a fresh install, and the older-install states the catalogue found defects in (an
  origin-only write block, an upgrade pending, offset-less live and retired ledger bounds, an offset-less
  partition bound, a paused parent's mark, a dropped parent, and a gone relation's ledger row).

A small scope is a deliberate choice. Every retrodiction mutation is caught at three environment steps or
fewer, and most at one or two (each mutation's budget is in `mutations/mutate.py`). The scope is still a
bound: a clean check says nothing about a behaviour that needs three operator actions, or three partitions.

## What is not modelled

The spec headers list every abstraction, and a missing one would be a defect in the spec. In short:

- the synchronous exports (`archive.to_s3` and the others), which come in a later phase;
- privileges and row-level security;
- row payloads, which are tokens; a chunk's digest is modelled as the exact row set;
- `archive_batch` above 1, and `retain_batch`;
- regrain, except for its custody effects (a copy relation in flight, and the swap);
- another parent's retirements, except as one mark on a paused parent;
- snapshots: a transaction is one atomic step, except the archive step's strategy call, which is two
  (the call, then the return with its re-check), so a concurrent detach can overtake the read.

## Hypotheses and known gaps

A counterexample from the unmutated spec that reads as a real defect becomes a **claim**. Claims are listed
in `docs/formal/record.md` and reproduced against PostgreSQL in Phase 2, never by the author of the spec. While a
claim stands, the default configs assume the guard that would close it (`Hypotheses = {"H_C1", "H_C2"}`), so the
rest of the design is still checked. Each claim has an as-shipped config that leaves its hypothesis out, and the
track requires it to keep failing.

The spec header also lists **known gaps** (K1 to K8): places where the independent fidelity read found the spec
narrower than the contracts, not yet closed. A clean check says nothing about them.

## Retrodiction: the model's discriminate track

A spec that checks clean proves nothing on its own. It might be clean because the design holds, or because the
model cannot see the defect. So `mutations/mutate.py` takes each of the 37 Tier 1/2 custody root causes in
the catalogue and rewrites the guard that root cause's fix put in. Every such guard sits on a line tagged
`@guard <id>` in `Custody.tla`. The rewrite restores the shape that shipped the defect. Each mutation runs
twice:

1. the unmutated spec under the mutation's config, checking every invariant, must be clean;
2. the mutant under the same config, checking the invariant the defect broke, must be violated.

Each edit names its exact site and refuses to build when the text has drifted, the same rule
`bench/mutations/mutate.py` follows. The invariants and the environment read untagged copies of the design
(`TrueHolds`, `TrueBusy`), so a mutation changes what pgpm does and never what is checked.

Where a later fix put a second guard over the same hole, putting back only the original guard can leave the
model clean. Those mutations are **composite**: they rebuild the design as it stood when the defect shipped.
The single-guard form still runs, and is reported as `MASKED` when the later guard covers it. A mask is itself
a claim about defence in depth.

A mutation that the model misses stays in the table with its expected outcome, so a model change that
starts catching it, or stops, fails the track either way. Every mutation is kept.

## When you change pgpm

If a change touches the custody chain's contracts (`docs/reference.md` sections `retire`, `retain`,
`_detach_reap`, `maintain`, the archive strategy contract, the ledger; `docs/guide.md` "Archiving before a
drop"), update the spec to the new contract first, then run `./test.sh formal`. A new guard goes on its own
line, tagged `@guard <issue>`, with a mutation in `mutations/mutate.py` in the same commit, the rule
`bench/mutations/` already follows.
