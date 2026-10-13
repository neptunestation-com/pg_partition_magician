# F18 null results (slice S1: conversion and reversal)

Claims: F18-01 (T1, fresh surface, untransmute never calls `_refuse_detach_pending`), F18-02 (T4, operator
error, the staging-squatter remedy `drop table` against a sequence or view), F18-03 (T3, contracts versus
documentation, `restore_incoming_fks` writes `validate_retry_after` but never reads it).

## fresh surface

- `_refuse_detach_pending` (new, #1157): read in full; its query and remedy are right (ran the FINALIZE
  remedy in F18-01's fixture: the partition stands alone afterwards). But `grep` over all three install
  files finds no caller: neither of untransmute's two promised sites. Claimed F18-01.
- `_transmute_refuse_child_holders` (new, #1167): asked in the preflight, from the forward CREATE's failure
  and again after obtain. pg_class arm excludes anything in pg_inherits; pg_type arm uses `_type_squatter`
  so a partition's own row type and implicit array types are not holders. Held for a standalone table, a
  sequence, an enum and a domain at a forward name (reasoned from `_is_fine_child_label` and the arms; the
  preflight refusals are exercised by the existing suite). See hypothesis H1 for the one shape it passes.
- The 23505 arm of the handler around the cutover's obtain (#1135): `duplicate_table`, `duplicate_object`,
  `unique_violation`; `obtain` itself never raises those (it steps over holders via `_obtain_name`), so the
  arm can only fire on a concurrent creator, as intended. `_transmute_names_present` is read before obtain
  so pre-existing array-type holders are skipped (p_skip). Held.
- `_transmute_reap` (#1166): lock first, claim re-read `for update skip locked`, PGPMR rollback when gone or
  alive, `skip_transmute_reap` on `lock_not_available`. Held by reading; no claim.
- `restore_incoming_fks` / `_fk_def_unvalidated` (#633): the parking of a failed one-step re-add is written
  but never consulted by the loop. Claimed F18-03. `_fk_def_unvalidated` strips only a trailing ` NOT
  VALID`, which is where `pg_get_constraintdef` puts it on 15 through 18. Held.
- `_refuse_bad_transmute_arguments` (#1085): shared rules; `extract(year)*12 + extract(month)` for a
  calendar sign, then epoch; held. NaN as an id step passes `p_step::numeric <= 0` (false for NaN) and
  `_id_step_contract` (NaN = NaN), but the only public route is the `bigint` overload, which cannot carry
  NaN, and from_hypertable passes 'time' only. Not a defect; recorded as H3.
- `_time_unit_contract` and the date anchor (#1117): message for a date names the anchor's UTC time and
  the session zone; held.

## time and zones

- Every bound `_transmute` writes goes through `_encode` -> `_time_literal(…, v_tz)` (CHECK, `for values`)
  or `_ts_text` (claim lo/hi, pgpm.part, log); `_ts_text` pins `datestyle = 'ISO, MDY'` for the render.
  The min read is `_ts_text(t.col)` for timestamptz, and the naive read is `::text` then `::timestamp at
  time zone v_tz` in the same session (so the same DateStyle parses what it rendered). Held.
- `transmute`'s wrappers hand `p_interval::text` and `p_retain::text` to `_transmute`, rendered in the
  session's IntervalStyle. Probed all four styles (postgres, postgres_verbose, sql_standard, iso_8601) with
  '1 month', '90 days', '1 day 2 hours 30 minutes', '-1 day', '1 year 2 months 3 days 04:05:06' and
  '-1 month 30 days': every rendering parses back to the same interval. Held (no DateStyle-class defect for
  intervals).
- A naive key records `partition_tz = 'UTC'` whatever the session zone, and the frontier for a date or
  timestamp key is `max(col)::timestamp at time zone 'UTC'` against `now()`; the east-of-UTC lead is
  documented in the reference. Held.
- Resumed bound from another zone: `partition_tz` is taken from the claim (`v_tz := coalesce(v_claim_tz,
  v_tz)`) before the grid check and the monolith name. Held.
- `_frontier_skew_limit` is `now() + step + 1 hour` with `now()` the transaction start; held.

## boundary arithmetic and types

- `_control_bound_contract`: non-finite check via `in ('NaN','Infinity','-Infinity')` then round trip
  through `format_type(atttypid, atttypmod)` (domains unwrapped for the finest-step remedy only, and
  transmute refuses a domain id key before asking). Held.
- `_id_step_contract`: scale from the typmod through domains; held (NaN note above).
- `_array_type_name`, `_is_clone_pkey_name`: 63-byte clipping on character boundaries; held.
- `_transmute_refuse_child_holders`' `starts_with(relname, rel || '_p')`: a sibling managed table
  `<rel>_px` has children `<rel>_px_p…`, whose suffix `x_p…` is not a fine label; the monolith's own
  `<lo>_to_<hi>` label is not a fine label. Held. A 60-byte table name is refused by `_part_name` before the
  cutover (never truncated), so no truncated forward name reaches the prefix test. Held.
- `_identity_reseed`: numeric division, lattice walk both directions, clamp at the bound; held.

## operator error

- A second transmute over a converted table: refused by the `pgpm.config` row check before anything is
  committed. A re-run over a half-converted table from the same session: resumed (second claim arm). From
  another live session: "already in progress". Held by reading; existing tests exercise all three.
- `transmute_abort` of nothing returns false; bad `p_lock_timeout` refused with the setting restored. Held.
- `p_incoming_fks => 'drop'` takes `'preserve'`'s path (recorded and restored): documented in the
  reference, so not a defect.
- Remedies typed: `_refuse_detach_pending`'s FINALIZE (works), `_transmute_refuse_child_holders`' `drop
  table` (for a table; other relkinds get "drop or rename", no command), `_transmute_refuse_staging_squatter`'s
  `drop table` (fails for a sequence or a view: F18-02), the bare-unique remedy's `ADD CONSTRAINT …
  USING INDEX` (correct shape), the reaper's "re-run transmute" (resumes).
- TABLE-form `GRANT USAGE ON <sequence>` as `_acl_carry_ddl` emits for identity sequences: probed on PG 15,
  accepted (and `REVOKE ALL … CASCADE`, `GRANT ALL` likewise). Held.

## failure injection

- Phase boundaries: a raise after the claim insert rolls the claim back (first transaction); a cutover
  failure leaves bound + claim and the re-run resumes from the recorded bound; `_transmute_reap` and
  `transmute_abort` both find the table by oid. Held by reading.
- A hand-dropped `pgpm_monolith_bound` with the claim left: the re-run re-adds the CHECK and phase 2's
  VALIDATE fails raw on any row written past hi in between; state is the resumable one. Recorded as H4
  (raw message only).
- `_detach_reap`'s `when others` around FINALIZE logs `fail_detach_reap` and leaves the row; the #705
  disown runs before and outside it. Held.
- `restore_incoming_fks` one-step re-add on an orphan: parked, but the park is not honoured (F18-03); on
  success `validate_retry_after` is cleared (14872). The NOT VALID path never scans. Held otherwise.

## contracts versus documentation

- Reference `transmute` entries: refusals listed (zone names, RLS, NOT VALID keys, bare unique index,
  staging and monolith names, orphan children) each map to a preflight site; `transmute_abort`'s "returns
  false", "raises if running in another session", "your own session's attempt is yours" all match the
  code. `untransmute`'s entry promises the pending-detach refusal "the same two ways" (line 678): the code
  does not keep it (F18-01, the reference is right). `restore_incoming_fks`'s five-minute park (line 3549)
  is not kept (F18-03). `pgpm.transmute_inflight` column table matches the DDL.

## Hypotheses (no reproduction built)

- H1 (`_transmute_refuse_child_holders`, 9564-9607; boundary / fresh surface): a relation that IS in
  pg_inherits under ANOTHER parent (an operator's own partitioned table with a partition named exactly
  `<rel>_p<label>` in the same schema) is excluded by the `not exists (pg_inherits)` arm in both the
  preflight and the final ask, yet `_obtain_name` steps over it (to_regclass finds it, pgpm.part does
  not), so the conversion completes with that cell unbuilt and no refusal. Contrived fixture (needs a
  sibling partitioned table whose partition carries the forward name); not built.
- H2 (`obtain`, ~2975, and `extend_to`; outside S1, S2's units): `_log_unbuilt_cell` (2129) has no call
  site in install.sql; obtain's `if v_name is null then null; end if;` sits under the comment "a hole in the
  grid, so it is logged (#710)". The reference (3747, 3942) promises a `fail_obtain_name` row per unbuilt
  cell per tick. Build: create a sequence named for a future forward cell after transmute, call
  `pgpm.obtain(parent)`, expect a `fail_obtain_name` row naming the holder; none is written. Left to S2.
- H3 (`_refuse_bad_transmute_arguments` 1449 and `_id_step_contract` 8957): a NaN id step passes both
  gates; unreachable from the public `bigint` overload, so no claim.
- H4 (`_transmute` phase 1/2 after a hand-dropped CHECK with the claim left): VALIDATE fails with a raw
  23514 rather than pgpm's words; no loss, state resumable. Not built.

## Round 2

Built (both shape 6, a derived name squatted with nothing logged):
- H2 -> F18-04 (Tier 3, contracts versus documentation): `_log_unbuilt_cell` has no caller; a sequence at
  the next forward cell's name leaves `obtain` building nothing and logging no `fail_obtain_name` (4
  LIVENESS ok, 2 defect checks not ok). Unit is S2's `obtain`; filed here since the hypothesis was mine.
- H1 -> F18-05 (Tier 2, fresh surface): a partition of another parent at `<rel>_p<first forward label>`
  passes `_transmute_refuse_child_holders` (pg_inherits exclusion) and obtain's step-over; the conversion
  completes with [0,1000) and [2000,3000) built and [1000,2000) a silent hole (2 LIVENESS ok, 4 not ok).
  The CALL runs at top level with ON_ERROR_STOP off around it, so a refusal on a fixed tree passes the file.
Not attempted: H3 (NaN id step: unreachable from the public bigint overload, no state to build); H4 (hand-
dropped CHECK with the claim left: a raw 23514 at phase 2, no loss, resumable; a message-wording claim only).
