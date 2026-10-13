# F19 null results (slice S5: the archive module)

Harness: `pgpm_test-archive`, database `f19_a` (dropped afterwards), tree installed from
`tests/archive/fixtures.sql`, `pgpm_core/install.sql`, `pgpm_archive/install.sql`. Every probe below was
run; "held" means the behaviour matched the code's own comment and the documents.

## fresh surface

- `archive.to_s3` (#1168): the keyset order `(control, tableoid, ctid)`, the NULL run after the non-null
  run, the type allowlist and its LIMIT 0 probe, the tree walk refusing views, materialized views and
  foreign leaves: read against the comment and tests/archive/db/51. The one thing the comment promises
  that the code does not do is the typmod on the cursor's cast (`v_ctl_mod` is computed and never used,
  `v_ctltype` is the bare `regtype::text`): claim F19-01 (char(3) and bit(3) never end).
- `archive._row_digest` and `_refuse_recorded_chunk_overwrite` (#1069): the digest pins TimeZone,
  DateStyle, IntervalStyle, extra_float_digits, bytea_output, lc_monetary and search_path, which is every
  setting that changes `row_to_json` text of a scalar I could name (xml, jsonb, inet, enum output depend on
  none). The NDJSON digest is of `t.*` of the parent and the Parquet digest of `s.*` of the snapshot's
  columns in attnum order; the key set and the values are the same for the same rows (CTAS keeps typmods and
  collations). The claim-row `FOR UPDATE` is taken before the ledger read; the digest UPDATE precedes the
  PUT and rolls back with it. A chunk of zero rows digests to md5('') on both paths and re-runs admitted.
  Held.
- `_owned_key` / `_claim_object_key` / `_child_object_key` (#890, #976, #1064): read for the base and
  whole-key claims, the oid shape and the two refusals; the install-time seeders' regexps (`_[^_]*$` and
  the oid-shape exclusion) against stems that hold `.`, `BC`, a sign, and prefixes or table names holding
  `_`. Held.
- The `#969` null-argument wrappers on every public routine: read; `p_lo`/`p_hi` of the exports and
  `p_child` of the strategies accepted as documented. Held.

## time and zones

- `archive._cursor_text` round trip under `TimeZone Asia/Kolkata` + `DateStyle SQL, DMY`,
  `IntervalStyle sql_standard | postgres_verbose | iso_8601`, `bytea_output escape`: timestamptz (incl.
  five-digit year and BC), timestamp, date, timetz, interval (mixed-sign), bytea: every value read back
  equal. The `float4` rendering inherits `archive.to_s3`'s function-level `extra_float_digits = 1`. Held.
- `row_to_json` of an interval written under `sql_standard` (`+0-0 +1 -2:00:00`, `-0-10 -3 +4:00:00`) reads
  back as the same interval under the default style: the NDJSON payload survives the style. Held.
- `_object_stem` under its pinned UTC/ISO: digits for `+00`, BC suffix, fraction keeps the point. Held for
  canonical (ISO, offset-carrying) text, which is everything the tick, the ledger and the operator script
  hand it. For non-ISO text handed by a direct call it disagrees with the rest of the call: claim F19-03.
- `_pq_epoch_micros`: finite clamp at INT64 max - 1, infinity sentinels, naive `timestamp at time zone
  'UTC'`, far past (-2.1e17 us fits). `extract(epoch)` is numeric on PG 14+, so no float rounding. Held.
- The NDJSON and Parquet range literals go through `pgpm._encode(..., partition_tz)`, whose
  `_time_literal` carries an explicit offset, so a session zone cannot move the read. Held.

## boundary arithmetic and types

- `_pq_decimal_shape` at negative scale, scale above precision; `_pq_decimal_byte_width` at precision 1, 3,
  7 (negative-scale widening) and 1000; `_pq_plain_decimal` two's complement at width 1 (-9 -> f7). Held.
- `_pq_varint`, `_pq_zigzag`, `_pq_list_hdr` at 14/15, `_pq_field_hdr` deltas over 15: the sign edges are
  unreachable from the writer (lengths, counts and field ids are non-negative). Held.
- Page of exactly `fetch_rows`, `fetch_rows` of 1 (every claim and test 51 run it), the empty-range refusal
  in the native type ('9' vs '10'), relation of one heap and of several, composite and array control
  columns refused: read and (for 51's shapes) relied on the test file's own witnesses. Held.
- Object keys with ` `, `+`, `%`, `&`, `?`, `#`, `"`, `'` and a non-ASCII byte in two path segments PUT,
  GET back byte-identical and DELETE through the signers. Held.
- `_object_stem('id', ...)` keeps the text whole, so `10000`, `10000.0` and `1e4` are three keys for one
  chunk lo (hypothesis H2 below): no overwrite, nothing lost.

## operator error

- `archive.configure`: `p_part_bytes` at 0, negative, 5 MiB - 1; `p_fetch_rows` at 0 and negative; a
  non-managed parent; nulls: refused where the value is chosen, as documented. Held.
- `p_endpoint` with a trailing slash is accepted and every PUT then fails with MinIO's 400 at
  `//bucket/key`: claim F19-02. The same class, not claimed separately: a `p_prefix` with a leading `/`, an
  empty `p_region`, a bucket with a trailing slash (each fails at the store, none refused at configure).
- `archive.to_s3` with a schema-qualified `p_child`: refused with the message that names the rule. A direct
  strategy call with swapped bounds: refused as inverted. `unconfigure` mid-export: the export keeps the row
  it read. Hand-nulling `object_key_claim.rows_digest`: the re-run is refused, as documented. Held.

## failure injection

- `archive.to_s3`'s two handlers (the `when others` of the export block and the outer `query_canceled`)
  and `_s3_abort_uploads_at`'s paging: read against tests 24 and 28; the id-less initiate window
  (`v_initiating`) and the abort-by-key path are covered there. The type probe's `when others` swallows
  only what reaches it; `_resolve_child`'s LOCK TABLE needs SELECT first, so I found no non-type error that
  can reach it (hypothesis H4). Held, by reading.
- A strategy PUT that fails rolls back the claim and the digest; a tick that fails after the PUT and before
  its ledger row leaves an object the next tick is admitted to overwrite (no ledger row at the key). Held.

## contracts versus documentation

- README (`pgpm_archive/README.md`) and reference 2697-2880 held to the code: the key shapes, the oid
  shape, the whole-key claim and its refusal wording, the digest description, the paging rules and the
  allowlist, the `part_bytes`/`fetch_rows` refusals, the Parquet type list and the timestamp annotations,
  the null-argument paragraph. The README's and reference's `char(n)`/`bit(n)` promise is the one the code
  does not keep (F19-01). Documented statements typed and run: `archive.configure(regclass-from-text,
  bucket)`, `set_archive_fn(... ::regprocedure)`, `archive.to_s3(parent, child, '2024-01-01', '2024-02-01')`.

## Hypotheses (no reproduction)

- H1. `_pq_encode_column_data`'s `array_json` branch and `_encode_upload_ndjson_single`'s row text render an
  `interval[]` / `interval` by the session's IntervalStyle and a `timestamptz[]` in the session zone, so
  the bytes of one chunk depend on who ticked it (pinned: only extra_float_digits). The values read back
  the same, so this is a reproducibility gap, not a wrong value.
- H2. `_object_stem('id', p_lo)` keeps the text whole, so a direct call spelling a recorded chunk's lo
  with a scale (`10000.0`) lands on a key the ledger does not record and is admitted: a duplicate object, not
  an overwrite. The reference's "compared as the grid's native type" holds for the range check, not the key.
- H3. `archive.to_s3`'s type-probe `exception when others` reports any error of the probe as "cannot page
  by"; a reader that lacks SELECT on the child is stopped by `_resolve_child`'s LOCK first, so I found no
  input that reaches the handler with a non-type error.
- H4. `_refuse_recorded_chunk_overwrite` refuses a re-run after a column rename or ADD COLUMN on the parent
  (the digest's JSON keys change): a safe refusal of a legitimate re-run, with a message that blames the
  rows rather than the shape.

## Round 2

Built: H4 as F19-04 (Tier 3, contracts versus documentation): after `ALTER TABLE ... ADD COLUMN` on the
parent, the documented re-run of a live, write-blocked chunk (its own [lo, hi), rows unchanged, ledgered
by a real maintain() tick) is refused by `_refuse_recorded_chunk_overwrite` because `_row_digest` hashes
the row's JSON text with its column names; the message blames the rows. Reproduced in `f19_b` (dropped).
Not built: H1 (session-style interval/timestamptz[] text in a chunk's bytes): the values read back the
same, so no assertion fails on the tree for a wrong value; left as a hypothesis. H2 (an id-kind lo spelled
with a scale lands on a second key): a duplicate object, nothing overwritten or lost; not a defect to
assert. H3 (the type probe's `when others`): no input found that reaches the handler with a non-type error
(`_resolve_child`'s LOCK TABLE needs SELECT first), so not reproducible. None of the four hypotheses has
one of the six long-surviving shapes, and the slice has no mechanical pre-pass.
