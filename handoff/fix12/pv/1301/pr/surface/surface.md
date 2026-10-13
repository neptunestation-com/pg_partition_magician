# Surface of the change: 6 file(s), 15 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 4-13
- `bench/archive_configure_endpoint.sh` (added): 1-105
- `pgpm_archive/README.md` (modified): 34-38
- `pgpm_archive/install.sql` (modified): 60-62, 139-150, 169-169, 200-207, 211-211, 389-390, 466-466
- `test.sh` (modified): 981-984
- `tests/archive/db/53_configure_endpoint_canonical_test.sql` (added): 1-103

## Units (read every one; the ledger names them exactly)
- `pgpm_archive/install.sql:60-62` in `pgpm_archive/install.sql` lines 60-62: top-level hunk, outside every function
- `archive._s3_endpoint_canonical` in `pgpm_archive/install.sql` lines 146-149: touched at 139-150
- `archive.configure` in `pgpm_archive/install.sql` lines 157-217: touched at 169-169
- `archive.s3_signed_request` in `pgpm_archive/install.sql` lines 371-436: touched at 389-390
- `archive.s3_signed_request_bytea` in `pgpm_archive/install.sql` lines 451-502: touched at 466-466
- `archive._encode_upload_ndjson_single` in `pgpm_archive/install.sql` lines 3068-3146: calls archive.s3_signed_request, archive.s3_signed_request_bytea
- `archive._encode_upload_parquet` in `pgpm_archive/install.sql` lines 3157-3207: calls archive.s3_signed_request_bytea
- `archive._s3_abort_uploads_at` in `pgpm_archive/install.sql` lines 3335-3392: calls archive.s3_signed_request
- `archive.to_s3` in `pgpm_archive/install.sql` lines 3417-3793: calls archive.s3_signed_request, archive.s3_signed_request_bytea
- `archive.to_s3_parquet` in `pgpm_archive/install.sql` lines 3804-3834: calls archive.s3_signed_request_bytea
- `CHANGELOG.md` (modified file, read it whole)
- `bench/archive_configure_endpoint.sh` (added file, read it whole)
- `pgpm_archive/README.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/archive/db/53_configure_endpoint_canonical_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `archive._s3_endpoint_canonical`: `bench/archive_configure_endpoint.sh`
- `archive.configure`: `bench/archive_configure_endpoint.sh`, `bench/archive_keys_row_read.sh`, `bench/archive_null_arguments.sh`, `bench/archive_recorded_chunk_tick_race.sh`, `bench/archive_to_s3_loud_edges.sh`, `bench/archive_to_s3_part_bytes.sh`, `bench/lint_value_not_spelling.sh`, `docs/guide.md`, `docs/reference.md`, `docs/reviews/2026-09-28.md`, `docs/reviews/2026-10-04-pass8.md`, `docs/reviews/2026-10-08-pass10.md` ...
- `archive.s3_signed_request`: `bench/archive_fn_s3_readback.sh`, `bench/archive_null_arguments.sh`, `bench/archive_recorded_chunk_tick_race.sh`, `bench/archive_signer_non_utf8.sh`, `docs/reference.md`, `docs/reviews/2026-10-04-pass8.md`, `docs/reviews/2026-10-09-pass11.md`, `scripts/check_archive_object_keys.py`, `tests/archive/db/08_archive_fn_s3_test.sql`, `tests/archive/db/12_to_s3_tied_rows_test.sql`, `tests/archive/db/13_to_s3_parquet_child_identity_test.sql`, `tests/archive/db/15_parquet_single_snapshot_test.sql` ...
- `archive.s3_signed_request_bytea`: `bench/archive_fn_s3_readback.sh`, `bench/archive_null_arguments.sh`, `docs/reference.md`, `docs/reviews/2026-10-09-pass11.md`, `tests/archive/db/17_sigv4_wall_clock_test.sql`, `tests/archive/db/38_archive_reads_under_caller_rls_test.sql`, `tests/archive/db/39_archive_key_owner_every_path_test.sql`, `tests/archive/db/41_archive_null_arguments_test.sql`, `tests/archive/db/44_archive_extension_resolution_test.sql`, `tests/archive/db/53_configure_endpoint_canonical_test.sql`
