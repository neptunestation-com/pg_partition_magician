# P1 null results: per-PR verification of #1305

Harness: `pgpm_prv-15`, fresh databases `prv_p1_1305_{a,b,c,d}`, the tree's `pgpm_core/install.sql` piped in
under `--single-transaction`, every database dropped afterwards (`pg_database` checked clean at the end).

## Lens: fresh surface

- `pgpm._native_bound_key(kind, text, tz)` (5157-5165): probed from a `UTC / ISO, MDY` session and an
  `Asia/Kolkata / SQL, DMY` session with the legacy shapes the brief names: a pre-#500 `SQL, DMY` render with a
  space-separated zone abbreviation (`01/10/2026 00:00:00 UTC`), an ambiguous abbreviation (`... IST`), a
  Postgres-style render (`Thu 01 Oct 00:00:00 2026 UTC`), a German-style one (`01.10.2026 00:00:00 UTC`) and a
  bare date. Every one gave the identical numeric key from both sessions (the DateStyle pin reads the
  DateStyle-shaped ones as MDY, the body's stated rule; an abbreviation parses through the global abbreviation
  table, not the session zone). The id branch is a plain `::numeric`, the pre-change cast. Held.
- The SET-clause scoping the body promises: after a call, and after a call that RAISES inside the helper
  (`'garbage'::timestamptz` caught by a DO handler), the session's `TimeZone / DateStyle` were still
  `Asia/Kolkata / SQL, DMY`. tests/334 parts 12 and 13 pass on the tree as well. Held.
- `pgpm._over_retired_chunks` (5168-5214): the only non-cosmetic change beyond the helper is where the keys are
  computed; the floor read (`_native_order_key(l.hi) > v_floor or is null`) is unchanged and still keys only
  offset-carrying text, so it never decides an overlap. tests/317 (the #1163 range-first contract, 13 checks,
  including the offset-less `pgpm.part` lo of part C) passes 13/13 on the tree. The keys are computed inside the
  parent-filtered materialized CTEs, so #973 still holds. The one thing that does not hold is the zone argument
  itself: claim P1-01.
- `pgpm.retain` (4164-4222) and `pgpm._archive_step` (5270-5477): both consume `_over_retired_chunks` by
  `child_name` only (`v_held`), unchanged by the PR; neither re-derives the overlap. Read; no fresh-surface
  defect introduced there. `_archive_step`'s own orphan-discard query (5311-5323) and `_archive_fully_covered`'s
  watermark still cast unretired bounds in the caller's session: this is the class the body itself names as not
  covered and reported separately, so it is a hypothesis below, not a claim.
- `test.sh` 1259: `pgpm_perf372` is used once in the file; the guard is in the sharded perf list. Held.
- `bench/over_retired_chunks_grid_zone.sh`: read whole; same shape as the wrapper it cites (install under
  `ON_ERROR_STOP`, pg_prove, `not ok` lines surfaced, a `ran = 0` liveness). It cannot be run here (no `/repo`
  mount in the private harness). Its description says the three mutations fail it on non-premise assertions; on
  THIS tree the guard's test file itself fails checks 5, 7, 9, 11 and 16, so the guard is live (see P1-01).
- `CHANGELOG.md` and `docs/reference.md` hunks: both state the grid's-clock rule the code does not keep. Not
  filed separately: same root cause as P1-01, one claim.

## Lens: time and zones

- What the grid's clock is for a date grid versus a timestamptz grid: a `date` control column transmutes as
  `control_kind = 'time'` with `partition_tz = 'UTC'` (#504) and its bounds are written `+00`, so an offset-less
  legacy bound of such a grid reads as its UTC wall date, the same reading `_col_to_native` gives the column.
  Consistent with the helper's rule (once the right zone is passed). Held.
- The rule versus tests/317's contract: 317 states "from any session's TimeZone and DateStyle" and its offset-less
  fixture (`gone_z`, a UTC grid read from UTC and Asia/Kolkata) lands inside the partition from both zones, so it
  agrees with the grid's-clock rule but cannot discriminate the session-zone defect: that is why it is green on
  this tree while tests/334 is not. No contradiction between the two files' stated contracts.
- The reference's wording ("never in the caller's TimeZone or DateStyle"): accurate to the intended rule,
  contradicted by the code on this tree (P1-01).
- Order of the chunk description (`order by l.lo_k`) and the `m.lo_k < max(x.hi_k)` prefilter: both go through
  the same key, so once the zone argument is right they are session-independent; with the caller's zone they fail
  together with the join, which P1-01's second check (Pacific/Kiritimati, empty result) covers.

## Hypotheses (no reproduction built)

1. `_archive_step`'s orphan discard (5311-5323, `l.lo::timestamptz < t.hi::timestamptz` in the caller's session
   over UNRETIRED rows under an untracked name) and `_archive_fully_covered`'s `_max_hi_native` watermark: an
   offset-less pre-#977 bound on an unretired row is still read on the session's clock, so whether an orphan's
   coverage is discarded (`archive_coverage_reset`, a DELETE of ledger rows) or a partition reads as fully covered
   depends on who calls. The body names this class as adjacent and reported separately; not built to avoid a
   duplicate. Consequence is fail-closed in the first (re-archive from lo) and the #977 shape in the second.
2. `timezone_abbreviations` is a session GUC: a legacy bound carrying an ambiguous abbreviation (`IST`) would key
   differently in a session that changed that GUC. Nothing in pgpm sets it, and no install writes abbreviations,
   so this is outside the stated rule rather than a defect.
3. `_native_bound_key` raises (no handler) on text that is not a timestamp, whereas `_native_order_key` returns
   null; the pre-change `::timestamptz` cast raised the same way, so this is unchanged behaviour, not fresh.
