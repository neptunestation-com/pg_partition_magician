# Surface of the change: 6 file(s), 14 unit(s) in the ledger

## Files and hunks (head-side lines)
- `CHANGELOG.md` (modified): 4-19
- `bench/archive_key_base_canonical.sh` (added): 1-109
- `docs/reference.md` (modified): 2784-2797
- `pgpm_archive/install.sql` (modified): 168-175, 2867-2876, 2894-2899, 2989-3016, 3060-3061, 3063-3064
- `test.sh` (modified): 981-984
- `tests/archive/db/52_archive_key_base_canonical_test.sql` (added): 1-187

## Units (read every one; the ledger names them exactly)
- `archive.configure` in `pgpm_archive/install.sql` lines 143-203: touched at 168-175
- `archive._canonical_key` in `pgpm_archive/install.sql` lines 2872-2875: touched at 2867-2876
- `archive._owned_key` in `pgpm_archive/install.sql` lines 2879-2925: touched at 2894-2899
- `archive._claim_canonical_spellings` in `pgpm_archive/install.sql` lines 2995-3014: touched at 2989-3016
- `archive._refuse_recorded_chunk_overwrite` in `pgpm_archive/install.sql` lines 3054-3086: touched at 3060-3061
- `archive._object_key` in `pgpm_archive/install.sql` lines 2932-2935: calls archive._owned_key
- `archive._encode_upload_ndjson_single` in `pgpm_archive/install.sql` lines 3097-3175: calls archive._refuse_recorded_chunk_overwrite
- `archive._encode_upload_parquet` in `pgpm_archive/install.sql` lines 3186-3236: calls archive._refuse_recorded_chunk_overwrite
- `archive._child_object_key` in `pgpm_archive/install.sql` lines 3342-3345: calls archive._owned_key
- `CHANGELOG.md` (modified file, read it whole)
- `bench/archive_key_base_canonical.sh` (added file, read it whole)
- `docs/reference.md` (modified file, read it whole)
- `test.sh` (modified file, read it whole)
- `tests/archive/db/52_archive_key_base_canonical_test.sql` (added file, read it whole)

## Exercised by (context, not in the ledger)
- `archive._canonical_key`: `bench/archive_key_base_canonical.sh`
- `archive._claim_canonical_spellings`: `tests/archive/db/52_archive_key_base_canonical_test.sql`
- `archive._owned_key`: `bench/archive_export_key_by_relation.sh`, `bench/archive_key_base_canonical.sh`, `bench/archive_key_by_resolved_oid.sh`, `bench/archive_key_full_claim.sh`, `bench/archive_key_owner_every_path.sh`, `bench/archive_keys_row_read.sh`, `bench/lint_child_by_oid_inverse.sh`, `bench/lint_value_not_spelling.sh`, `docs/adversarial-review.md`, `docs/reviews/2026-10-02-pass7.md`, `docs/reviews/2026-10-06-pass9.md`, `docs/reviews/2026-10-08-pass10.md` ...
- `archive._refuse_recorded_chunk_overwrite`: `bench/archive_fn_s3_readback.sh`, `bench/archive_key_base_canonical.sh`, `bench/archive_recorded_chunk.sh`, `bench/archive_recorded_chunk_tick_race.sh`, `bench/archive_retired_chunk_digest_layer.sh`, `docs/reviews/2026-10-06-pass9.md`, `docs/reviews/2026-10-08-pass10.md`, `docs/reviews/2026-10-09-pass11.md`, `tests/archive/db/48_archive_recorded_chunk_rows_identity_test.sql`, `tests/archive/db/50_archive_retired_chunk_kept_test.sql`
- `archive.configure`: `bench/archive_keys_row_read.sh`, `bench/archive_null_arguments.sh`, `bench/archive_recorded_chunk_tick_race.sh`, `bench/archive_to_s3_loud_edges.sh`, `bench/archive_to_s3_part_bytes.sh`, `bench/lint_value_not_spelling.sh`, `docs/guide.md`, `docs/reference.md`, `docs/reviews/2026-09-28.md`, `docs/reviews/2026-10-04-pass8.md`, `docs/reviews/2026-10-08-pass10.md`, `docs/reviews/2026-10-12-pass12.md` ...
