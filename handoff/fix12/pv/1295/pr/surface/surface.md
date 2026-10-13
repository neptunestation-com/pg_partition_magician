# Surface of the change: 6 file(s), 7 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 5-12
- `bench/adopt_partition_isolation.sh` (added): 1-55
- `docs/reference.md` (modified): 3021-3021, 3033-3038
- `pgpm_core/install.sql` (modified): 14005-14013, 14021-14024
- `test.sh` (modified): 1268-1268
- `tests/332_adopt_partition_isolation_test.sql` (added): 1-132

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:14005-14013` in `pgpm_core/install.sql` lines 14005-14013: top-level hunk, outside every function
- `pgpm.adopt_partition` in `pgpm_core/install.sql` lines 14014-14143: touched at 14021-14024
- `CHANGELOG.md` (modified file, read it whole)
- `bench/adopt_partition_isolation.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/332_adopt_partition_isolation_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm.adopt_partition`: `bench/adopt_partition.sh`, `bench/adopt_partition_isolation.sh`, `bench/adopt_partition_regrain_lock.sh`, `bench/archive_retired_chunk_kept.sh`, `bench/doc_archive_identity_recovery.sh`, `docs/adversarial-review.md`, `docs/guide.md`, `docs/reference.md`, `docs/reviews/2026-10-08-pass10.md`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `docs/runbook.md` ...
