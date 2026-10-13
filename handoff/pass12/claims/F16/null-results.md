# F16 null results (pass 12, slice S12: the archive and timescale pgTAP suites, their fixtures, fixtures/demo.sql)

Coverage: 92 of 116 units read whole (see coverage.md). The 24 timescale files 33-36, 44-63 (bar the ones
listed as read) were only grepped for their assertion lines, or not opened, for want of budget: the slice is
below 0.9 and should be split or re-run for those files.

## Pre-pass

- `count(*)`: 318 hits. Verdict by family: archive files pair every count with an identity read-back (ids,
  id:payload strings, byte equality) except 08 Part A (NDJSON monolith checked by line count 5000, the two
  5-row chunks never read back; hypothesis H3) and the "nothing at key" / "no skip_archive" negatives, each
  paired with a ledger or 404 witness (sound). Timescale 02/03/09/10/14/15 use counts as their main
  assertion; their headers promise counts, and 02/03 add `rows_equal` over distinct-row fixtures (sound).
- `sum(`: 08:51 and 08:150 (rows_archived 5010: cardinality, paired with Parquet byte identity in Part B,
  not in Part A: H3); 22:88 Kraft sum, a property check (sound); timescale 12:14 the estimate's own formula
  (sound for a pure helper).
- `length(`: 41 hits, all page-offset arithmetic over `_pq_build_page_header` (sound: offsets, not checks)
  or octet lengths as witnesses, except archive 16 Part B and 26 Part B, where `octet_length` (neg_bytes >
  pos_bytes, bytes a > bytes b) is the assertion that the right Parquet object sits at a key: size, not
  identity (H2).
- `throws_ok(` with NULL or three-argument shapes: archive 20:38 (an INSERT, no COMMIT: sound); timescale
  16:27/52/59/92, 21:79/109, 27:80, 28:127, 38:110, 40:54/85, 41:44, 44:52, 45:63, 48:107, 59:126 (all
  INSERT/SELECT/DELETE statements that commit nothing: sound); 08:27 around a committing cutover pins
  SQLSTATE and message (sound); 19:38, 27:47, 61:99/154 pin messages (sound).
- `is(..., 0, ...)`: every hit paired with a liveness line in the same part (checked per file); none claimed.
- `null || x`: one hit, timescale 33:23, a comment describing the defect it fixed; no live `|| null`.

## Lenses

### fresh surface
- archive/db/51 read whole: multi-heap cursor, NULL runs, typmod-carrying casts, the type allowlist. Probed
  the allowlist's round-trip claim for interval under every IntervalStyle (sql_standard, iso_8601,
  postgres_verbose, mixed-sign values): every rendering read back equal (held). Float cursors: to_s3 pins
  extra_float_digits = 1 at function level, so `_cursor_text` inherits it (held). bytea under escape output
  round-trips (held).
- archive/db/50: retired chunk kept, digest arm pinned with 90 = 90 rows; the remedy matches reference.md.
- archive/db/37: read `_pq_snapshot`'s shape check in pgpm_archive/install.sql (names, types, typmods,
  collations, the ordinal): reuse across same-shape tables cannot mix columns (held).
- timescale 64, 65, 66, 67, 20, 22 read whole. 67: every negative paired with reader-snapshot and no-lock
  witnesses; F/G regexes allow other pids around the importer (sound). 66: probed a naive `timestamp(0)`
  dimension with a 1500 ms step: refused before the copy (held); the refusal's remedy text is F16-01.

### time and zones
- Zone-sensitive files and what each did not vary: archive 14 (NY vs UTC; no fixed-offset zone, no
  DateStyle), archive 16_encode (legacy NY naive grid; session UTC only), 26 (Karachi/Bogota; timestamptz
  only, no naive control), 35 (Karachi + SQL DMY for BC stems), 36 (Shanghai/Guam under Postgres style);
  timescale 19 (Tokyo/LA, naive and date; ISO only), 35 (NY spring-forward naive watermark), 36 (Shanghai
  SQL DMY), 66 (date anchor at 12:00 UTC; session UTC only). No file runs a fall-back (repeated hour)
  watermark on a naive dimension; see H6.

### boundary arithmetic and types
- Checked 41's empty/inverted range: compared natively (`pgpm._native_gt`), '9' < '10' control (held);
  NaN as p_hi reads every row >= lo (a superset, not a loss).
- 23/28: part_bytes floor exactly at 5242880 accepted, 5242879 refused (held). 23 (timescale): name budget
  at 48/49 bytes exactly (held).

### operator error
- Every refusal in archive 09, 23, 28, 41 and timescale 24, 26, 28, 34, 58 read for its remedy: 26 types the
  remedy (drop the constraints) and migrates; 34 types the override. 66's remedy is not typed: F16-01.

### failure injection
- archive 24/28: cancel inside the transport and inside the initiate, a pending cancel, statement_timeout.
  Sibling not driven: a transport that returns a non-2xx for a part (no exception) mid-multipart; none of
  the files drive an HTTP 5xx answer from the stand-in. Not built (H1).
- timescale 08: a dependent view aborts the swap; the sibling (a failure after the swap's COMMIT, in the
  handoff) is driven only by bench per 21's header.

### contracts versus documentation
- 16_to_s3_compress's header says multipart identity is the bench's; consistent.
- 44 header says the objects written under `search_path = app` are read back by identity; the tick's two
  Parquet objects are only checked for a `PAR1` prefix (H4).

## Hypotheses (not reproduced)

- H1. archive/db/24 and 28 inject cancels and raised errors in the transport stand-in, never a returned
  non-2xx `http_response` (a 503 for part 3). Whether archive.to_s3 aborts the upload on a returned error
  status as it does on a raised one is untested by the archive suite. Build: t24.http returning
  `(503, ...)` for partNumber=3 and assert `t24.inflight(key) = '{}'`.
- H2. archive/db/16_archive_object_key_identity Part B (and 26 Part B) assert the Parquet object at the
  [-10000, 0) key by `octet_length(neg) > octet_length(pos)`. A mutant whose Parquet strategy writes the
  right SIZE of file for the wrong rows (e.g. the right chunk encoded from a different snapshot or with a
  column swapped) passes. Build: replace with `fetch_object(key) = archive._pq_to_parquet_range(...)`
  over the recorded [lo, hi), as 08 Part B does.
- H3. archive/db/08 Part A checks the NDJSON monolith by line count and the two 5-row chunks not at all; a
  strategy emitting 5000 copies of one row would pass the read-back (5000 lines) while rows_archived and
  coverage stay right. Build: ids array identity as in 12/26.
- H4. archive/db/44 Part B's Parquet tick objects asserted only as 'PAR1'-prefixed files; the header promises
  identity. Build: byte equality against `_pq_to_parquet_range` of each ledgered [lo, hi).
- H5. archive.object_key_claim and object_key_owner key a namesake by relation oid; after OID wraparound a
  new relation can take a dropped one's oid and pass the claim as the "same relation" (34, 39, 43). Not
  reproducible without wrapping the OID counter.
- H6. No test runs the append-only catch-up of a naive `timestamp` dimension across a fall-back (repeated
  hour) in the session zone; timescale/35 covers the spring-forward gap only.
- H7. The same wrong remedy as F16-01 is raised by `pgpm._time_unit_contract`'s timestamp(p) branch
  (pgpm_core/install.sql:9092) through from_hypertable_cutover (it says re-run transmute and
  transmute_abort on a hypertable); the claim's repro drives the date branch only.
- H8. archive/db/29 loads `/repo/pgpm_core/install.sql` and `/repo/pgpm_archive/install.sql` into its LATIN1
  sibling, not the tree under test: in a harness whose /repo is another checkout, the file tests that
  checkout's signer, not the one installed in the test database.

## Round 2

Built first, by the precedence rule for pre-pass assertions weakened to a count, a length or a prefix; each
repro runs the test file from `$TREE` against a mutant pgpm_archive (a sed/py edit applied in the repro, the
mutation script kept in the claim directory) with LIVENESS lines that the mutant lost data and that the file ran
to its plan:

- H2 -> F16-02 (Tier 5): archive/db/16 Part B's `neg_bytes > pos_bytes` stays 23/23 green against a Parquet
  strategy that archived 500 of the chunk's 1000 rows. (26 Part B's size check is NOT claimed: 26 also asserts
  the ledger's rows_archived, which the same mutant breaks.)
- H3 -> F16-03 (Tier 5): archive/db/08 stays 22/22 green against an NDJSON strategy writing `"id":1` on every
  line (line counts only).
- H4 -> F16-04 (Tier 5): archive/db/44 stays 15/15 green against a Parquet strategy that PUTs only `PAR1`.

Tried and not built:
- H1: read archive.to_s3's part and complete paths: a returned non-2xx raises inside the export, and the
  `when others` handler runs `_s3_abort_uploads_at`; the abort on a 503 holds by construction, so a repro would
  pass on the tree.

Not attempted (budget, or no reproducible state):
- H5 (OID reuse after wraparound: no reachable state in a test database).
- H6 (fall-back watermark on a naive dimension: a pgpm-side hunt in the timescale harness, beyond 15 minutes).
- H7 (the timestamp(p) branch of F16-01's message: the same defect and line family as F16-01, not a new claim).
- H8 (archive/29's /repo paths: a property of the harness's mount, not reproducible from a fresh database).
