# Surface of the change: 9 file(s), 31 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 4-23
- `bench/retirement_mark_needs_dispatch.sh` (added): 1-65
- `docs/reference.md` (modified): 1491-1496, 2249-2257, 2272-2281
- `pgpm_core/install.sql` (modified): 2160-2191, 2200-2204, 2223-2223, 2230-2231, 2240-2241, 3531-3531, 5246-5247, 5251-5261, 5267-5285, 5440-5449
- `scripts/archive_partition_whole.sql` (modified): 70-70, 158-166
- `test.sh` (modified): 1268-1268
- `tests/280_obtain_rebuilds_detached_cell_test.sql` (modified): 134-136
- `tests/307_write_block_skips_hand_detached_test.sql` (modified): 186-187
- `tests/330_retirement_mark_needs_dispatch_test.sql` (added): 1-325

## Units (read every one; the ledger names them exactly)
- `pgpm._detach_dispatched` in `pgpm_core/install.sql` lines 2166-2174: touched at 2160-2191
- `pgpm._retirement_vouched` in `pgpm_core/install.sql` lines 2187-2190: touched at 2160-2191
- `pgpm_core/install.sql:2200-2204` in `pgpm_core/install.sql` lines 2200-2204: top-level hunk, outside every function
- `pgpm._part_built` in `pgpm_core/install.sql` lines 2214-2225: touched at 2223-2223
- `pgpm_core/install.sql:2230-2231` in `pgpm_core/install.sql` lines 2230-2231: top-level hunk, outside every function
- `pgpm_core/install.sql:2240-2241` in `pgpm_core/install.sql` lines 2240-2241: top-level hunk, outside every function
- `pgpm._disown_retirement` in `pgpm_core/install.sql` lines 3519-3532: touched at 3531-3531
- `pgpm_core/install.sql:5246-5247` in `pgpm_core/install.sql` lines 5246-5247: top-level hunk, outside every function
- `pgpm_core/install.sql:5251-5261` in `pgpm_core/install.sql` lines 5251-5261: top-level hunk, outside every function
- `pgpm._archive_hold_partition` in `pgpm_core/install.sql` lines 5262-5269: touched at 5267-5285
- `pgpm._archive_unheld_retirement` in `pgpm_core/install.sql` lines 5278-5287: touched at 5267-5285
- `pgpm._archive_step` in `pgpm_core/install.sql` lines 5289-5504: touched at 5440-5449
- `pgpm._part_detached_by_hand` in `pgpm_core/install.sql` lines 2245-2250: calls pgpm._part_built
- `pgpm._cell_attached` in `pgpm_core/install.sql` lines 2272-2311: calls pgpm._part_built
- `pgpm._cell_walk_rows` in `pgpm_core/install.sql` lines 2340-2357: calls pgpm._part_built
- `pgpm._disown_unvouched_retirements` in `pgpm_core/install.sql` lines 3567-3602: calls pgpm._detach_dispatched, pgpm._disown_retirement
- `pgpm.retire` in `pgpm_core/install.sql` lines 3641-4030: calls pgpm._detach_dispatched, pgpm._disown_retirement
- `pgpm._retain_recall` in `pgpm_core/install.sql` lines 4069-4182: calls pgpm._detach_dispatched, pgpm._disown_retirement
- `pgpm.retain` in `pgpm_core/install.sql` lines 4184-4242: calls pgpm._archive_step
- `pgpm._detach_reap` in `pgpm_core/install.sql` lines 12011-12082: calls pgpm._detach_dispatched, pgpm._disown_retirement
- `pgpm.maintain` in `pgpm_core/install.sql` lines 13325-13528: calls pgpm._archive_step
- `pgpm.status` in `pgpm_core/install.sql` lines 14390-14510: calls pgpm._part_built
- `pgpm.progress` in `pgpm_core/install.sql` lines 14554-14673: calls pgpm._part_built
- `CHANGELOG.md` (modified file, read it whole)
- `bench/retirement_mark_needs_dispatch.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `scripts/archive_partition_whole.sql` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/280_obtain_rebuilds_detached_cell_test.sql` (modified file, read it whole)
- `tests/307_write_block_skips_hand_detached_test.sql` (modified file, read it whole)
- `tests/330_retirement_mark_needs_dispatch_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._archive_hold_partition`: `bench/archive_hold_detach_in_flight.sh`, `bench/archive_whole_skips_hand_detached.sh`, `bench/retirement_mark_needs_dispatch.sh`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `scripts/archive_partition_whole.sql`, `tests/307_write_block_skips_hand_detached_test.sql`, `tests/325_archive_hold_detach_in_flight_test.sql`, `tests/330_retirement_mark_needs_dispatch_test.sql`
- `pgpm._archive_step`: `bench/archive_chunk_ties.sh`, `bench/archive_covered_hi_canonical.sh`, `bench/archive_hold_detach_in_flight.sh`, `bench/archive_identity_substitution.sh`, `bench/archive_ledger_identity.sh`, `bench/archive_parquet_snapshot_locks.sh`, `bench/archive_partition_whole_contract.sh`, `bench/archive_partition_whole_follows_step.sh`, `bench/archive_recorded_chunk_tick_race.sh`, `bench/archive_retired_chunk_kept.sh`, `bench/archive_step_child_isolation.sh`, `bench/archive_whole_skips_hand_detached.sh` ...
- `pgpm._archive_unheld_retirement`: `scripts/archive_partition_whole.sql`
- `pgpm._detach_dispatched`: `bench/retirement_mark_needs_dispatch.sh`, `docs/reviews/2026-10-12-pass12.md`, `tests/330_retirement_mark_needs_dispatch_test.sql`
- `pgpm._disown_retirement`: `docs/reviews/2026-10-12-pass12.md`
- `pgpm._part_built`: `bench/obtain_rebuilds_detached_cell.sh`, `bench/progress_write_child_built.sh`, `bench/retirement_mark_needs_dispatch.sh`, `docs/reviews/2026-10-06-pass9.md`, `docs/reviews/2026-10-08-pass10.md`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/279_progress_write_child_exists_test.sql`, `tests/298_obtain_backoff_hole_test.sql`, `tests/307_write_block_skips_hand_detached_test.sql`, `tests/330_retirement_mark_needs_dispatch_test.sql`
- `pgpm._retirement_vouched`: `bench/retirement_mark_needs_dispatch.sh`, `tests/330_retirement_mark_needs_dispatch_test.sql`
