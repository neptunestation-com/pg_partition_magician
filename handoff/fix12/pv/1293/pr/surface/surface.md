# Surface of the change: 6 file(s), 7 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 5-11
- `bench/check_time_monotonic_session_zone.sh` (added): 1-51
- `docs/reference.md` (modified): 3481-3485
- `pgpm_core/install.sql` (modified): 14287-14294, 14298-14299
- `test.sh` (modified): 1268-1268
- `tests/335_check_time_monotonic_session_zone_test.sql` (added): 1-108

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:14287-14294` in `pgpm_core/install.sql` lines 14287-14294: top-level hunk, outside every function
- `pgpm.check_time_monotonic` in `pgpm_core/install.sql` lines 14295-14317: touched at 14298-14299
- `CHANGELOG.md` (modified file, read it whole)
- `bench/check_time_monotonic_session_zone.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/335_check_time_monotonic_session_zone_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm.check_time_monotonic`: `bench/check_time_monotonic_session_zone.sh`, `docs/guide.md`, `docs/reference.md`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/16_time_correlation_test.sql`, `tests/241_reads_under_caller_rls_conformance_test.sql`, `tests/335_check_time_monotonic_session_zone_test.sql`
