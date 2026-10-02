# pgpm_archive

Archives a `pg_partition_magician`-managed table's aged partitions to S3 (or any S3-compatible
store) before `pgpm.retain()` drops them. Optional: `pgpm_core` has zero dependency on this
module.

## Install

```bash
psql "$DATABASE_URL" -f pgpm_core/install.sql
psql "$DATABASE_URL" -f pgpm_archive/install.sql
```

Store your S3 credentials in [Vault](https://supabase.com/docs/guides/database/vault), once, as a
privileged role (the caller needs `select` on `vault.decrypted_secrets` to read them back):

```sql
select vault.create_secret('AKIAIOSFODNN7EXAMPLE',                     's3_archive_access_key_id');
select vault.create_secret('wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 's3_archive_secret_access_key');
```

Then, per table, set connection settings and turn on automatic archiving:

```sql
select archive.configure('public.events', 'my-archive-bucket');   -- region/endpoint/prefix/etc. all default sanely
select pgpm.set_archive_fn('public.events',
  'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);   -- or archive_to_s3_ndjson
```

That's it: `pgpm.maintain()` now archives every eligible partition automatically, in bounded
chunks, and `pgpm.retire()` won't drop one until it's fully archived. `archive.configure`'s other
parameters (`p_region`, `p_endpoint` for S3-compatible stores like MinIO or Supabase Storage,
`p_prefix`, `p_compress`, etc.) all have sensible defaults -- pass only what you need to override.
`p_part_bytes` (the size of each `archive.to_s3` multipart part, 8 MiB by default) must be at least
5 MiB, the smallest non-final multipart part S3 accepts: `archive.configure` refuses anything smaller,
and `archive.to_s3` refuses a row holding zero or less before it sends anything. A positive size under
5 MiB written into the row by hand is not refused there: an export that fits in one part succeeds, and
one that needs more fails at complete with `EntityTooSmall`, its upload aborted and nothing written. `p_fetch_rows` (rows
per page, 20000 by default) must be at least 1, refused the same way by both.

Each chunk the automatic path archives lands at `<prefix><schema>.<table>_<stem>.ndjson` (or `.parquet`),
the stem being the chunk's `lo` (`2024010100000000` for 2024-01-01 00:00 UTC, `2024010100000000BC` for the
same day BC). A key is never reused by a different relation: if a new table later takes the name of one
that archived under the same prefix (after a drop and `pgpm.forget_missing()`, or a rename), its chunks
carry its oid, `<prefix><schema>.<table>.<oid>_<stem>.ndjson`, and the first table's objects are left as
they are. See the [reference](../docs/reference.md#real-s3-archive-strategies) for the full layout.

## Automatic vs. manual

|             | Automatic                                       | Manual                                                                |
|-------------|-------------------------------------------------|-----------------------------------------------------------------------|
| Turn on     | `pgpm.set_archive_fn(parent, fn)`, once         | nothing to set up                                                     |
| Runs        | every `pgpm.maintain()` tick, in bounded chunks | whenever you call it                                                  |
| Drop safety | `pgpm.retire()` waits until fully archived      | your own script's responsibility                                      |
| Call        | --                                              | `archive.to_s3(parent, child, lo, hi)` / `archive.to_s3_parquet(...)` |

Automatic is the normal way to use this module. Manual exists for a one-off archive or a workflow
that doesn't want pgpm's own drop-gating; call it, then drop the partition however you like:

```sql
select archive.to_s3('public.events', 'events_p2024_01', '2024-01-01', '2024-02-01');
select pgpm.retire('public.events', 'events_p2024_01');
```

The object is named after the partition with its parent's schema: `<prefix>public.events_p2024_01.ndjson`
here (`.ndjson.gz` compressed), and `<prefix><schema>.<child>.parquet` from `archive.to_s3_parquet`, so
same-named tables in two schemas can share a prefix.

`archive.to_s3` reads the partition in pages and, before writing the object, checks that the rows it
paged are the rows the partition holds after the last page: the same count and the same content
fingerprint (a sum of 64-bit hashes of each exported line), so writes that cancel in a count, such as
one row moved behind the paging cursor and another ahead of it, are caught too. On a mismatch it
raises `pg_partition_magician: archive.to_s3 of ... paged N rows but the partition holds M ...` (or
`... paged N rows and the partition holds N, but not the same rows ...`) and writes nothing (an
in-flight multipart upload is aborted), so an object that does land holds exactly the partition's
rows. The only thing that trips it is a write to the partition during the export: run it against a
partition nothing is still writing to, then drop. The check reads the partition once more after the
last page, which costs about one more pass over it. The multipart abort runs whatever ends an export, an error or
a cancel (`statement_timeout`, `pg_cancel_backend`), and the error or cancel still reaches the caller.
One that lands inside the request that starts the upload, before the store's answer arrives, leaves no
upload id to abort by, so the export then aborts every upload in flight at its own object key (at
exactly that key, never one it is a prefix of); a second session exporting the same object at the same
moment would lose its upload and fail. That sweep reads every page of the store's listing.

Both manual functions resolve `child` in the parent's schema, never through your session's
`search_path`, and verify its identity the same way the automatic path does before reading it: if
the name no longer resolves to the relation pgpm recorded for that partition, the call fails with a
`pg_partition_magician:` error naming both oids and uploads nothing. A `child` that does not exist
in the parent's schema is refused too, with a `pg_partition_magician:` error saying so, even when a
same-named relation is visible through `search_path`.

See the [reference](../docs/reference.md#archive-strategy-contract) for the full `archive_fn`
contract and the [guide](../docs/guide.md#archiving-before-a-drop) for the operator's view.

## NDJSON or Parquet

- **NDJSON** (`pgpm.archive_to_s3_ndjson` / `archive.to_s3`): universal, human-readable, round-trips
  any column type. The object is UTF-8 whatever the database's server encoding. A `float8` or `float4`
  is written as the shortest text that reads back as exactly the stored value (`0.30000000000000004`,
  not `0.3`), whatever `extra_float_digits` the archiving session has: the encoders pin it, as the
  Parquet writer does for an array column's JSON text.
- **Parquet** (`pgpm.archive_to_s3_parquet` / `archive.to_s3_parquet`): columnar, directly queryable
  by DuckDB, Athena, Redshift Spectrum, Spark, Trino, and Snowflake with no conversion step -- a
  from-scratch, zero-dependency writer with real limits (see below).

GZIP compression applies to either format (`archive.config.compress`, off by default). With it on, an
NDJSON object takes the `.ndjson.gz` suffix and Content-Type `application/gzip`: `archive.to_s3`
writes `<prefix><schema>.<child>.ndjson.gz` (nothing at the plain key) and the automatic strategy adds the same
suffix to its own keys. A large `archive.to_s3` export is a stream of gzip members, one per
`part_bytes` of NDJSON, which `gunzip`, `zcat`, Python's `gzip`, DuckDB and Hadoop all read as one
file. A Parquet object keeps its `.parquet` name and compresses its pages internally. It's not
free: real compression time runs from ~50ms/MB on compressible data up to ~2.6s/MB on
near-incompressible data. On the automatic `archive_fn` path this compounds with
`pgpm.config.archive_byte_budget` (the per-tick chunk size) with no timeout of its own -- see
[Byte-budget chunked archiving](../docs/reference.md#byte-budget-chunked-archiving) before raising
the budget past a few MiB with compression on.

## Limits

- **Parquet supports eleven types**: `int4`, `int8`, `float8`, `boolean`, `text`,
  `timestamp`/`timestamptz`, `uuid` (as fixed-size binary, not a typed UUID -- readers get the raw
  16 bytes), `json`/`jsonb` (as text, tagged as JSON), and `numeric(p,s)` as a real DECIMAL --
  `numeric` with no declared precision/scale is refused, since Parquet DECIMAL needs one fixed
  precision/scale for the whole column. Parquet requires `0 <= scale <= precision`, and PostgreSQL 15
  and later accept columns outside that, so two shapes are declared differently with every value
  unchanged: a negative scale, `numeric(p,-k)`, is written as `DECIMAL(p+k, 0)` (its values are whole
  multiples of `10^k`), and a scale above the precision, `numeric(p,s)` with `s > p`, as
  `DECIMAL(s, s)`. `NaN`, also legal in `numeric(p,s)`, has no DECIMAL form and is written as null (a
  `NOT NULL` column holding one is declared optional in that file); the NDJSON formats keep it as
  `"NaN"`. PostgreSQL enums are UTF-8 strings; arrays are JSON-tagged
  strings because this flat writer does not emit Parquet's nested `LIST` structure. Array dimensions
  and non-default lower bounds are not preserved. Composite types are refused outright. One row group,
  no dictionary encoding, no statistics.
- **Timestamps**: `timestamptz` is an instant, written as microseconds since the Unix epoch and
  annotated `TIMESTAMP(isAdjustedToUTC=true)` beside the legacy `TIMESTAMP_MICROS`, so DuckDB and
  pyarrow read it as an instant and show it in their own zone. `timestamp`
  (without time zone) is a wall clock with no instant of its own: it is written as that wall clock
  read as if it were UTC and annotated `TIMESTAMP(isAdjustedToUTC=false)` beside the legacy
  `TIMESTAMP_MICROS`, the pair pyarrow itself writes for a naive timestamp, so DuckDB and pyarrow
  give back the same wall clock the NDJSON path emits, whatever `TimeZone` the archiving session ran
  under. A reader that predates Parquet's logical types sees only `TIMESTAMP_MICROS` and shows that
  wall clock labelled UTC. `infinity` and `-infinity`, legal in both types, are written as INT64 max
  and minus INT64 max, the pair DuckDB reads back as `infinity` and `-infinity`; pyarrow gives back
  the two integers. PostgreSQL's range runs about 30 years past 294247-01-10 04:00:54.775806 UTC, the
  last instant INT64 microseconds since 1970 can hold below that sentinel, so a finite value after it
  is written as that instant (INT64 max minus 1, the largest timestamp DuckDB reads back as finite):
  it is archived, and stays finite and in order, but at the ceiling rather than its own value.
- **Payload size**: `archive.to_s3` (NDJSON) streams through S3 multipart in bounded memory once a
  partition exceeds one ~8MiB part, so it handles any size. `archive.to_s3_parquet` has no
  multipart path and would not benefit from one -- a Parquet file's footer needs every row group's
  byte offset, known only once the whole file is built, so the encoder already holds the entire
  file in memory (Postgres's ~1GB cap) before any upload starts. For a partition whose Parquet
  encoding would exceed that, use the [automatic path](#automatic-vs-manual) instead:
  `config.archive_fn` chunks by `config.archive_byte_budget` (default 8 MiB), independent of
  partition size, so no single chunk's encoder input scales with partition size. That budget sizes
  a **row count**, not the uploaded file: it estimates the average on-disk row size
  (`pg_column_size`, sampled) and picks roughly `archive_byte_budget / that average` rows per
  chunk, so an 8 MiB budget does not mean 8 MiB Parquet files -- the actual upload is the *encoded*
  (and, with `compress` on, *GZIP-compressed*) size of those rows, which is usually smaller than
  the budget and never exactly equal to it. See
  [Byte-budget chunked archiving](../docs/reference.md#byte-budget-chunked-archiving) for the row
  math and the compression cost that scales with it.
- **Concurrent writes**: a Parquet file is written from one snapshot. The encoder reads every column
  from a single materialisation taken in one statement, so a row that commits while the file is
  being built is either wholly in it or wholly out of it, never in some columns and not others, and
  the `rows_archived` the automatic path records is the row count of that same snapshot. What
  decides whether such a row is in or out is the write fence, and only the automatic path has one:
  `pgpm.maintain()` write-blocks a partition before archiving it, so nothing can commit into it
  mid-encode. The manual `archive.to_s3_parquet` (and `archive.to_s3`) has no fence at all: a row
  that commits after the snapshot is simply not in the file, and the drop you run afterwards takes
  it with the partition. Quiesce the partition first (a `pgpm_write_block`-style trigger, or stop the
  writer), or use the automatic path.
- **On Supabase**: Storage enforces the project's upload size limit (default 50MB) on the S3
  protocol too, and `statement_timeout` is 2 minutes -- both apply to a single manual call. The
  automatic path's chunking keeps each upload well under both.

## Testing

```bash
./test.sh archive
```

Brings up a MinIO service and a `pgsql-http`-enabled PostgreSQL 17 image (see the root
[`ONBOARDING.md`](../ONBOARDING.md)) and runs `tests/archive/db/*.sql` against it, then
`scripts/verify_parquet.py`/`verify_parquet_range.py` (independent-reader pyarrow + DuckDB
verification) against the same instance.
