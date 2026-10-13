# Surface of the change: 6 file(s), 10 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 5-16
- `bench/snapshot_wait_foreign_floor_holder.sh` (added): 1-63
- `docs/reference.md` (modified): 1000-1003, 1973-1974, 1986-2004, 2063-2064
- `pgpm_core/install.sql` (modified): 7639-7652, 7699-7703, 7732-7732, 7811-7842
- `test.sh` (modified): 310-310, 313-319, 340-345, 1280-1280
- `tests/333_snapshot_wait_foreign_floor_holder_test.sql` (added): 1-236

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:7639-7652` in `pgpm_core/install.sql` lines 7639-7652: top-level hunk, outside every function
- `pgpm_core/install.sql:7699-7703` in `pgpm_core/install.sql` lines 7699-7703: top-level hunk, outside every function
- `pgpm._snapshot_wait` in `pgpm_core/install.sql` lines 7721-7855: touched at 7732-7732
- `pgpm._regrain_snapshot_wait` in `pgpm_core/install.sql` lines 7858-7864: calls pgpm._snapshot_wait
- `pgpm.from_hypertable_cutover` in `pgpm_hypertable/install.sql` lines 1618-2399: calls pgpm._snapshot_wait
- `CHANGELOG.md` (modified file, read it whole)
- `bench/snapshot_wait_foreign_floor_holder.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/333_snapshot_wait_foreign_floor_holder_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._snapshot_wait`: `bench/hypertable_cutover_waits_for_older_snapshots.sh`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/328_regrain_swap_waits_for_older_snapshots_test.sql`, `tests/333_snapshot_wait_foreign_floor_holder_test.sql`
