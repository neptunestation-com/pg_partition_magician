## Defect (#1265)

`pgpm.check_time_monotonic` compared `%I::timestamptz`, so the time column was cast in the CALLER's session `TimeZone`. A naive `timestamp` column (or a text column holding offset-free wall times) with a value inside that zone's spring-forward gap read an hour late: 02:30 on 2026-03-08 in `America/New_York` casts to 03:30 EDT, past 03:15. The same column then reported 1.0 from a UTC session and 0.5 from New York, and a pair that really falls across the gap (03:15 then 02:30) read as rising. `docs/reference.md` defines the result as the fraction of adjacent pairs whose time is non-decreasing, with no word of a zone.

## Fix

`check_time_monotonic` now carries a function-level `SET timezone = 'UTC'` (the shape `archive._row_digest` already uses). The `::timestamptz` cast therefore never takes the caller's zone, UTC has no gap and no repeated hour, and PostgreSQL restores the caller's `TimeZone` (including a transaction's `SET LOCAL`) when the call returns.

What it guarantees, for `check_time_monotonic` (the only site):

- a naive `timestamp`, `date` or offset-free text column is compared as its own wall-clock values, whatever the caller's zone;
- a `timestamptz` column, or text with an explicit offset, is still compared by instant (the cast is kept, not dropped);
- the caller's session and transaction-local `TimeZone` are unchanged after the call.

Sibling check functions: `check_uuidv7` decodes a uuid and `check_text_time` decodes text with its epoch as a bound `timestamptz` parameter (#1081); neither casts a column through the session zone, so neither is changed.

Not covered (outside this issue): a text column's date ORDER (`MDY` vs `DMY`) is still parsed under the caller's `DateStyle`; see the report's adjacent observations.

## Acceptance

- Reproduction: F2-02's `repro.sql` fails on the base (`not ok 4`, have 0.5000) and passes on this head.
- Test: `tests/335_check_time_monotonic_session_zone_test.sql` (17 assertions): A the issue's column from UTC and New York; B an asymmetric fixture (three pairs, one falls across the gap) reporting `(3,2,0.6667)` from both; C the same for an offset-free text column; D text with explicit offsets compared by instant (its lexical order is the reverse) and a `timestamptz` column; E the caller's `TimeZone` untouched, in autocommit and under `SET LOCAL`. Passes on PG 15 and PG 18.
- Guard: `bench/check_time_monotonic_session_zone.sh` (`pgpm_perf373`), a pgTAP wrapper over tests/335.
- Mutation: `check_time_monotonic_session_zone` drops the `SET timezone` clause; the guard FAILS against it on tests 3, 6 and 8 (parts A, B, C), none of them a LIVENESS line.
- `./test.sh 15 --channel=psql` PASS; `check_quoted_splices.py` PASS; every mutation builds; `shellcheck` clean; `check_living_docs.sh` PASS; markdownlint clean.

Closes #1265

🤖 Generated with [Claude Code](https://claude.com/claude-code)

