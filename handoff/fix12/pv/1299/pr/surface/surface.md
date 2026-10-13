# Surface of the change: 8 file(s), 26 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 4-17
- `bench/retirement_mark_needs_dispatch.sh` (added): 1-56
- `docs/reference.md` (modified): 1491-1496, 2249-2257
- `pgpm_core/install.sql` (modified): 2160-2190, 2199-2203, 2222-2222, 2229-2230, 2239-2240, 3530-3530, 5245-5247, 5256-5256
- `test.sh` (modified): 1268-1268
- `tests/280_obtain_rebuilds_detached_cell_test.sql` (modified): 134-136
- `tests/307_write_block_skips_hand_detached_test.sql` (modified): 186-187
- `tests/330_retirement_mark_needs_dispatch_test.sql` (added): 1-232

## Units (read every one; the ledger names them exactly)
- `pgpm._detach_dispatched` in `pgpm_core/install.sql` lines 2166-2174: touched at 2160-2190
- `pgpm._retirement_vouched` in `pgpm_core/install.sql` lines 2186-2189: touched at 2160-2190
- `pgpm_core/install.sql:2199-2203` in `pgpm_core/install.sql` lines 2199-2203: top-level hunk, outside every function
- `pgpm._part_built` in `pgpm_core/install.sql` lines 2213-2224: touched at 2222-2222
- `pgpm_core/install.sql:2229-2230` in `pgpm_core/install.sql` lines 2229-2230: top-level hunk, outside every function
- `pgpm_core/install.sql:2239-2240` in `pgpm_core/install.sql` lines 2239-2240: top-level hunk, outside every function
- `pgpm._disown_retirement` in `pgpm_core/install.sql` lines 3518-3531: touched at 3530-3530
- `pgpm_core/install.sql:5245-5247` in `pgpm_core/install.sql` lines 5245-5247: top-level hunk, outside every function
- `pgpm._archive_hold_partition` in `pgpm_core/install.sql` lines 5251-5259: touched at 5256-5256
- `pgpm._part_detached_by_hand` in `pgpm_core/install.sql` lines 2244-2249: calls pgpm._part_built
- `pgpm._cell_attached` in `pgpm_core/install.sql` lines 2271-2310: calls pgpm._part_built
- `pgpm._cell_walk_rows` in `pgpm_core/install.sql` lines 2339-2356: calls pgpm._part_built
- `pgpm._disown_unvouched_retirements` in `pgpm_core/install.sql` lines 3566-3601: calls pgpm._detach_dispatched, pgpm._disown_retirement
- `pgpm.retire` in `pgpm_core/install.sql` lines 3640-4029: calls pgpm._detach_dispatched, pgpm._disown_retirement
- `pgpm._retain_recall` in `pgpm_core/install.sql` lines 4068-4181: calls pgpm._detach_dispatched, pgpm._disown_retirement
- `pgpm._archive_step` in `pgpm_core/install.sql` lines 5261-5468: calls pgpm._archive_hold_partition
- `pgpm._detach_reap` in `pgpm_core/install.sql` lines 11975-12046: calls pgpm._detach_dispatched, pgpm._disown_retirement
- `pgpm.status` in `pgpm_core/install.sql` lines 14354-14474: calls pgpm._part_built
- `pgpm.progress` in `pgpm_core/install.sql` lines 14518-14637: calls pgpm._part_built
- `CHANGELOG.md` (modified file, read it whole)
- `bench/retirement_mark_needs_dispatch.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/280_obtain_rebuilds_detached_cell_test.sql` (modified file, read it whole)
- `tests/307_write_block_skips_hand_detached_test.sql` (modified file, read it whole)
- `tests/330_retirement_mark_needs_dispatch_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._archive_hold_partition`: `bench/archive_hold_detach_in_flight.sh`, `bench/archive_whole_skips_hand_detached.sh`, `bench/retirement_mark_needs_dispatch.sh`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `scripts/archive_partition_whole.sql`, `tests/307_write_block_skips_hand_detached_test.sql`, `tests/325_archive_hold_detach_in_flight_test.sql`, `tests/330_retirement_mark_needs_dispatch_test.sql`
- `pgpm._detach_dispatched`: `bench/retirement_mark_needs_dispatch.sh`, `docs/reviews/2026-10-12-pass12.md`, `tests/330_retirement_mark_needs_dispatch_test.sql`
- `pgpm._disown_retirement`: `docs/reviews/2026-10-12-pass12.md`
- `pgpm._part_built`: `bench/obtain_rebuilds_detached_cell.sh`, `bench/progress_write_child_built.sh`, `bench/retirement_mark_needs_dispatch.sh`, `docs/reviews/2026-10-06-pass9.md`, `docs/reviews/2026-10-08-pass10.md`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/279_progress_write_child_exists_test.sql`, `tests/298_obtain_backoff_hole_test.sql`, `tests/307_write_block_skips_hand_detached_test.sql`, `tests/330_retirement_mark_needs_dispatch_test.sql`
- `pgpm._retirement_vouched`: `bench/retirement_mark_needs_dispatch.sh`, `tests/330_retirement_mark_needs_dispatch_test.sql`
