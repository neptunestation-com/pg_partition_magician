# Surface of the change: 7 file(s), 12 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 4-16
- `bench/retain_disown_remedy.sh` (added): 1-52
- `docs/reference.md` (modified): 1510-1526, 1532-1533, 3735-3735
- `pgpm_core/install.sql` (modified): 3480-3492, 3495-3495, 3499-3499, 3501-3505, 3508-3511, 3591-3591
- `test.sh` (modified): 1268-1268
- `tests/327_retire_pending_detach_test.sql` (modified): 517-517
- `tests/339_retain_disown_remedy_test.sql` (added): 1-156

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:3480-3492` in `pgpm_core/install.sql` lines 3480-3492: top-level hunk, outside every function
- `pgpm._disown_retirement` in `pgpm_core/install.sql` lines 3493-3514: touched at 3495-3495
- `pgpm._disown_unvouched_retirements` in `pgpm_core/install.sql` lines 3565-3600: touched at 3591-3591
- `pgpm.retire` in `pgpm_core/install.sql` lines 3639-4028: calls pgpm._disown_retirement
- `pgpm._retain_recall` in `pgpm_core/install.sql` lines 4067-4180: calls pgpm._disown_retirement
- `pgpm._detach_reap` in `pgpm_core/install.sql` lines 11973-12044: calls pgpm._disown_retirement
- `CHANGELOG.md` (modified file, read it whole)
- `bench/retain_disown_remedy.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/327_retire_pending_detach_test.sql` (modified file, read it whole)
- `tests/339_retain_disown_remedy_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._disown_retirement`: `bench/retain_disown_remedy.sh`, `docs/reviews/2026-10-12-pass12.md`, `tests/339_retain_disown_remedy_test.sql`
- `pgpm._disown_unvouched_retirements`: `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/327_retire_pending_detach_test.sql`, `tests/339_retain_disown_remedy_test.sql`
