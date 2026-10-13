# Surface of the change: 6 file(s), 13 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 5-18
- `bench/snapshot_wait_foreign_floor_holder.sh` (added): 1-65
- `docs/reference.md` (modified): 1000-1003, 1973-1974, 1986-2006, 2065-2069
- `pgpm_core/install.sql` (modified): 7639-7652, 7699-7706, 7733-7733, 7812-7845, 13479-13485
- `test.sh` (modified): 310-310, 313-319, 340-345, 1280-1280
- `tests/333_snapshot_wait_foreign_floor_holder_test.sql` (added): 1-312

## Units (read every one; the ledger names them exactly)
- `pgpm_core/install.sql:7639-7652` in `pgpm_core/install.sql` lines 7639-7652: top-level hunk, outside every function
- `pgpm_core/install.sql:7699-7706` in `pgpm_core/install.sql` lines 7699-7706: top-level hunk, outside every function
- `pgpm._snapshot_wait` in `pgpm_core/install.sql` lines 7722-7858: touched at 7733-7733
- `pgpm.maintain` in `pgpm_core/install.sql` lines 13319-13528: touched at 13479-13485
- `archive._pq_encode_column_data` in `pgpm_archive/install.sql` lines 2017-2135: calls pgpm.maintain
- `pgpm._regrain_snapshot_wait` in `pgpm_core/install.sql` lines 7861-7867: calls pgpm._snapshot_wait
- `pgpm.maintain_all` in `pgpm_core/install.sql` lines 13548-13629: calls pgpm.maintain
- `pgpm.from_hypertable_cutover` in `pgpm_hypertable/install.sql` lines 1618-2399: calls pgpm._snapshot_wait
- `CHANGELOG.md` (modified file, read it whole)
- `bench/snapshot_wait_foreign_floor_holder.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/333_snapshot_wait_foreign_floor_holder_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `pgpm._snapshot_wait`: `bench/hypertable_cutover_waits_for_older_snapshots.sh`, `docs/reviews/2026-10-09-pass11.md`, `docs/reviews/2026-10-12-pass12.md`, `tests/328_regrain_swap_waits_for_older_snapshots_test.sql`, `tests/333_snapshot_wait_foreign_floor_holder_test.sql`
- `pgpm.maintain`: `bench/README.md`, `bench/archive_extension_resolution.sh`, `bench/archive_huffman_lock_entries.sh`, `bench/archive_key_full_claim.sh`, `bench/archive_key_reused_name.sh`, `bench/archive_recorded_chunk.sh`, `bench/archive_recorded_chunk_rows_identity.sh`, `bench/archive_recorded_chunk_tick_race.sh`, `bench/archive_retired_chunk_digest_layer.sh`, `bench/archive_step_child_isolation.sh`, `bench/datestyle_bounds.sh`, `bench/doc_archive_identity_recovery.sh` ...
