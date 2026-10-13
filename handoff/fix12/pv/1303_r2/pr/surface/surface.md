# Surface of the change: 7 file(s), 12 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 4-21
- `bench/retain_disown_remedy.sh` (added): 1-55
- `docs/reference.md` (modified): 1510-1538, 1544-1545, 3213-3216, 3750-3750
- `pgpm_core/install.sql` (modified): 3480-3506, 3509-3511, 3515-3515, 3517-3553, 3556-3557, 3637-3637
- `test.sh` (modified): 1268-1268
- `tests/327_retire_pending_detach_test.sql` (modified): 517-517
- `tests/339_retain_disown_remedy_test.sql` (added): 1-221

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:3480-3506` in `pgpm_core/install.sql` lines 3480-3506: top-level hunk, outside every function
- `pgpm._disown_retirement` in `pgpm_core/install.sql` lines 3507-3560: touched at 3509-3511
- `pgpm._disown_unvouched_retirements` in `pgpm_core/install.sql` lines 3611-3646: touched at 3637-3637
- `pgpm.retire` in `pgpm_core/install.sql` lines 3685-4074: calls pgpm._disown_retirement
- `pgpm._retain_recall` in `pgpm_core/install.sql` lines 4113-4226: calls pgpm._disown_retirement
- `pgpm._detach_reap` in `pgpm_core/install.sql` lines 12019-12090: calls pgpm._disown_retirement
- `CHANGELOG.md` (modified file, read it whole)
- `bench/retain_disown_remedy.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/327_retire_pending_detach_test.sql` (modified file, read it whole)
- `tests/339_retain_disown_remedy_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._disown_retirement`: `bench/retain_disown_remedy.sh`, `docs/reviews/2026-10-12-pass12.md`, `tests/339_retain_disown_remedy_test.sql`
- `pgpm._disown_unvouched_retirements`: `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/327_retire_pending_detach_test.sql`, `tests/339_retain_disown_remedy_test.sql`
