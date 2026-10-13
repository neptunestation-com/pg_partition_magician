# F3 null results (pass 12, slice S3: regrain and the scratch relations)

Claims: F3-01 (T3, fresh surface: the prepare-tick lock budget ignores archive_fn), F3-02 (T1, operator error:
regrain() from a REPEATABLE READ transaction drops a row), F3-03 (T2, fresh surface: a NOT VALID parent CHECK
wedges every copy batch).

## fresh surface

- #1161 lock budget: read `_regrain_fine_count`, `_regrain_swap_budget`, set_regrain's warn loop and the swap's
  measured budget. Ran the prepare tick on a 2500-child id run with retain null (refused, as documented), with
  retain + no archive_fn (admitted, correct) and with retain + archive_fn (admitted: F3-01). The measured
  budget's arithmetic (v_made counter starts at 0 on the swap path, v_per floor of 2, incoming keys charged
  2 + 2k) matches the reference text. Held apart from F3-01.
- #1241 snapshot wait: read `_snapshot_wait` and `_regrain_snapshot_wait` line by line against the reference
  section. Checked: `age(backend_xmin) >= age(limit)` is "xmin at or before the reference"; own-xid rule when
  written is null or this transaction's; every write into the fine children outside the swap's own
  transaction updates `regrain_written_xid` (copy batch with rows, reconcile batch that consumed rows); a
  cancelled or failed tick rolls the xid update back with its writes; `_scratch_record` resets the hypertable
  copy's xid. regrain_cancel and the swap leave a stale `regrain_written_xid`, but the next run's first
  writing batch replaces it and a run that writes nothing has nothing for an old snapshot to miss. Held.
- #633 copy shape: `_regrain_copy_make` / `_regrain_fresh_copy_drift`. Probe is created and dropped in the
  tick's transaction (a cancel leaves no probe); its name is cut by characters (no mid-character cut);
  name-taken returns null as documented. NOT VALID FKs are left off the copy, but NOT VALID CHECKs are made
  valid by LIKE: F3-03.
- #1165 `_same_step`: '1 mon'/'1 month', '24 hours'/'1 day', '050'/'50' same; '30 days'/'1 month' differ; a
  spelling change of the in-flight target is harmless because copies are found by bounds (#585), not name.
- #1117 `_regrain_step_shape` registered grid, `_reconvert_remedy`: remedy names `pgpm.untransmute('<regclass
  text>')`, a function taking regclass, and the reconversion; held.

## time and zones

- Every bound regrain_step writes (sub_lo/sub_hi/cursor) comes from `_grid_floor`/`_grid_next` (rendered by
  `_ts_text`) or is a pgpm.part bound copied verbatim, so a session whose TimeZone/DateStyle differs from the
  tick's writes the same instants; `_native_below` and `_regrain_fine_count` walk with the same helpers and
  partition_tz as the copy. Held by reading.
- `_naive_grid_zone_off` flags a zone whose offset at the 1st of each month varies from 2000's; a constant
  non-zero offset (Asia/Tokyo, Asia/Kolkata, America/Phoenix) is not flagged. Reasoned that a constant
  offset keeps a fixed lattice on whole wall units in that zone, so this leniency is correct; the reference's
  wording ("a zone whose offset is always zero ... is UTC here") is narrower than the code but changes nothing
  an operator types.

## boundary arithmetic and types

- `2 * v_n > v_slots / 2` at the line (n = slots/4 is admitted, slots/4 + 1 refused; the cap counts to
  slots/4 + 1 so the answer is exact at the line). Held.
- id steps 'NaN' and 'Infinity' pass `_regrain_step_forward` (NaN sorts above every number) and
  `_regrain_step_shape` (trunc(NaN) = NaN), but regrain_step answers `nosubdiv` and set_regrain refuses them
  as coarser than partition_step, so no wedge. Held (refused, with an odd message).
- `_regrain_capture_derive` octet_length fit; `_regrain_shape_drift` `_ck` name cast truncates exactly as the
  CHECK's own identifier did. Held.

## operator error

- regrain_cancel of nothing (returns 0, logs a row), of an unmanaged table (refused), set_regrain twice with
  the same target in another spelling (accepted), set_regrain(null) mid-run (cancels through regrain_cancel).
  Held.
- regrain() inside a REPEATABLE READ transaction: F3-02. transmute, untransmute, from_hypertable and the cutover
  refuse a stricter isolation (`_refuse_strict_isolation`); regrain, regrain_history and regrain_step do not.
- Hand edit of regrain_cursor: reference.md's Catalog says the tables are read-mostly and to use the functions,
  so not pursued as a defect (a cursor moved past a half-copied sub-range would let the swap attach it short).

## failure injection

- Cancel/timeout inside the snapshot wait, between DETACH and ATTACHes, inside regrain_cancel: all inside one
  transaction, rolled back whole; the advisory marker is transaction-scoped. A cancelled
  `_regrain_fresh_copy_drift` leaves no probe. A copy batch that fails (F3-03's 23514) rolls back and leaves
  the run prepared, capture on: that is the wedge F3-03 reports.
- `_scratch_owner_follow`'s handlers catch only insufficient_privilege; `_enforce_regrain_capture`'s `when
  others` per child logs skip_regrain_capture with sqlerrm and moves on (documented isolation). Held.

## contracts versus documentation

- reference.md regrain_step's lock-budget paragraph: "With archive_fn unset it counts only the sub-ranges above
  the retention horizon" is the contract F3-01's code breaks (set_regrain's warning inherits the same count).
- reference.md hand-over entry, regrain_cancel entry, set_regrain spelling rules: run/read as written; held.
- The pgpm.config catalog table in reference.md lists no `regrain_written_xid` row (the column is described in
  the regrain_step text); not an operator-typed statement, so not claimed.

## Hypotheses (not reproduced)

- H1 (sibling of F3-02, maintain/regrain_step path): `regrain_step`'s swap under REPEATABLE READ (a session or
  database `default_transaction_isolation = 'repeatable read'`, which pg_cron's maintain inherits) reads the
  delta through the tick's statement-start snapshot. A writer holding ROW EXCLUSIVE on the source when the swap
  tick starts makes the DETACH (install.sql ~8480) wait; it commits, its capture rows land in the delta, and
  the residual `_regrain_reconcile` loop and the final `_regrain_delta_count(p_parent, lo, hi)` (8510) cannot
  see them, so the source is dropped with the committed UPDATE reverted (or INSERT lost, DELETE resurrected).
  Build: two sessions, W `begin; update ... where id in source; pg_sleep(3); commit`, S (RR, no lock_timeout)
  the swap tick of a hand regrain_step; assert W's payload after. Same fix as F3-02 if put in regrain_step.
- H2: `transmute` may carry a NOT VALID CHECK of the original table onto the new parent NOT VALID; if so,
  F3-03 is reached by any table converted with such a constraint, not only by one altered afterwards (not
  checked: transmute is another slice's).
- H3: `_snapshot_wait` truncates `regrain_written_xid` (xid8) to xid; a run idle more than 2^31 transactions
  makes `age(v_limit)` negative and the wait list every session with a snapshot (over-wait, never under-wait).
  Not reproducible in budget.
- H4: `_regrain_capture_names` resolves the capture function only in the delta's CURRENT schema; after an
  operator moves the delta (SET SCHEMA, which the reference says capture tolerates), `fn` is null, and
  untransmute (install.sql 12697) and uninstall.sql leave the capture function behind. Residue only.
- H5: regrain_history's reference text says "the oldest coarse child"; the code takes the smallest-lo attached
  partition (as the parenthetical says), so after a hierarchical first pass a second regrain_history refuses
  'nosubdiv' on a fine child while coarse ones remain. Wording, not pursued.

## Round 2

- Built H1 as **F3-04** (Tier 1, operator error; shape 4, sibling of F3-02): a two-session `repro.sh`. A writer
  holds row 10 of the source across the start of a hand `regrain_step` swap tick run in REPEATABLE READ; the
  DETACH waits, the writer commits, and the swap drops the source with the update unapplied (10=orig, want
  10=updated). The same script under READ COMMITTED keeps the update.
- Built H4 as **F3-05** (Tier 3, operator error): after a cancelled regrain and the delta moved by SET SCHEMA,
  untransmute drops the delta and leaves `public.h4_pgpm_regrain_capture()`. Without the move both go.
- Tried H2 and disproved it: transmute refuses a table with a NOT VALID constraint up front ("the cutover
  cannot carry a NOT VALID constraint"), so F3-03 is reached only by a NOT VALID CHECK added to the parent
  after conversion, as its reproduction does.
- Not attempted: H3 (needs 2^31 transactions, and only over-waits) and H5 (a wording point; the reference's own
  parenthetical matches the code).
