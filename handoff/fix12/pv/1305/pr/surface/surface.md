# Surface of the change: 6 file(s), 10 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 5-16
- `bench/over_retired_chunks_grid_zone.sh` (added): 1-59
- `docs/reference.md` (modified): 2474-2477
- `pgpm_core/install.sql` (modified): 5137-5143, 5150-5166, 5170-5170, 5172-5172, 5181-5183, 5189-5192, 5206-5206, 5209-5210, 5212-5212
- `test.sh` (modified): 1259-1259
- `tests/334_over_retired_chunks_grid_zone_test.sql` (added): 1-137

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:5137-5143` in `pgpm_core/install.sql` lines 5137-5143: top-level hunk, outside every function
- `pgpm._native_bound_key` in `pgpm_core/install.sql` lines 5157-5165: touched at 5150-5166
- `pgpm._over_retired_chunks` in `pgpm_core/install.sql` lines 5168-5214: touched at 5170-5170
- `pgpm.retain` in `pgpm_core/install.sql` lines 4164-4222: calls pgpm._over_retired_chunks
- `pgpm._archive_step` in `pgpm_core/install.sql` lines 5270-5477: calls pgpm._over_retired_chunks
- `CHANGELOG.md` (modified file, read it whole)
- `bench/over_retired_chunks_grid_zone.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/334_over_retired_chunks_grid_zone_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._over_retired_chunks`: `bench/over_retired_chunks_grid_zone.sh`, `bench/over_retired_chunks_range_first.sh`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `scripts/archive_partition_whole.sql`, `tests/309_archive_retired_chunk_kept_test.sql`, `tests/314_ledger_backfill_origin_only_block_test.sql`, `tests/317_over_retired_chunks_range_first_test.sql`, `tests/334_over_retired_chunks_grid_zone_test.sql`
