## The defect (#1264, F15-02)

`pgpm._over_retired_chunks` decides which attached partitions sit over a retired chunk's range (#1141): the archive
step skips them and `retain()` leaves them out of its batch. It compared every bound with `::timestamptz` in the
CALLER's session. A retired `pgpm.archive_ledger` row an older install wrote can carry a bound with no offset
(before #977 a strategy's `covered_hi` was stored verbatim, and no upgrade rewrites a retired row), and such text
names a different instant in every zone: the same call held a partition from pg_cron's UTC session and nothing from
an operator's Asia/Kolkata one (a hand `_archive_step` or `retain()`), against tests/317's stated contract (the same
answer from any session's TimeZone and DateStyle).

## The fix

One mechanism, at every comparison the function makes. A new helper, `pgpm._native_bound_key(kind, text, tz)`,
returns a bound's position as a number: the value for an `id` kind; for a time kind the epoch of the instant the
text names, parsed with `TimeZone` set to the grid's `config.partition_tz`, `DateStyle` pinned to `ISO, MDY` and
`timezone_abbreviations` pinned to `Default`, all scoped to the call by its SET clauses (the caller's settings are
left as they were; tests/334 parts F and H check them). So:

- a bound with an offset (every bound pgpm writes since #500) is the instant it names, unchanged;
- a bound with no offset is wall time on the grid's clock, `partition_tz` (the zone the grid's cells are computed
  and named in, and the zone `_col_to_native` reads a naive column's wall time in), not UTC and not the caller's;
- a DateStyle-shaped bound (a pre-#500 render) reads as `ISO, MDY`, the style `_ts_text` writes;
- a zone abbreviation (a pre-#500 render under DateStyle `SQL` or `Postgres` ends in one) reads in the `Default`
  set: `'01/01/2026 03:00:00 IST'` is Israel's +02 from every session, not India's +05:30 from a session on the
  India set (round 1's V-01).

Sites covered, all inside `_over_retired_chunks`: the overlap join's four bounds (`led.lo`, `led.hi`, `mine.lo`,
`mine.hi`), the `m.lo < max(x.hi)` prefilter, and the chunk description's order. Each key is computed once per row
in the existing materialized CTEs (after their parent filter, so #973 still holds). The floor read through
`archive_ledger_retired_hi_key_idx` is unchanged: it keys only text with an offset and takes every unkeyed row as a
candidate, so it never decides an overlap.

Read rule, not an upgrade rewrite (the issue asked which): a retired row is the record of the only copy and its
`lo` is the ledger's primary key, so the rows are read on the grid's clock rather than rewritten; the same rule
also covers an offset-less `pgpm.part` bound an operator's hand left (tests/317 part C).

Not covered (adjacent, reported separately): other readers of ledger bounds outside this function, e.g.
`_archive_fully_covered`'s watermark over an unretired pre-#977 row, still cast in the caller's session.

## Acceptance

- F15-02's `repro.verified.sql`: 6/6 on this head; fails its one non-LIVENESS assertion on base `b76002e6` and on
  the `over_retired_chunks_session_zone` mutant.
- `tests/334_over_retired_chunks_grid_zone_test.sql`: a grid registered in Asia/Tokyo with five retired chunks
  (offset-less `hi`, offset-less `lo`, DateStyle-shaped, and offset-carrying), the held partitions and chunks named
  exactly from five sessions (UTC; Asia/Tokyo; Asia/Kolkata under `SQL, DMY`; Pacific/Kiritimati;
  America/Los_Angeles under `German`), each with a LIVENESS witness that the session's own parse gives another
  answer, plus a UTC grid read from Tokyo (part G) and a UTC grid with an `IST`-bearing legacy `hi` read from an
  Asia/Kolkata session on the India abbreviations (part H). Green on PG 15 and PG 18; on base its six
  cross-session checks fail (5, 7, 9, 11, 16, 21).
- V-01's `repro.sql` (round 1): 6/6 on this head; fails its one non-premise assertion against the
  `native_bound_key_session_abbreviations` mutant.
- Guard `bench/over_retired_chunks_grid_zone.sh` (pgpm_perf372), a pgTAP wrapper in the shape of
  `bench/retain_recall_moved_parent.sh`. Mutations, each failing it on non-premise assertions:
  - `over_retired_chunks_session_zone`: the bounds read in the caller's TimeZone (the pre-fix shape);
  - `native_bound_key_utc`: the plausible-but-wrong fix, offset-less read as UTC;
  - `native_bound_key_session_datestyle`: the DateStyle pin dropped;
  - `native_bound_key_session_abbreviations`: the `timezone_abbreviations` pin dropped (part H).

Closes #1264

🤖 Generated with [Claude Code](https://claude.com/claude-code)

