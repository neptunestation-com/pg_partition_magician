# P1 null results: PR #1294 (fix(regrain): copy the rows a NOT VALID CHECK tolerates, #1261)

Harness: pgpm_prv-15 (PostgreSQL 15), fresh database per run, the review tree's pgpm_core/install.sql.
Every unit in units.txt was read before anything was built (see coverage.md).

## Lens: fresh surface

- `_regrain_copy_make` (6546-6584): READ the whole body. The diff's hunk at 6554-6561 is comment only; the
  function holds no statement after the LIKE that drops a NOT VALID CHECK (or a NOT VALID NOT NULL) from the copy.
  The only loop is the #348 one over validated outgoing keys. This is the root cause of both claims (P1-01,
  P1-02) and I did not probe further around it.
- `_regrain_shape_drift` (6653-6706): parent-side exclusion of a NOT VALID enforced CHECK and of a column's NOT
  NULL when it comes from a NOT VALID NOT NULL constraint; copy side not excused. Read with the regrain_step
  restart branch (8117-8170): a copy holding the CHECK under any validity reads as drift, the probe copy decides
  restart vs refusal. On a tree where the copy is made without the CHECK this is self-consistent (the probe
  matches, a restart cures it, the new copies lack it, no second restart). HELD by reading; not probed
  separately because the copy-make defect makes every such probe fail for the P1-01 reason.
- Swap pre-ATTACH add (8565-8582): read against the #633 key loop it is modelled on. `regexp_replace(..., ' NOT
  VALID$', '')` on `pg_get_constraintdef` of a CHECK yields `CHECK ((expr))`; the `conenforced` read through
  `to_jsonb` is null before 18 and so passes; the NOT NULL branch matches by column name through the parent's
  attnum. The "copy already holds it by name keeps it" clause is unreachable on a correct tree (the drift check
  restarts such a run first, in the same tick before the swap), and harmless. HELD by reading; the add itself is
  unreachable on this tree (no copy ever survives the copy phase or the drift check with the CHECK present).
- `_regrain_fresh_copy_drift` (6596-6611): makes the probe through `_regrain_copy_make` with an empty tablespace
  clause, compares with the same drift routine, drops it in the tick's transaction. Probed in P1-01: the probe
  holds the CHECK on this tree and turns the restart into a refusal.
- `pgpm.regrain` (8671-8722) and `pgpm.maintain` (13312-13515): both reach the defect only through
  `regrain_step`; regrain() surfaces it as a raise (both repros), maintain as skip_regrain (read, not run; the
  handler at 13470-13475 logs `left(sqlerrm, 200)` and defers, with capture and the TRUNCATE guard left on).
- Race considered and dismissed (not a claim): a `VALIDATE CONSTRAINT` committed between the drift check and the
  swap inside one maintain tick would make the ATTACH fail 'child table is missing constraint' once; the next
  tick restarts. Transient and self-healing. Under regrain() the SHARE lock on the parent excludes it.
- Documented-restart case (not a claim): a copy holding the CHECK validated after the parent's was dropped and
  re-added NOT VALID with no violating row now restarts where the base did not; the body, CHANGELOG and
  reference.md:2086-2088 all say so, so it is a documented contract, not a regression.

## Lens: upgrade and install paths

- All three touched routines are `create or replace` with unchanged signatures; re-running install.sql replaces
  them with nothing to drop. HELD by reading.
- In-flight run across the upgrade whose copies hold the CHECK validated: reads as drift (copy side), probe
  decides. On a correct tree: restart once, as the body says. On this tree: the probe holds it, so the run is
  REFUSED on every tick rather than restarted (the same mechanism as P1-01; P1-01's fixture reaches that exact
  state from a fresh run, so no separate claim).
- In-flight run across the upgrade whose copies LACK the CHECK (added mid-run before the upgrade, copies
  predate it): on the base the drift check restarted it (parent CHECK missing from the copies); on this tree the
  parent side is excluded, no drift, the copy phase continues and new copies get the CHECK validated by LIKE, so a
  violating row in an uncopied sub-range fails 23514 (P1-02's mechanism). Not a separate claim.
- reference.md:215: transmute refuses a NOT VALID CHECK on the monolith, so the state only arises after
  conversion; consistent with the fixtures (ALTER after transmute).
- tests/331 (read whole): parts A, B, C, D each pair LIVENESS with identity assertions over named rows and the fine
  child serving each; no count = count; throws_ok pinned to SQLSTATE. On this tree parts A, B, C fail at their
  first lives_ok (the same 23514 as P1-02), so the file does discriminate the tree's state. Part D skips before 18.
- bench/regrain_not_valid_check.sh (read whole): install failure reported as FAIL, pg_prove rc decides, 0 ran
  reported as a LIVENESS failure. No wrong-reason pass found.
- test.sh: one guard entry added to the perf shard list at 1268; the shard loop selects by index, so the entry is
  run. HELD.
- CHANGELOG.md, docs/reference.md 2079-2090: describe the intended mechanism; consistent with the code at the swap
  and the drift check, and NOT with `_regrain_copy_make` as it stands (claims P1-01/P1-02 cover that).

## Hypotheses (no reproduction)

- PostgreSQL 18 only (no 18 harness given): `pg_get_constraintdef` of a NOT VALID NOT NULL constraint must end in
  ` NOT VALID` for the swap's regexp to strip it; if 18 renders it otherwise the add would fail. The body says
  verified on 18; unverified here.
- `pgpm_hypertable.from_hypertable_copy` has its own `LIKE ... INCLUDING CONSTRAINTS` (the body says so and calls
  it not covered); outside this slice and the timescale harness was not available to me. A NOT VALID CHECK on a
  hypertable with a violating row would fail its copy the same way.
- A CHECK added NOT VALID directly on the SOURCE child (not the parent) is dropped with the source at the swap and
  never carried to the fine children; pre-existing, arguably by design (the drift check compares parent only).
- On 18 a `NOT ENFORCED` CHECK is left on the copy by LIKE and compared on both sides; if LIKE copies it as
  enforced, the copy would refuse rows the parent accepts. Not checkable on 15.
