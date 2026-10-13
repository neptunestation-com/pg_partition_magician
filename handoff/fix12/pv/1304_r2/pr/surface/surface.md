# Surface of the change: 6 file(s), 11 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 5-15
- `bench/archive_direct_call_bounds.sh` (added): 1-105
- `docs/reference.md` (modified): 2765-2772
- `pgpm_archive/install.sql` (modified): 2747-2752, 3040-3055, 3080-3090, 3180-3182
- `test.sh` (modified): 981-984
- `tests/archive/db/54_archive_direct_call_bounds_session_test.sql` (added): 1-242

## Units (read every one; the ledger names them exactly)
- `pgpm_archive/install.sql:2747-2752` in `pgpm_archive/install.sql` lines 2747-2752: top-level hunk, outside every function
- `archive._bound_native` in `pgpm_archive/install.sql` lines 3048-3054: touched at 3040-3055
- `archive._encode_upload_ndjson_single` in `pgpm_archive/install.sql` lines 3065-3154: touched at 3080-3090
- `archive._encode_upload_parquet` in `pgpm_archive/install.sql` lines 3165-3218: touched at 3180-3182
- `pgpm.archive_to_s3_ndjson` in `pgpm_archive/install.sql` lines 3894-3923: calls archive._encode_upload_ndjson_single
- `pgpm.archive_to_s3_parquet` in `pgpm_archive/install.sql` lines 3925-3950: calls archive._encode_upload_parquet
- `CHANGELOG.md` (modified file, read it whole)
- `bench/archive_direct_call_bounds.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/archive/db/54_archive_direct_call_bounds_session_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `archive._bound_native`: `tests/archive/db/54_archive_direct_call_bounds_session_test.sql`
- `archive._encode_upload_ndjson_single`: `bench/archive_direct_call_bounds.sh`, `bench/archive_encode_partition_tz.sh`, `bench/archive_float_digits_pinned.sh`, `bench/archive_ndjson_row_alias.sh`, `docs/reference.md`, `scripts/check_archive_object_keys.py`, `tests/archive/db/08_archive_fn_s3_test.sql`, `tests/archive/db/16_encode_partition_tz_test.sql`, `tests/archive/db/32_float_digits_pinned_test.sql`, `tests/archive/db/33_ndjson_row_alias_shadowed_test.sql`, `tests/archive/db/39_archive_key_owner_every_path_test.sql`, `tests/archive/db/46_parquet_read_by_regclass_test.sql`
- `archive._encode_upload_parquet`: `bench/archive_direct_call_bounds.sh`, `bench/archive_encode_partition_tz.sh`, `bench/archive_fn_s3_readback.sh`, `bench/archive_parquet_snapshot.sh`, `docs/reference.md`, `scripts/check_archive_object_keys.py`, `tests/archive/db/08_archive_fn_s3_test.sql`, `tests/archive/db/15_parquet_single_snapshot_test.sql`, `tests/archive/db/16_encode_partition_tz_test.sql`, `tests/archive/db/39_archive_key_owner_every_path_test.sql`
