# F5 null results (pass 12, slice S5: pgpm_archive/install.sql)

Whole module read top to bottom (3950 lines), plus pgpm_archive/README.md and docs/reference.md's
"Real S3 archive strategies" and null-argument entries, and the strategy call sites in
scripts/archive_partition_whole.sql. Probes ran in pgpm_test-archive against MinIO (databases f5_*,
dropped after; bucket objects deleted).

## fresh surface

- #1168 (to_s3 keyset cursor `(control, tableoid, ctid)`, NULL run, relkind tree refusal, allowlist + LIMIT 0
  probe, domain paged as base type): read against its comments. Cursor cast does NOT carry the typmod although
  the comment and CHANGELOG say it does: claimed as F5-01 (char(n) never ends; bit(n) the same mechanism).
  The NULL run, the switch from the non-NULL run (`v_page_rows = 0 and not v_null_run`), the cursor's
  `array_agg(... order by k desc, r desc, c desc)[1]` and the conservation fingerprint all held on read.
- #1069 digest (`archive._row_digest`, `_refuse_recorded_chunk_overwrite`): checked every session setting an
  output function reads under row_to_json (TimeZone, DateStyle, IntervalStyle, extra_float_digits,
  bytea_output, lc_monetary, search_path for reg* types; ranges/arrays/composites route through the same
  output functions) and found each pinned. NDJSON digest (`t.*` of the parent) and Parquet digest (`s.*` over
  the snapshot's parent columns) are of the same column list. The claim row is locked FOR UPDATE before the
  ledger lookup; the update of rows_digest happens only after the loop admits. Held.
- `_owned_key` / `_claim_object_key` / install seeding (`_claim_archived_key_bases`, `_claim_archived_keys`,
  `_record_claim_relations`): regexes for the base and the oid shape checked against fractional, negative and
  BC stems; held. The text-only identity of a key is defeated by a store that normalises a leading '/':
  F5-02.

## time and zones

- to_s3 export with fetch_rows 1 under `IntervalStyle sql_standard`, `bytea_output escape`, `DateStyle SQL, DMY`,
  `TimeZone America/New_York`, over timetz (two offsets, equal instants), interval (mixed signs), bytea (0x00,
  0x5c, 0xff), timestamptz across the 2024-11-03 repeated hour, real (NaN, -0, 0), date (BC and year 20240),
  varchar(3), time(0): every export completed with every row once. `_cursor_text` pins ISO/UTC, and the
  unpinned settings are read and written by the same session. Held.
- `_object_stem` (UTC, ISO pinned; era and fraction kept) vs the read's session interpretation of an
  offset-less p_lo: the key then names a different instant than the read, but `_refuse_recorded_chunk_overwrite`
  compares range in the session's interpretation and refuses at a recorded key; at an unrecorded key the tick
  later overwrites with its own chunk. No loss found.
- `_pq_epoch_micros` (immutable; infinity sentinels; clamp before extract), the naive `at time zone 'UTC'`
  branch and `_pq_logical_timestamp_micros` adjusted flags: held on read.
- `s3_signed_request*` use clock_timestamp() for x-amz-date (not now()). Held.

## boundary arithmetic and types

- Thrift compact protocol: field-header delta range 1..15, list short form <= 14, bool type nibble 1/2, every
  struct field id (SchemaElement 1-10, PageHeader 1,2,3,5, DataPageHeader 1-4, ColumnMetaData 1-7,9, ColumnChunk
  2,3, RowGroup 1-3, FileMetaData 1-4,6, LogicalType.TIMESTAMP 8 / TimeUnit.MICROS 2) checked against
  parquet.thrift; Parquet physical/converted type codes checked. Held.
- `_pq_decimal_shape` (signed 11-bit scale, negative scale and scale > precision), `_pq_decimal_byte_width`,
  `_pq_plain_decimal` (div/mod, two's complement), NaN as null with `_pq_has_nan`: held on read. numeric
  Infinity cannot be stored in numeric(p,s).
- DEFLATE: fixed code table, length codes 257-285 (257 -> 284 extra 30, 258 -> 285), distance codes to 32768,
  window check, dynamic HLIT/HDIST/HCLEN, code-length order, RLE 16/17/18 ranges, length-limited Huffman repair
  (weight -1 per step), single-symbol code, bit accumulator width (<= 22 bits in int4); gzip header/trailer and
  unsigned->signed CRC/ISIZE: held on read.
- `_pq_varint`/`_pq_zigzag` at the sign edges: zigzag(INT64 min) overflows, but no caller passes a negative
  count/offset or INT64 min. Held.
- to_s3 page boundary on a run of equal control values, on NULLs, fetch_rows 1, relations of one and many heaps:
  covered by the probe above and by the code's total order. Composite, array, json, regproc refused by the
  allowlist. char(n)/bit(n): F5-01.

## operator error

- archive.configure: part_bytes < 5 MiB, fetch_rows < 1, null arguments refused; endpoint, region, bucket and
  prefix not validated. Probed: endpoint `http://minio:9000/` (trailing slash) is accepted and every request
  then goes to `//bucket/...`, refused 400 by MinIO (loud, every tick skip_archive); endpoint `minio:9000` (no
  scheme) accepted, 403 SignatureDoesNotMatch; prefix `x//` accepted, MinIO 400 XMinioInvalidObjectName; prefix
  `x/a/../` accepted, 403. All loud, nothing written, so recorded here rather than claimed. Prefix with a leading
  '/' is NOT loud: it aliases another spelling's objects (F5-02).
- unconfigure mid-export: the export reads its config row once into a local; held.
- Direct strategy calls with swapped/empty bounds (refused by `_refuse_empty_range`), a wrong p_child (unused,
  documented), a NaN/Infinity hi on a numeric id grid (refused at a recorded key by the native range compare;
  at an unrecorded key overwritten by the tick's own chunk later). Held.
- Re-run export over a claimed key: same relation admitted, another relation refused (documented remedy: another
  prefix). Runbook remedy "export the partition with archive.to_s3" for a held re-created partition: key is its
  own, held.

## failure injection

- to_s3: claim is inside the `<<export>>` subtransaction, so an error rolls it back; cancel reaches the outer
  `query_canceled` handler which aborts by id or by key (`_s3_abort_uploads_at`); a cancel during the inner
  handler's DELETE propagates to the outer handler with the id still set. Held on read.
- Strategies: a PUT that fails rolls back the digest update and the claim; a tick that fails after the PUT leaves
  an unrecorded object that the next tick rewrites at the same key. Held.
- `when others` around the to_s3 type probe: swallows any error into "cannot page by"; the only non-type errors
  reachable there (a lock or permission failure) are pre-empted by `_resolve_child`'s LOCK TABLE, which takes the
  same locks first. Not claimed.

## contracts versus documentation

- README / reference promises on refusals (null args, RLS, empty range, recorded chunk, unpageable types and
  relkinds), key shapes (chunk, export, oid shapes, `.ndjson.gz`), re-run semantics and multipart abort: checked
  against code; the typmod promise is broken (F5-01) and "a key is never reused by a different relation" is
  broken under a leading-slash prefix (F5-02). README's manual example `pgpm.retire(parent, child)` matches the
  signature.
- reference: "the encoded bytes ... are identical" between to_s3 and the strategies is loose (to_s3 orders by
  (control, tableoid, ctid), the strategy by control) but changes nothing an operator types. Not claimed.

## Hypotheses (not reproduced)

- H1. `pgpm.set_archive_fn` accepts `pgpm.archive_to_s3_parquet` for a table whose control column is `date` or
  `varchar` (both pgpm control types), and `archive._pq_to_parquet_range_counted`'s type switch (install.sql
  ~2618-2646) raises "unsupported column type" on every chunk, so every tick logs skip_archive and retention
  never passes the first partition. README documents the eleven types, so this is a documented limit with a
  wedge and no preflight; likely known.
- H2. `archive._s3_abort_uploads_at`, MinIO pagination: MinIO leaves NextUploadIdMarker empty, so the next page
  is asked with key-marker = the last key and no upload-id-marker, which lists keys strictly after it; with more
  than p_page_size uploads in flight at exactly p_key, those past the first page are never aborted. Needs 1001
  leaked uploads at one key to build.
- H3. AWS S3 itself (endpoint null) keeps '/P/x' and 'P/x' distinct, so F5-02 is store-dependent; other
  S3-compatible stores that normalise paths (Supabase Storage?) would alias the same way. Not tested beyond MinIO.
- H4. to_s3 cancelled after CompleteMultipartUpload succeeded at the store but before its response is read: the
  handler aborts a completed upload (404, ignored), the transaction rolls back and the claim with it, leaving an
  unclaimed object at the plain key that a later namesake can claim and replace. The caller saw an error, so it
  should not have dropped the source; low value.

## Round 2

- H1 built as F5-03 (Tier 3): the Parquet strategy refuses every chunk of a `date`-controlled table with
  "unsupported column type date" while set_archive_fn accepted it. Driven by direct strategy calls over a chunk of
  the table's own monolith, with an NDJSON twin archiving the same range as the witness; a maintain()-driven
  version was tried first, but on a fresh date grid the only past partition is the monolith, whose hi is past
  now(), so no tick finds an eligible partition without a much larger fixture. The varchar (text_time) variant of
  H1 is the same mechanism and was not built separately.
- H4 not built: the cancel would have to land after CompleteMultipartUpload succeeded and before the call
  returns. Building it would mean a stand-in transport that raises query_canceled once the complete call
  returns. Even then the caller sees an error and the object holds exactly the partition's rows, so no
  documented contract is broken until an operator drops the source after a failed call. Judged not a defect
  worth the budget.
- H2 (MinIO listing markers past 1000 uploads at one key) and H3 (store-dependence of F5-02) not attempted:
  H2 needs more than 1000 leaked multipart uploads at one key, and H3 is a remark on F5-02's tier, not a separate
  defect.
- None of the hypotheses has a long-surviving shape (no detach-pending gate, no read before a lock, no sibling
  copy, no older-install state, no squatted derived name); no mechanical pre-pass in this slice.
