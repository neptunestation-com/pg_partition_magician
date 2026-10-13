# F1 null results and hypotheses (pass 12, slice S1)

Claims: F1-01 (T1, untransmute never asks `_refuse_detach_pending`), F1-02 (T3, `restore_incoming_fks`
never reads the park it writes), F1-03 (T4, reference.md's untransmute remedy omits FINALIZE), F1-04 (T3,
outside my slice but reached from transmute's cutover: obtain and extend_to never call `_log_unbuilt_cell`).
Every claim was run on `pgpm_test-15` against the review tree before writing it up.

## fresh surface

- #1157 (`_refuse_detach_pending`): grepped every caller in all three install files and uninstall.sql;
  it is called nowhere, though untransmute's comment (install.sql:12243) and the CHANGELOG say it is asked
  before the gate and again under the lock. Reproduced the issue's own scenario: rows lost (F1-01).
- #633 (one-step re-add parked): the park is written (14884) but neither the loop query (14839-14842) nor
  maintain's call site reads `validate_retry_after`; reference.md, the dropped_fk table doc and runbook
  step 1 all promise the five-minute park (F1-02).
- #1167 / #1135 (forward names under the cutover's lock): read the post-obtain re-ask and the 23505 /
  42P07 / 42710 handler around `obtain`. obtain itself has no handler, so a holder still open at
  lock_timeout surfaces raw as 55P03 and rolls the cutover back to the resumable state (documented
  "raised as it came"). Held.
- #1166 (`_transmute_reap` re-read): walked the interleavings (take-over row lock before / after the
  reaper's table lock; the reaper deleting first and the take-over's ON CONFLICT re-inserting fresh).
  All end with a live conversion intact or a fresh one. Held.
- `_fk_def_unvalidated` (#633, PG18): only reachable on PostgreSQL 18; the harness is 15. Not exercised.
- Systematic check: listed every function defined in the core with no call site. Found
  `_refuse_detach_pending` (F1-01) and `_log_unbuilt_cell` (F1-04); the others (`set_obtain`,
  `untransmute`... public entry points) are expected. Grepped for bare `null;` branches: two in obtain and
  extend_to are the F1-04 sites, the rest are deliberate swallow/rollback arms.
- CHANGELOG.md Unreleased carries hand-merge artefacts: the #1157 entry appears twice verbatim, and the
  #633 entry ends with a stray duplicated sentence (`docs/guide.md` now say so. Test `tests/322`.). Not
  operator-facing; not claimed.

## time and zones

- transmute in `America/New_York` with a date key and `p_anchor => '2024-01-01'`: refused (05:00 UTC), the
  message prints the session zone. timestamptz(0) with `'500 milliseconds'`: refused before commit.
- Bounds written by `_transmute` (claim lo/hi, CHECK, ATTACH, config, part) all go through `_ts_text` /
  `_encode` with the claim's zone; a resume adopts `partition_tz` from the claim and recomputes the
  monolith name in it. ISO text from `_ts_text` parses identically under any DateStyle. Held.
- The minimum of a timestamptz key is read through `_ts_text` (#788); the maximum through `max()` into a
  timestamptz variable, no text round trip. Held.

## boundary arithmetic and types

- `_identity_reseed` (numeric/bigint division, negative increments, exhausted bound), `_seq_next`,
  `_array_type_name` and `_is_clone_pkey_name` (63-byte clipping) read against PostgreSQL's naming rules.
- `_id_step_contract` / `_control_bound_contract`: domains unwrapped, typmod -1 skipped, NaN/Infinity
  refused. `_transmute_refuse_child_holders`: `length`/`substr` are both character-based, so the label cut
  is right for multibyte names.
- An INVALID secondary index (failed CREATE INDEX CONCURRENTLY) is carried as an invalid partitioned
  index; transmute and untransmute both complete. Held.

## operator error

- transmute over a converted table refused; transmute_abort with no claim returns false; step
  `'1 day -1 hour'` accepted and behaves as a consistent 23-hour lattice; `'1 month 1 day'` refused by
  `_grid_floor` before anything commits; `_retain_nonnegative` refuses `'-1 year 360 days'`,
  `'1 month -1 day'`, `'1 day -1 hour'`. A negative `p_bound_headroom` is silently read as 0 (harmless).
- Typed each remedy the S1 refusals name: `_refuse_detach_pending`'s message names FINALIZE correctly, but
  the reference's copy of it does not (F1-03, the documented statement fails with PostgreSQL's
  "unfinished detach" error and leaves the partition pending).

## failure injection

- Killed a DETACH ... CONCURRENTLY in its wait phase (the F1-01 / F1-03 fixture): the pending state is
  reached and the reference's remedy fails; untransmute destroys the rows.
- `restore_incoming_fks` with an orphan on a partitioned referencer (PG15): fails, parks, then retries on
  the next unscoped call anyway (F1-02).

## contracts versus documentation

- reference.md `transmute_abort`, `untransmute`, incoming-key entries and dropped_fk / transmute_inflight
  catalog entries read against the code: the untransmute pending-detach paragraph (code missing, F1-01;
  remedy wrong, F1-03) and the restore park (F1-02) are the breaks found; the rest held.

## Hypotheses (not reproduced)

1. `restore_incoming_fks` (14882-14885) parks a one-step re-add for five minutes on ANY error, a
   `lock_not_available` from maintain's 3 s lock_timeout included, and logs "retried in 5 minutes". Once
   F1-02 is fixed (the park read), a transient lock conflict would keep a key's RI off for five minutes
   for no scan's sake. Build: hold SHARE on the referencing table in a second
   session across a `restore_incoming_fks` call on PG15 with a partitioned referencer, then check
   `validate_retry_after`.
2. `_transmute_refuse_child_holders` (9564) matches by `_is_fine_child_label` of the KIND, not of the
   grid's step: an operator's standalone table `sales_p2023` (a yearly label) blocks the transmute of
   `sales` on a monthly grid, whose children can never take that name, and the message calls it "an
   orphan left by an interrupted regrain. Drop it (drop table ...)". The same refusal meets the partition
   F1-01's remedy leaves standing (`untransmute` "leaves the detached partition standing as a table of
   yours") on the next transmute, with advice to drop a table that holds the operator's rows.
3. A naive `timestamp` key written as local wall time east of UTC (Asia/Tokyo, +9) on an hourly grid:
   `_frontier_skew_limit` (now() + 1 step + 1 h, read on the UTC clock) refuses the transmute as a "client
   with a wrong clock" unless `p_force_frontier`, while reference.md's naive-column paragraph says such a
   table runs on an hourly grid with `obtain` above the offset. Build: a `timestamp` column holding
   `now() at time zone 'Asia/Tokyo'` rows, transmute with interval '1 hour'.
4. A resume with a different text_time shape (prefix, epoch, radix) than the attempt that recorded the
   claim: neither the claim nor the resume checks (#628 checks the column, #574 the grid), so phase 1 skips
   the existing CHECK (old encoding) and the cutover's ATTACH cannot use it: a scan under ACCESS EXCLUSIVE,
   or a raw failure when the encodings disagree on a row. Build: interrupt a text_time transmute after
   phase 1 (lock_timeout in phase 2), re-run with another `p_tt_epoch`.
5. `p_obtain => 0` on an `id` grid: the frontier is max(id) inside the monolith, obtain's only candidate
   overlaps it, so nothing is ever built and every write at or past `hi` is refused for good (only
   `extend_to` helps). Allowed by `set_obtain`'s rule; whether the reference's "no lookahead beyond the
   partition the frontier is already in" warns of it enough is a documentation question.
6. The handoff and the time overload store `p_retain::text` / `p_interval::text` in the calling session's
   IntervalStyle (sql_standard, iso_8601, postgres_verbose); every reader casts back to interval, which
   parses each style, but any reader that compares `partition_step` as text would see another spelling.
   Not traced outside the slice.

## Round 2

Built (each run on pgpm_test-15 against the review tree, each fails there with its LIVENESS premises passing):

- Hypothesis 2 -> F1-05 (T4, operator error): the orphan-child guard's kind-wide label match refuses `sales`
  on a monthly grid for the operator's own `sales_p2023` and prescribes `drop table` of it. Long-surviving
  shape (6), a derived name judged held.
- Hypothesis 4 -> F1-06 (T3, operator error): a text_time resume under another `p_tt_epoch` takes the claim
  over, skips phase 1 on the old-encoding CHECK and dies raw in the cutover's ATTACH (partition constraint
  violated, after a scan under ACCESS EXCLUSIVE). Long-surviving shape (2), the claim and CHECK read before
  and trusted after. The first attempt's half-state is made deterministically: phase 1 queued behind a
  reader, a SHARE UPDATE EXCLUSIVE holder queued behind phase 1, phase 2 timing out on it.
- Hypothesis 3 -> F1-07 (T4, time and zones): an Asia/Tokyo wall-time `timestamp` table on an hourly grid
  with obtain 12 is refused by the frontier-skew check, against reference.md's naive-column paragraph.

Not built:

- Hypothesis 1 (a lock timeout parks a one-step re-add): unreproducible on this tree, since the park is
  never read (F1-02); it only bites once F1-02 is fixed.
- Hypothesis 5 (`p_obtain => 0` on an id grid): allowed by the documented set_obtain rule; a documentation
  judgement, not attempted.
- Hypothesis 6 (IntervalStyle spellings of stored steps): no reader that compares the text was traced;
  not attempted.
