-- =============================================================================
-- pg_partition_magician :: archive  --  archive a managed table's aged
-- partitions to S3 before retention drops them, config-driven.
--
-- OPTIONAL add-on, loaded ON TOP of the core (pgpm_core/install.sql). See
-- README.md in this directory for the front door. pgpm's own core has zero
-- dependency on this schema; nothing here is required for ordinary
-- partitioning.
--
-- Two ways to use it, both reading connection settings (bucket/region/
-- endpoint/prefix/vault key names/compress) from archive.config, the one
-- config surface both share:
--   - The archive_fn strategies (pgpm.archive_to_s3_ndjson / archive_to_s3_parquet,
--     in the pgpm schema, not archive -- they are pgpm_core contract implementations
--     that happen to live in this optional module): pgpm.set_archive_fn(parent, one
--     of them) and pgpm.maintain()'s own byte-budget chunking (pgpm._archive_step,
--     pgpm.archive_ledger) drives archiving automatically, ahead of every drop.
--     This is the normal way to use this module.
--   - The synchronous functions (archive.to_s3 / archive.to_s3_parquet): archive a
--     partition INLINE, called directly, holding the vacuum horizon for the whole
--     read-and-upload. No ledger, no automatic scheduling -- call one yourself
--     before dropping a partition another way.
--
-- The old paced worker (archive.tick(), archive.config's boundary_rule/drop_trigger/
-- format knobs, archive.file_gate, and pgpm.hook, the pre_drop registry it and the
-- synchronous functions used to register through) existed to do by hand what
-- pgpm.maintain()'s archive_fn path now does natively; it was deleted once that path
-- was proven out (issue #240), and its archive.configure/schedule operator interface
-- went with it. archive.configure/unconfigure below are its reintroduced, narrower
-- successor for THIS architecture: connection settings only, no schedule knob (there
-- is nothing left to schedule -- pgpm.maintain()'s own schedule already drives
-- archiving for every managed table).
--
-- Surface (all in the archive schema, except the archive_fn switch/strategies noted below):
--   archive.config                 per-table connection settings; one row per
--                                  managed table using either path above.
--   archive.configure / unconfigure   sets/clears a table's archive.config row.
--   archive.to_s3 / archive.to_s3_parquet     the synchronous functions.
--   pgpm.set_archive_fn             the archive_fn switch (in pgpm_core; sets/clears
--                                  pgpm.config.archive_fn for a table).
--   pgpm.archive_to_s3_ndjson / pgpm.archive_to_s3_parquet   the archive_fn strategies.
-- =============================================================================

create extension if not exists http;
create extension if not exists pgcrypto;
create schema if not exists archive;

-- per-table configuration: one real row per managed table, connection settings only. `create
-- table if not exists` below, mirroring pgpm.config's own idempotent-upgrade shape, so re-running
-- this file is safe.
create table if not exists archive.config (
  parent_table    regclass    primary key,

  -- connection: where this table's archives land
  bucket          text        not null,
  region          text        not null default 'us-east-1',
  endpoint        text,                                    -- null = AWS S3; an
                                                             -- URL for S3-compatible
                                                             -- stores (path prefix
                                                             -- and all)
  prefix          text        not null default 'events/',
  vault_key_id    text        not null default 's3_archive_access_key_id',
  vault_secret    text        not null default 's3_archive_secret_access_key',
  compress        boolean     not null default false,

  -- archive.to_s3's own multipart PUT chunking (the archive_fn strategies don't need this --
  -- pgpm._next_archive_chunk already bounds their read size before they ever run)
  part_bytes      bigint      not null default 8 * 1024 * 1024,
  fetch_rows      int         not null default 20000,

  created_at      timestamptz not null default now()
);
-- the paced worker's knobs and the old archive.ledger's own connection-settings columns are gone
-- (issue #240): boundary_rule/drop_trigger picked which unit to archive and who dropped it,
-- format/byte_budget/probe_sample configured the deleted archive._next_range_byte_budget/
-- archive.archive_range/archive._encode_upload_ndjson_commits. Nothing reads them anymore.
alter table archive.config drop column if exists boundary_rule;
alter table archive.config drop column if exists drop_trigger;
alter table archive.config drop column if exists format;
alter table archive.config drop column if exists byte_budget;
alter table archive.config drop column if exists probe_sample;

-- the old ledger (one row per archived range, written by the paced worker) is gone entirely
-- (issue #240): pgpm.archive_ledger, populated by the archive_fn strategies below via
-- pgpm._archive_step, is its successor.
drop table if exists archive.ledger;

-- Which relation an object-key base belongs to (#822). A key base is everything archive._object_key puts
-- before a chunk's stem, <prefix><schema>.<table> quoted as that function quotes it, and a NAME: a dropped
-- table's name can be taken by a new one, and a renamed table's by another. The first relation to archive
-- under a base claims it here and keeps the key shape it always had; any other relation that computes the
-- same base gets its oid in the key instead (archive._object_key, below), so it can never PUT over an
-- object an earlier relation wrote. Nothing deletes from this table, deliberately: pgpm.forget_missing()
-- deletes a dropped table's pgpm.archive_ledger rows, which leaves the bucket object as the ONLY copy of the
-- rows retire() dropped, and the claim is what still remembers whose that object is.
create table if not exists archive.object_key_owner (
  key_base   text        primary key,
  parent_oid oid         not null,
  claimed_at timestamptz not null default now()
);

-- Which writer a FULL object key belongs to (#890). A base claim above cannot see across the two shapes of
-- key: a chunk's is <base><tail> with tail _<stem><ext>, an export's is <base'><ext> with base' named after
-- the child, and an export of a relation named <table>_<stem> (archive._resolve_child accepts any relation
-- in the parent's schema, tracked or not) spells exactly a chunk key of <table> under a base of its own.
-- Both base claims succeeded and the export PUT over the chunk, the only copy of the rows retire() dropped.
-- So every key is also claimed whole, by its parent and its kind ('chunk' for an archive_fn chunk, 'export'
-- for a synchronous export), and the same parent re-writing the same kind of object at it (a retried chunk,
-- a re-run export) is the only writer that finds it its own. Never deleted, for the reason above.
--
-- relation_oid is the relation whose rows the object holds (#976): the parent itself for a chunk, the
-- exported relation for an export. The parent and the kind alone could not tell a re-run export from the
-- same parent's export of ANOTHER relation (archive._resolve_child accepts any relation in the parent's
-- schema), so after archive.to_s3 of x, DROP TABLE x and a new relation named x, the new x's export read
-- as a re-run and PUT over the first export, the only copy of x's rows. Null on a claim made before the
-- column existed: install records a chunk's (its parent), and an export's is not known, so no export may
-- write over it (archive._record_claim_relations, archive._owned_key).
create table if not exists archive.object_key_claim (
  object_key   text        primary key,
  parent_oid   oid         not null,
  kind         text        not null check (kind in ('chunk', 'export')),
  claimed_at   timestamptz not null default now(),
  relation_oid oid
);
alter table archive.object_key_claim add column if not exists relation_oid oid;

-- Operator interface for archive.config: an upsert with every connection-setting column as a
-- named, defaulted parameter, guarding that p_parent is actually pgpm-managed first -- an operator
-- should never need a raw `insert into archive.config` for normal use. Needed by BOTH paths this
-- module ships (the archive_fn strategies and the synchronous functions), which is exactly why
-- this stays a separate call from pgpm.set_archive_fn: connection settings and the choice to
-- automate archiving are orthogonal.
create or replace function archive.configure(
  p_parent       regclass,
  p_bucket       text,
  p_region       text    default 'us-east-1',
  p_endpoint     text    default null,
  p_prefix       text    default 'events/',
  p_vault_key_id text    default 's3_archive_access_key_id',
  p_vault_secret text    default 's3_archive_secret_access_key',
  p_compress     boolean default false,
  p_part_bytes   bigint  default 8 * 1024 * 1024,
  p_fetch_rows   int     default 20000
) returns void language plpgsql as $$
declare v_prefix_given boolean;
begin
  -- #969: refused before anything is read or written; p_endpoint (null = AWS S3) is not. The prefix is
  -- handed over as whether it was given, never as itself: every object key starts with it, and
  -- scripts/check_archive_object_keys.py reads any call the prefix is handed to as a second place a key
  -- is assembled, which is the rule that keeps every key in archive._owned_key.
  if p_prefix is not null then v_prefix_given := true; end if;
  perform pgpm._refuse_null_arguments('archive.configure', json_build_object(
    'p_parent', p_parent, 'p_bucket', p_bucket, 'p_region', p_region, 'p_prefix', v_prefix_given,
    'p_vault_key_id', p_vault_key_id, 'p_vault_secret', p_vault_secret, 'p_compress', p_compress,
    'p_part_bytes', p_part_bytes, 'p_fetch_rows', p_fetch_rows));
  if not exists (select 1 from pgpm.config where parent_table = p_parent) then
    raise exception 'archive.configure: % is not managed by pgpm; transmute() it first', p_parent;
  end if;
  -- archive.to_s3 fills each multipart part until it holds part_bytes, so a size of zero or less
  -- never reads a row and uploads empty parts until the store refuses part 10001 (issue #594).
  if p_part_bytes <= 0 then
    raise exception 'archive.configure: p_part_bytes must be a positive number of bytes, not %', p_part_bytes;
  end if;
  -- And a positive size under 5 MiB is one the store cannot take: S3 and MinIO refuse every non-final
  -- multipart part under 5 MiB, so an export spanning more than one part uploaded all of them and
  -- then failed at CompleteMultipartUpload with EntityTooSmall (issue #636). Refused here, where the
  -- value is chosen, rather than discovered after the upload.
  if p_part_bytes < 5 * 1024 * 1024 then
    raise exception 'archive.configure: p_part_bytes must be at least 5242880 bytes (5 MiB, the smallest multipart part S3 accepts), not %', p_part_bytes;
  end if;
  -- archive.to_s3 reads each page with LIMIT fetch_rows: 0 reads no page at all (and trips the
  -- conservation check with a message about rows), and a negative one fails on LIMIT (#636).
  if p_fetch_rows < 1 then
    raise exception 'archive.configure: p_fetch_rows must be a positive number of rows, not %', p_fetch_rows;
  end if;
  insert into archive.config
    (parent_table, bucket, region, endpoint, prefix, vault_key_id, vault_secret, compress, part_bytes, fetch_rows)
  values
    (p_parent, p_bucket, p_region, p_endpoint, p_prefix, p_vault_key_id, p_vault_secret, p_compress, p_part_bytes, p_fetch_rows)
  on conflict (parent_table) do update set
    bucket = excluded.bucket, region = excluded.region, endpoint = excluded.endpoint,
    prefix = excluded.prefix, vault_key_id = excluded.vault_key_id, vault_secret = excluded.vault_secret,
    compress = excluded.compress, part_bytes = excluded.part_bytes, fetch_rows = excluded.fetch_rows;
end;
$$;

-- Deletes a table's connection settings, idempotent. Does not touch pgpm.config.archive_fn (see
-- pgpm.set_archive_fn) or drop anything already archived.
create or replace function archive.unconfigure(p_parent regclass)
returns void language plpgsql as $$
begin
  -- #969: a null p_parent deleted nothing and reported nothing, as if the settings were gone
  perform pgpm._refuse_null_arguments('archive.unconfigure', json_build_object('p_parent', p_parent));
  delete from archive.config where parent_table = p_parent;
end;
$$;

-- ---------------------------------------------------------------------------
-- Key discovery and S3 transport primitives
-- ---------------------------------------------------------------------------

-- key discovery, shared by every reader that has to order a read spanning more than one child's
-- heap (where ctid is no longer comparable): archive._pq_to_parquet_range, the Parquet range
-- reader, calls this, and orders a keyless relation by its control column alone (#597). Identical contract to pgpm.regrain_step's own v_keyidx/v_pkjoin_q discovery: a PRIMARY KEY
-- preferred, else a predicate/expression-free UNIQUE CONSTRAINT, never a bare UNIQUE INDEX
-- unbacked by a constraint. Returns null for a genuinely keyless relation -- the same 'nokey'
-- contract regrain() already enforces, an inherited limitation, not a new gap. (On a partitioned
-- parent, Postgres itself requires any unique constraint to include every partitioning column, so
-- in practice the control column is always already one of the columns this discovers.)
create or replace function archive._key_columns(p_relation regclass) returns name[]
language plpgsql as $$
declare v_keyidx oid; v_cols name[];
begin
  select coalesce(
           (select i.indexrelid from pg_index i where i.indrelid = p_relation and i.indisprimary limit 1),
           (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
             where con.conrelid = p_relation and con.contype = 'u'
               and i.indpred is null and i.indexprs is null limit 1))
    into v_keyidx;
  if v_keyidx is null then return null; end if;
  select array_agg(a.attname order by k.ord) into v_cols
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indexrelid = v_keyidx;
  return v_cols;
end;
$$;

-- Multipart variant of the archive.to_s3 pre_drop hook: bounded memory for partitions of any size.
-- Three pieces: a URL-encoder, one shared SigV4 request signer (every S3 call signs the same way),
-- and the hook, which streams the partition in part-sized chunks via keyset pagination.

-- RFC 3986 percent-encoding of everything but the unreserved set, byte-wise (UTF-8), as SigV4 requires.
create or replace function archive.s3_url_encode(p_raw text)
returns text language sql immutable as $$
  -- #969: a null encoded to '', so a null key or query value was signed and sent as an empty one
  select pgpm._refuse_null_arguments('archive.s3_url_encode', json_build_object('p_raw', p_raw));
  select coalesce(string_agg(
    case when b.byte in (45, 46, 95, 126)                    -- - . _ ~
           or b.byte between 48 and 57                       -- 0-9
           or b.byte between 65 and 90                       -- A-Z
           or b.byte between 97 and 122                      -- a-z
         then chr(b.byte)
         else '%' || upper(lpad(to_hex(b.byte), 2, '0')) end, '' order by b.i), '')
  from (select get_byte(convert_to(p_raw, 'UTF8'), i) as byte, i
          from generate_series(0, octet_length(convert_to(p_raw, 'UTF8')) - 1) i) b;
$$;

-- The S3 *path* needs per-segment percent-encoding, not whole-string: '/' must stay literal (it
-- separates path segments; AWS's SigV4 spec calls this out explicitly for the S3 canonical URI),
-- while every other reserved character within a segment -- including a literal '"' from a
-- quoted-identifier table name landing in an S3 key, hit in production -- has to be
-- percent-encoded, or the canonical request used for signing diverges from what actually goes
-- out over the wire and S3 replies 403 SignatureDoesNotMatch.
-- An empty key encodes to '' (not null), so a signed request can address the bucket itself, which
-- is where ListMultipartUploads lives (archive._s3_abort_uploads_at).
create or replace function archive._s3_encode_path(p_key text)
returns text language sql immutable as $$
  select coalesce(string_agg(archive.s3_url_encode(seg), '/' order by ord), '')
    from unnest(string_to_array(p_key, '/')) with ordinality as t(seg, ord);
$$;

-- The two extensions this module depends on, pgcrypto (digest, hmac) and http (http, http_set_curlopt,
-- bytea_to_text and the http_* types), are reached through their OWN schemas, read from pg_extension at
-- call time, never through the caller's search_path (#984). The signers below used to call them
-- unqualified in functions that pinned no search_path, so they resolved through whatever path the calling
-- session had: a function hmac(bytea, bytea, text) that any role could create in a schema ahead of
-- pgcrypto's on that path (or a convert_to(text, name) ahead of an explicitly listed pg_catalog) was handed
-- 'AWS4' || <the S3 secret key> and ran with the caller's privileges, a maintain() tick or a pg_cron job
-- among them; and a session whose path did not name the extensions' schema at all (`set search_path = app`)
-- could not resolve http_response, so every archive call failed and the tick logged skip_archive forever.
-- So the signers and these helpers pin search_path to pg_catalog (pg_temp last, so a temporary object can
-- never shadow a builtin either), the function-level SET core's _fk_definition uses, and every extension
-- object is called as <its schema>.<name> with that schema looked up per call: an install-time pin would
-- go stale the day pgcrypto is moved with ALTER EXTENSION ... SET SCHEMA (http cannot be), and leave the
-- old schema named where anyone able to create in it could plant the shadow again. The functions that only receive a
-- response (archive.to_s3 and the rest) name none of the http types any more: they hold it in a record.
create or replace function archive._extension_schema(p_extension name)
returns name language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v_nsp name;
begin
  select n.nspname into v_nsp
    from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid = e.extnamespace
   where e.extname = p_extension;
  if v_nsp is null then
    raise exception 'pg_partition_magician: pgpm_archive needs the % extension, and it is not installed in database %',
      p_extension, current_database();
  end if;
  return v_nsp;
end;
$$;

-- SHA-256 of p_data, and HMAC-SHA256 of p_data under p_key: pgcrypto's digest() and hmac(), called in
-- pgcrypto's own schema (above). p_key of the first HMAC of a signature is 'AWS4' || the secret key.
create or replace function archive._sha256(p_data bytea)
returns bytea language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v_out bytea;
begin
  execute format('select %I.digest($1, %L)', archive._extension_schema('pgcrypto'), 'sha256') into v_out using p_data;
  return v_out;
end;
$$;

create or replace function archive._hmac_sha256(p_data bytea, p_key bytea)
returns bytea language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v_out bytea;
begin
  execute format('select %I.hmac($1, $2, %L)', archive._extension_schema('pgcrypto'), 'sha256') into v_out using p_data, p_key;
  return v_out;
end;
$$;

-- The transport: one signed request, assembled from the http extension's types and sent with its http(),
-- all in the extension's own schema (above). p_body is the payload's bytes, crossed to text at the wire by
-- the extension's bytea_to_text (a raw copy, see archive.s3_signed_request_bytea). Every request this
-- module sends goes through here and nowhere else: the two signers are its only callers (tests/archive/db/39
-- Part 0 starts its scan of the module's S3 requests from this function), and it is the one place a test
-- puts a stand-in for the store (tests/archive/fixtures.sql's mk_transport_standin).
create or replace function archive._s3_send(
  p_method text, p_url text, p_amz_date text, p_payload_hash text, p_auth text, p_ctype text, p_body bytea
) returns http_response language plpgsql set search_path = pg_catalog, pg_temp as $$
declare v_http name := archive._extension_schema('http'); v_resp record;
begin
  execute format('select %I.http_set_curlopt(%L, %L)', v_http, 'CURLOPT_TIMEOUT_MS', '300000');   -- default is 5s; size for real parts
  execute format(
    'select r.* from %1$I.http(($1::%1$I.http_method, $2,'
    ' array[%1$I.http_header(%2$L, $3), %1$I.http_header(%3$L, $4), %1$I.http_header(%4$L, $5)],'
    ' $6, %1$I.bytea_to_text($7))::%1$I.http_request) r',
    v_http, 'x-amz-date', 'x-amz-content-sha256', 'authorization')
    into v_resp using p_method, p_url, p_amz_date, p_payload_hash, p_auth, p_ctype, p_body;
  return v_resp;
end;
$$;

-- One signed S3 request. p_query must already be the CANONICAL query string (keys sorted,
-- keys and values percent-encoded, '' for none); it is used verbatim in both the signature
-- and the URL, so they cannot drift apart.
create or replace function archive.s3_signed_request(
  p_method text, p_endpoint text, p_bucket text, p_region text,
  p_key text, p_query text, p_ctype text, p_payload text,
  p_key_id text, p_secret text
) returns http_response language plpgsql set search_path = pg_catalog, pg_temp as $$   -- #984, above
declare
  v_host text; v_uri text; v_url text;
  v_amz_date text; v_date text; v_payload_hash text; v_scope text;
  v_signed_headers text := 'content-type;host;x-amz-content-sha256;x-amz-date';
  v_canonical text; v_sts text; v_kbin bytea; v_sig text; v_auth text;
begin
  -- #969: refused before anything is signed or sent; p_endpoint (null = AWS S3, virtual-hosted) is not. A
  -- null anywhere else made the URL, the canonical request or the signature null, or sent a request with
  -- an empty body or no credentials. The payload is handed over as its length, null exactly when it is:
  -- a part is megabytes, and its text would be copied into the json for nothing.
  perform pgpm._refuse_null_arguments('archive.s3_signed_request', json_build_object(
    'p_method', p_method, 'p_bucket', p_bucket, 'p_region', p_region, 'p_key', p_key, 'p_query', p_query,
    'p_ctype', p_ctype, 'p_payload', octet_length(p_payload), 'p_key_id', p_key_id, 'p_secret', p_secret));
  if p_endpoint is null then
    v_host := p_bucket || '.s3.' || p_region || '.amazonaws.com';   -- virtual-hosted style
    v_uri  := '/' || archive._s3_encode_path(p_key);
  else
    -- path style (MinIO, Supabase Storage, et al.); the endpoint may carry a path prefix
    v_host := regexp_replace(p_endpoint, '^https?://([^/]+).*$', '\1');
    v_uri  := regexp_replace(p_endpoint, '^https?://[^/]+', '') || '/' || p_bucket || '/' || archive._s3_encode_path(p_key);
  end if;
  v_url := case when p_endpoint is null then 'https://' || v_host || v_uri
                else p_endpoint || '/' || p_bucket || '/' || archive._s3_encode_path(p_key) end
        || case when p_query = '' then '' else '?' || p_query end;

  -- The wall clock, never now(). now() is the transaction's start time, and S3 and MinIO refuse a
  -- request whose x-amz-date is more than 15 minutes from their own clock (403 RequestTimeTooSkewed).
  -- archive.to_s3 signs every part of a multipart export inside one transaction and a maintain()
  -- tick signs every chunk it archives inside one, so a stamp read from now() had every request past
  -- the fifteenth minute refused (#520). The credential scope's date is derived from this same stamp.
  v_amz_date     := to_char(clock_timestamp() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"');
  v_date         := substr(v_amz_date, 1, 8);
  v_payload_hash := encode(archive._sha256(convert_to(p_payload, 'UTF8')), 'hex');
  v_scope        := v_date || '/' || p_region || '/s3/aws4_request';
  v_canonical    := p_method || e'\n' || v_uri || e'\n' || p_query || e'\n'
                 || 'content-type:' || p_ctype || e'\n'
                 || 'host:' || v_host || e'\n'
                 || 'x-amz-content-sha256:' || v_payload_hash || e'\n'
                 || 'x-amz-date:' || v_amz_date || e'\n'
                 || e'\n' || v_signed_headers || e'\n' || v_payload_hash;
  v_sts          := 'AWS4-HMAC-SHA256' || e'\n' || v_amz_date || e'\n' || v_scope || e'\n'
                 || encode(archive._sha256(convert_to(v_canonical, 'UTF8')), 'hex');
  v_kbin := archive._hmac_sha256(convert_to(v_date, 'UTF8'),        convert_to('AWS4' || p_secret, 'UTF8'));
  v_kbin := archive._hmac_sha256(convert_to(p_region, 'UTF8'),      v_kbin);
  v_kbin := archive._hmac_sha256(convert_to('s3', 'UTF8'),          v_kbin);
  v_kbin := archive._hmac_sha256(convert_to('aws4_request', 'UTF8'), v_kbin);
  v_sig  := encode(archive._hmac_sha256(convert_to(v_sts, 'UTF8'), v_kbin), 'hex');
  v_auth := 'AWS4-HMAC-SHA256 Credential=' || p_key_id || '/' || v_scope
         || ', SignedHeaders=' || v_signed_headers || ', Signature=' || v_sig;

  -- The body on the wire is the very bytes v_payload_hash was computed over: the payload's UTF-8
  -- encoding, crossed to text the way the bytea signer below crosses it (bytea_to_text, a raw copy).
  -- The text itself would go out in the SERVER encoding, which is those bytes only in a UTF8 database:
  -- in a LATIN1 one every body holding a non-ASCII character was refused (400
  -- XAmzContentSHA256Mismatch), and the uncompressed NDJSON strategy, which sends a chunk through this
  -- signer, wedged its table on every tick (#728).
  return archive._s3_send(p_method, v_url, v_amz_date, v_payload_hash, v_auth, p_ctype, convert_to(p_payload, 'UTF8'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Transport: a bytea-native SigV4 signer, and the pre_drop hook
-- ---------------------------------------------------------------------------
-- Why a separate signer from archive.s3_signed_request (to-s3.md's multipart
-- variant): that one hashes the payload via digest(convert_to(p_payload, 'UTF8'), 'sha256'),
-- which requires p_payload to be well-formed text in the server encoding. A Parquet file is
-- binary -- its Thrift-encoded footer alone guarantees stray 0x00 and high-bit-set bytes --
-- so convert_to() raises `invalid byte sequence for encoding "UTF8"` on real payloads
-- (verified: it does, on exactly a literal 0x00). This overload hashes the RAW bytea directly
-- (no encoding involved) and only crosses to text at the network boundary, via the http
-- extension's bytea_to_text() -- a raw memcpy reinterpretation of the same bytes, not a
-- re-encode (confirmed from the extension's C source). Verified end-to-end against MinIO:
-- a Parquet payload survives this exact path byte-for-byte and reads back correctly in pyarrow.
create or replace function archive.s3_signed_request_bytea(
  p_method text, p_endpoint text, p_bucket text, p_region text,
  p_key text, p_query text, p_ctype text, p_payload bytea,
  p_key_id text, p_secret text
) returns http_response language plpgsql set search_path = pg_catalog, pg_temp as $$   -- #984, above
declare
  v_host text; v_uri text; v_url text;
  v_amz_date text; v_date text; v_payload_hash text; v_scope text;
  v_signed_headers text := 'content-type;host;x-amz-content-sha256;x-amz-date';
  v_canonical text; v_sts text; v_kbin bytea; v_sig text; v_auth text;
begin
  -- #969: as archive.s3_signed_request's, the payload again handed over as its length
  perform pgpm._refuse_null_arguments('archive.s3_signed_request_bytea', json_build_object(
    'p_method', p_method, 'p_bucket', p_bucket, 'p_region', p_region, 'p_key', p_key, 'p_query', p_query,
    'p_ctype', p_ctype, 'p_payload', octet_length(p_payload), 'p_key_id', p_key_id, 'p_secret', p_secret));
  if p_endpoint is null then
    v_host := p_bucket || '.s3.' || p_region || '.amazonaws.com';
    v_uri  := '/' || archive._s3_encode_path(p_key);
  else
    v_host := regexp_replace(p_endpoint, '^https?://([^/]+).*$', '\1');
    v_uri  := regexp_replace(p_endpoint, '^https?://[^/]+', '') || '/' || p_bucket || '/' || archive._s3_encode_path(p_key);
  end if;
  v_url := case when p_endpoint is null then 'https://' || v_host || v_uri
                else p_endpoint || '/' || p_bucket || '/' || archive._s3_encode_path(p_key) end
        || case when p_query = '' then '' else '?' || p_query end;

  -- the wall clock, as in archive.s3_signed_request above (#520)
  v_amz_date     := to_char(clock_timestamp() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"');
  v_date         := substr(v_amz_date, 1, 8);
  v_payload_hash := encode(archive._sha256(p_payload), 'hex');   -- bytea-native: no encoding involved
  v_scope        := v_date || '/' || p_region || '/s3/aws4_request';
  v_canonical    := p_method || e'\n' || v_uri || e'\n' || p_query || e'\n'
                 || 'content-type:' || p_ctype || e'\n'
                 || 'host:' || v_host || e'\n'
                 || 'x-amz-content-sha256:' || v_payload_hash || e'\n'
                 || 'x-amz-date:' || v_amz_date || e'\n'
                 || e'\n' || v_signed_headers || e'\n' || v_payload_hash;
  v_sts          := 'AWS4-HMAC-SHA256' || e'\n' || v_amz_date || e'\n' || v_scope || e'\n'
                 || encode(archive._sha256(convert_to(v_canonical, 'UTF8')), 'hex');
  v_kbin := archive._hmac_sha256(convert_to(v_date, 'UTF8'),        convert_to('AWS4' || p_secret, 'UTF8'));
  v_kbin := archive._hmac_sha256(convert_to(p_region, 'UTF8'),      v_kbin);
  v_kbin := archive._hmac_sha256(convert_to('s3', 'UTF8'),          v_kbin);
  v_kbin := archive._hmac_sha256(convert_to('aws4_request', 'UTF8'), v_kbin);
  v_sig  := encode(archive._hmac_sha256(convert_to(v_sts, 'UTF8'), v_kbin), 'hex');
  v_auth := 'AWS4-HMAC-SHA256 Credential=' || p_key_id || '/' || v_scope
         || ', SignedHeaders=' || v_signed_headers || ', Signature=' || v_sig;

  -- the one crossing to text, at the wire (bytea_to_text, in archive._s3_send)
  return archive._s3_send(p_method, v_url, v_amz_date, v_payload_hash, v_auth, p_ctype, p_payload);
end;
$$;


-- ---------------------------------------------------------------------------
-- Parquet writer: byte-level primitives, Thrift compact protocol, PLAIN
-- encoding, GZIP compression, struct builders, column-data extraction.
-- Originally built and verified end-to-end (pyarrow + DuckDB) in a standalone
-- prototype before being ported rename-only; that independent-reader
-- verification now runs directly against these functions instead
-- (scripts/verify_parquet.py/verify_parquet_range.py, via ./test.sh archive).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Byte-level primitives
-- ---------------------------------------------------------------------------

create or replace function archive._pq_byte(b int4) returns bytea
language sql immutable as $$
  select set_byte('\x00'::bytea, 0, b);
$$;

create or replace function archive._pq_reverse_bytes(b bytea) returns bytea
language plpgsql immutable as $$
declare
  n int4 := length(b);
  buf bytea := b;
  i int4;
begin
  for i in 0..n-1 loop
    buf := set_byte(buf, i, get_byte(b, n-1-i));
  end loop;
  return buf;
end;
$$;

-- unsigned LEB128 varint; only ever called with non-negative magnitudes in
-- this writer (zigzag output, or a raw non-negative count/length).
create or replace function archive._pq_varint(v bigint) returns bytea
language plpgsql immutable as $$
declare
  n bigint := v;
  buf bytea := ''::bytea;
  b int4;
begin
  if n < 0 then
    raise exception 'archive._pq_varint: negative value % not supported', v;
  end if;
  loop
    b := (n & 127)::int4;
    n := n >> 7;
    if n <> 0 then
      buf := buf || archive._pq_byte(b | 128);
    else
      buf := buf || archive._pq_byte(b);
      exit;
    end if;
  end loop;
  return buf;
end;
$$;

create or replace function archive._pq_zigzag(v bigint) returns bigint
language sql immutable as $$
  select case when v >= 0 then v * 2 else (0 - v) * 2 - 1 end;
$$;

-- ---------------------------------------------------------------------------
-- Thrift compact protocol: field headers, typed field writers, lists, structs
-- ---------------------------------------------------------------------------
-- Compact types used here: BOOLEAN_TRUE=1 BOOLEAN_FALSE=2 (a bool's value rides in the type nibble
-- of its field header; there is no value byte) I32=5 I64=6 BINARY=8 LIST=9 STRUCT=12.

create or replace function archive._pq_field_hdr(p_last_id int4, p_field_id int4, p_ctype int4) returns bytea
language plpgsql immutable as $$
declare
  delta int4 := p_field_id - p_last_id;
begin
  if delta between 1 and 15 then
    return archive._pq_byte((delta << 4) | p_ctype);
  else
    return archive._pq_byte(p_ctype) || archive._pq_varint(archive._pq_zigzag(p_field_id::bigint));
  end if;
end;
$$;

create or replace function archive._pq_stop() returns bytea
language sql immutable as $$
  select archive._pq_byte(0);
$$;

create or replace function archive._pq_write_i32(p_last_id int4, p_field_id int4, p_val int4) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 5) || archive._pq_varint(archive._pq_zigzag(p_val::bigint));
$$;

create or replace function archive._pq_write_i64(p_last_id int4, p_field_id int4, p_val int8) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 6) || archive._pq_varint(archive._pq_zigzag(p_val));
$$;

create or replace function archive._pq_write_bool(p_last_id int4, p_field_id int4, p_val boolean) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, case when p_val then 1 else 2 end);
$$;

create or replace function archive._pq_write_binary(p_last_id int4, p_field_id int4, p_val bytea) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 8) || archive._pq_varint(length(p_val)::bigint) || p_val;
$$;

create or replace function archive._pq_write_struct(p_last_id int4, p_field_id int4, p_val bytea) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 12) || p_val;
$$;

create or replace function archive._pq_list_hdr(p_count int4, p_elem_ctype int4) returns bytea
language plpgsql immutable as $$
begin
  if p_count <= 14 then
    return archive._pq_byte((p_count << 4) | p_elem_ctype);
  else
    return archive._pq_byte((15 << 4) | p_elem_ctype) || archive._pq_varint(p_count::bigint);
  end if;
end;
$$;

create or replace function archive._pq_write_list_struct(p_last_id int4, p_field_id int4, p_elems bytea[]) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 9)
      || archive._pq_list_hdr(coalesce(array_length(p_elems,1),0), 12)
      || coalesce((select string_agg(e, ''::bytea order by ord)
                     from unnest(p_elems) with ordinality as t(e, ord)), ''::bytea);
$$;

create or replace function archive._pq_write_list_i32(p_last_id int4, p_field_id int4, p_elems int4[]) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 9)
      || archive._pq_list_hdr(coalesce(array_length(p_elems,1),0), 5)
      || coalesce((select string_agg(archive._pq_varint(archive._pq_zigzag(e::bigint)), ''::bytea order by ord)
                     from unnest(p_elems) with ordinality as t(e, ord)), ''::bytea);
$$;

create or replace function archive._pq_write_list_binary(p_last_id int4, p_field_id int4, p_elems bytea[]) returns bytea
language sql immutable as $$
  select archive._pq_field_hdr(p_last_id, p_field_id, 9)
      || archive._pq_list_hdr(coalesce(array_length(p_elems,1),0), 8)
      || coalesce((select string_agg(archive._pq_varint(length(e)::bigint) || e, ''::bytea order by ord)
                     from unnest(p_elems) with ordinality as t(e, ord)), ''::bytea);
$$;

-- ---------------------------------------------------------------------------
-- PLAIN encoding (Type physical values; see Encoding.PLAIN doc in the spec)
-- ---------------------------------------------------------------------------

create or replace function archive._pq_plain_int32(v int4) returns bytea
language sql immutable as $$
  select archive._pq_reverse_bytes(int4send(v));
$$;

create or replace function archive._pq_plain_int64(v int8) returns bytea
language sql immutable as $$
  select archive._pq_reverse_bytes(int8send(v));
$$;

-- A timestamp as the INT64 microseconds since the Unix epoch that a TIMESTAMP_MICROS leaf holds, for
-- both column types (a `timestamp` arrives here already read as UTC; see _pq_encode_column_data).
-- 'infinity' and '-infinity' are legal values of both types, the usual "never expires" sentinel, and
-- extract(epoch) returns them as numeric Infinity, which no int8 cast accepts: one such row raised
-- 'cannot convert infinity to bigint' on every encode of its chunk, so maintain() logged skip_archive
-- every tick and at archive_batch 1 nothing younger of the table was archived or retired (#586). They
-- are written as INT64 max and minus INT64 max, the pair DuckDB's reader decodes as infinity and
-- -infinity (INT64 min it decodes as a year-290309 BC date, which is why the negative sentinel is not
-- INT64 min, PostgreSQL's own internal one); pyarrow hands back the same two integers.
--
-- A FINITE value can pass the positive one (#664). PostgreSQL counts from 2000, not 1970, so its range
-- ends in 294276 AD, about 30 years after 294247-01-10 04:00:54.775807 UTC, where INT64 microseconds
-- since 1970 run out. Past that the cast raised 'bigint out of range', the #586 wedge again, and just
-- before the cast overflowed extract(epoch) had already dropped to float8 precision and returned a
-- number below the last exact instant's. So everything past 294247-01-10 04:00:54.775806 UTC (INT64 max
-- minus 1 exactly) is written as INT64 max minus 1: DuckDB's largest finite timestamp, one below the
-- +infinity sentinel, so it stays finite and in order for a reader. The clamp is on the timestamp,
-- before extract, because extract's result is the thing that goes wrong. The far past needs none:
-- PostgreSQL's range starts in 4714 BC, about -2.1e17 microseconds, nowhere near the negative sentinel.
create or replace function archive._pq_epoch_micros(v timestamptz) returns int8
language sql immutable as $$
  select case
    when isfinite(v) then round(extract(epoch from least(v, '294247-01-10 04:00:54.775806+00'::timestamptz)) * 1000000)::int8
    when v > 'epoch'::timestamptz then 9223372036854775807::int8
    else -9223372036854775807::int8
  end;
$$;

create or replace function archive._pq_plain_double(v float8) returns bytea
language sql immutable as $$
  select archive._pq_reverse_bytes(float8send(v));
$$;

create or replace function archive._pq_plain_bytearray(v bytea) returns bytea
language sql immutable as $$
  select archive._pq_reverse_bytes(int4send(length(v))) || v;
$$;

create or replace function archive._pq_plain_text(v text) returns bytea
language sql immutable as $$
  select archive._pq_plain_bytearray(convert_to(v, 'UTF8'));
$$;

-- FIXED_LEN_BYTE_ARRAY(16), no logical-type annotation: the 16 raw bytes uuid_send() already
-- gives (RFC 4122 byte order) are exactly what Parquet's PLAIN encoding wants for a fixed-length
-- type -- no length prefix (unlike BYTE_ARRAY), no byte-order conversion (unlike int32/int64/
-- float8's reverse_bytes). A reader sees fixed-size binary(16), not a typed UUID -- the newer
-- LogicalType.UUID annotation this project doesn't write is optional, not required, for a valid,
-- readable column.
create or replace function archive._pq_plain_uuid(v uuid) returns bytea
language sql immutable as $$
  select uuid_send(v);
$$;

-- Minimal two's-complement byte width that can hold every unscaled integer a numeric(p,*) column
-- can produce: max magnitude is 10^p - 1, so find the smallest n with a signed n-byte range
-- (2^(8n-1) - 1) covering it. Loop, not a lookup table, so it stays correct for any precision
-- Postgres itself allows (up to 1000).
create or replace function archive._pq_decimal_byte_width(p_precision int4) returns int4
language plpgsql immutable as $$
declare
  v_max numeric := (10::numeric ^ p_precision) - 1;
  n int4 := 1;
begin
  while (2::numeric ^ (8*n - 1)) - 1 < v_max loop
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- The (precision, scale) a numeric(p,s) column's Parquet DECIMAL leaf declares, from its atttypmod.
-- Both encoders take the column shape from here and nowhere else, so the leaf, the byte width
-- (_pq_decimal_byte_width over the precision returned) and the unscaled values (_pq_plain_decimal
-- over the scale returned) cannot disagree between them. Parquet requires 0 <= scale <= precision;
-- PostgreSQL 15 and later accept both a negative scale and a scale above the precision, so the
-- declared shape is not always a legal leaf, and each of the two cases below is its own defect.
--
-- The scale is an 11-bit SIGNED field since PostgreSQL 15 (numeric.c's numeric_typmod_scale). It was
-- read as the unsigned low 16 bits, so numeric(5,-2) came out as scale 2046: every value multiplied
-- by 10^2046 and cut to the column's 3-byte width, which is zero for every value since 10^2046 is a
-- multiple of 2^24. The file uploaded and was ledgered as archived with the values destroyed (#567).
-- A negative scale -k means every value is a whole multiple of 10^k with at most p significant
-- digits, so at most p + k digits in all: DECIMAL(p + k, 0) holds each value exactly as itself.
--
-- A scale above the precision, numeric(2,4) holding -0.0099..0.0099, was copied into the leaf as
-- DECIMAL(2,4), which Parquet forbids and pyarrow refuses for the whole file ("Invalid DECIMAL scale 4
-- cannot be greater than precision 2") while the upload and the ledger row succeeded (#596). Its
-- values are below 10^(p-s) <= 1 in magnitude, so their unscaled integers have at most s digits and
-- DECIMAL(s, s) holds them unchanged.
create or replace function archive._pq_decimal_shape(p_typmod int4, out p_precision int4, out p_scale int4)
language plpgsql immutable as $$
declare
  v_precision int4 := ((p_typmod - 4) >> 16) & 65535;
  v_scale int4 := (((p_typmod - 4) & 2047) # 1024) - 1024;
begin
  if v_scale < 0 then
    p_precision := v_precision - v_scale;
    p_scale := 0;
  elsif v_scale > v_precision then
    p_precision := v_scale;
    p_scale := v_scale;
  else
    p_precision := v_precision;
    p_scale := v_scale;
  end if;
end;
$$;

-- Parquet DECIMAL's physical encoding: the unscaled integer (value * 10^scale, exact since numeric
-- arithmetic is exact), two's complement, big-endian, in exactly p_bytes (from
-- _pq_decimal_byte_width, sized to the column's own declared precision so every value fits).
-- Negative values: two's complement of a negative n-byte-wide integer is 2^(8n) + value (value
-- already negative, so this subtracts its magnitude) -- the standard construction, computed exactly
-- in `numeric` since PL/pgSQL has no native bignum-to-bytes primitive to lean on. Encodes from the
-- least-significant byte backward (repeated mod 256 / div 256, the same shape _pq_varint's loop
-- already uses), landing the most-significant byte at index 0 -- big-endian, as the format requires.
-- div()/mod(), not trunc(v / 256) (issue #461): numeric `/` computes its quotient to a BOUNDED number
-- of digits, about 16 significant, and ROUNDS to it, so once the running value has 17 or more integer
-- digits the quotient is rounded to an integer before trunc() sees it and the carry lands in every
-- higher byte. Every negative reaches that magnitude at width 8 through the 2^(8n) step above (2^64
-- has 20 digits), so numeric(17,s) and wider, numeric(19,4) included, encoded -1 as 00000000000000ff.
-- div()/mod() are exact integer operations for numeric at any magnitude, the same reason
-- pgpm._radix_encode uses them.
create or replace function archive._pq_plain_decimal(v numeric, p_scale int4, p_bytes int4) returns bytea
language plpgsql immutable as $$
declare
  v_scaled numeric := round(v * (10::numeric ^ p_scale));
  v_unsigned numeric;
  buf bytea := decode(repeat('00', p_bytes), 'hex');
  i int4;
begin
  v_unsigned := case when v_scaled < 0 then (2::numeric ^ (8*p_bytes)) + v_scaled else v_scaled end;
  for i in reverse (p_bytes-1)..0 loop
    buf := set_byte(buf, i, mod(v_unsigned, 256)::int4);
    v_unsigned := div(v_unsigned, 256);
  end loop;
  return buf;
end;
$$;

create or replace function archive._pq_plain_boolean_array(vals boolean[]) returns bytea
language plpgsql immutable as $$
declare
  n int4 := coalesce(array_length(vals,1),0);
  nbytes int4 := ceil(n/8.0)::int4;
  buf bytea;
  i int4; byte_idx int4; bit_idx int4;
begin
  if n = 0 then
    return ''::bytea;
  end if;
  buf := decode(repeat('00', nbytes), 'hex');
  for i in 1..n loop
    byte_idx := (i-1) / 8;
    bit_idx  := (i-1) % 8;
    if vals[i] then
      buf := set_byte(buf, byte_idx, get_byte(buf, byte_idx) | (1 << bit_idx));
    end if;
  end loop;
  return buf;
end;
$$;

-- Definition levels for an OPTIONAL (nullable) column: a flat, non-nested schema has
-- max_definition_level = 1, so this is a bitmap (1 = present, 0 = null) encoded with the
-- RLE/bit-packed-hybrid encoding, one single bit-packed run covering the whole page,
-- 4-byte-length-prefixed (Data page v1 always prepends the length for levels, per the
-- Encodings.md table). IMPORTANT: the header's varint is a PLAIN unsigned ULEB128
-- (Encodings.md point 2), NOT the Thrift zigzag varint used everywhere else in this file --
-- these are two unrelated encodings that just happen to share the word "varint". At
-- bit_width=1 the "different packing order" the spec calls out collapses to the same
-- LSB-first-per-byte packing archive._pq_plain_boolean_array already uses, so this reuses that shape.
create or replace function archive._pq_definition_levels(is_present boolean[]) returns bytea
language plpgsql immutable as $$
declare
  n int4 := coalesce(array_length(is_present,1),0);
  nbytes int4;
  packed bytea;
  i int4; byte_idx int4; bit_idx int4;
  header bytea;
  encoded_data bytea;
begin
  if n = 0 then
    return archive._pq_reverse_bytes(int4send(0));   -- valid empty hybrid stream: zero-length encoded-data
  end if;
  nbytes := ceil(n/8.0)::int4;
  packed := decode(repeat('00', nbytes), 'hex');
  for i in 1..n loop
    byte_idx := (i-1) / 8;
    bit_idx  := (i-1) % 8;
    if is_present[i] then
      packed := set_byte(packed, byte_idx, get_byte(packed, byte_idx) | (1 << bit_idx));
    end if;
  end loop;
  -- bit-packed-header := varint-encode(<bit-pack-scaled-run-len> << 1 | 1); scaled-run-len is
  -- (bit-packed-run-len)/8, and since every byte here packs exactly 8 values, that's just nbytes.
  header := archive._pq_varint(((nbytes::bigint) << 1) | 1);
  encoded_data := header || packed;
  return archive._pq_reverse_bytes(int4send(length(encoded_data))) || encoded_data;
end;
$$;

-- ---------------------------------------------------------------------------
-- Compression: GZIP (RFC 1952) wrapping a from-scratch DEFLATE (RFC 1951)
-- encoder -- LZ77 matching plus a fixed Huffman code. Originally built and
-- verified end-to-end (pyarrow + DuckDB, including cross-partition ranges) in
-- a standalone prototype before being ported rename-only (pq._* ->
-- archive._pq_*); that verification now runs directly against these
-- functions instead (scripts/verify_parquet.py/verify_parquet_range.py).
-- ---------------------------------------------------------------------------

-- CRC-32/ISO-HDLC (the checksum RFC 1952's gzip trailer requires), table-driven.
create or replace function archive._pq_crc32_table() returns bigint[]
language plpgsql immutable as $$
declare
  tbl bigint[] := array_fill(0::bigint, array[256]);
  c bigint; i int4; j int4;
begin
  for i in 0..255 loop
    c := i;
    for j in 0..7 loop
      if (c & 1) = 1 then c := (c >> 1) # 3988292384;   -- 0xEDB88320
      else c := c >> 1;
      end if;
    end loop;
    tbl[i+1] := c;
  end loop;
  return tbl;
end;
$$;

-- `data` is forced into a fresh, plain (non-TOASTed) copy before the per-byte loop: calling
-- get_byte() repeatedly on a bytea sourced from a real table column is ~1000x slower than the
-- identical loop over a freshly-built local variable (measured: 49s vs 58ms for the same 1MB
-- input) -- PostgreSQL does not cache the detoasted form across calls the way one might expect.
create or replace function archive._pq_crc32(data bytea) returns bigint
language plpgsql as $$
declare
  tbl bigint[] := archive._pq_crc32_table();
  crc bigint := 4294967295;
  v_data bytea := data || ''::bytea;
  n int4 := length(v_data);
  i int4;
begin
  for i in 0..n-1 loop
    crc := tbl[(((crc # get_byte(v_data,i)) & 255) + 1)] # (crc >> 8);
  end loop;
  return crc # 4294967295;
end;
$$;

-- longest k in [0, max_len] with substr(data,a+1,k) = substr(data,b+1,k): a binary search over
-- native substr-equality comparisons (each a C-level memcmp regardless of k), not a byte-by-byte
-- extend loop -- O(log max_len) comparisons instead of O(max_len).
create or replace function archive._pq_lz_match_len(data bytea, a int4, b int4, max_len int4) returns int4
language plpgsql immutable as $$
declare
  lo int4 := 0; hi int4 := max_len; mid int4;
begin
  while lo < hi loop
    mid := (lo + hi + 1) / 2;
    if substr(data, a+1, mid) = substr(data, b+1, mid) then lo := mid; else hi := mid - 1; end if;
  end loop;
  return lo;
end;
$$;

-- reverse the low `nbits` bits of `value`: needed once per Huffman-code insert (bounded at 9
-- bits here), not once per output bit -- see archive._pq_deflate_encode. Distinct from
-- archive._pq_reverse_bytes above (byte-order reversal, not bit-within-a-value reversal).
create or replace function archive._pq_bit_reverse(value int4, nbits int4) returns int4
language plpgsql immutable as $$
declare rev int4 := 0; i int4;
begin
  for i in 0..nbits-1 loop
    rev := rev | (((value >> i) & 1) << (nbits - 1 - i));
  end loop;
  return rev;
end;
$$;

-- DEFLATE-encode `payload` as one final, fixed-Huffman block (RFC 1951 3.2.3/3.2.6). Consumes
-- archive._pq_lz77_tokens's token stream -- the same LZ77 matcher the dynamic-Huffman path uses
-- (see that function for the match-finding strategy, #366) -- rather than keeping a second, inline
-- copy of the matching loop.
--
-- #370: emits fixed-size chunks via `return next` (pre-sized once, filled with set_byte, never
-- grown -- archive._pq_plain_boolean_array's idiom) instead of appending one int4 per OUTPUT byte
-- to a growing v_bytes int4[] and hex-round-tripping it at the end -- that old shape cost 4 bytes
-- of int4[] storage per compressed byte, scaling with compressed OUTPUT size independent of #366's
-- token-count fix. archive._pq_deflate_encode (below) does the final string_agg aggregate over
-- this function's chunk stream, the same "return next, real aggregate downstream" shape
-- archive._pq_lz77_tokens already uses for its own token stream.
create or replace function archive._pq_deflate_encode_chunks(payload bytea)
returns table(chunk bytea)
language plpgsql as $$
declare
  v_tok record;
  v_acc int4 := 0; v_acc_n int4 := 0;
  v_chunk_size constant int4 := 8192;
  v_chunk_empty constant bytea := decode(repeat('00', v_chunk_size), 'hex');
  v_chunk bytea := v_chunk_empty;
  v_chunk_pos int4 := 0;
  v_code int4; v_nbits int4; v_rev int4;
  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;
  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;
  v_dist int4; v_len int4; v_sym int4;
begin
  -- block header: BFINAL=1, BTYPE=01 (fixed Huffman) -- raw, LSB-of-value-first (the OPPOSITE
  -- convention from Huffman codes, which are MSB-of-the-code-first; RFC 1951 3.1.1 splits these
  -- two conventions and it is easy to invert one for the other by accident).
  v_acc := v_acc | (3 << v_acc_n); v_acc_n := v_acc_n + 3;
  while v_acc_n >= 8 loop
    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;
    v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;
  end loop;

  for v_tok in select * from archive._pq_lz77_tokens(payload) loop
    if v_tok.is_match then
      v_len := v_tok.val1;
      v_dist := v_tok.val2;

      -- length code (RFC 1951 3.2.5), inlined rather than a separate lookup function -- see the
      -- section header note on OUT-parameter call overhead.
      case
        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;
        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;
        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;
        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;
        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;
        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;
        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;
      end case;

      -- distance code (RFC 1951 3.2.5), inlined
      case
        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;
        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;
        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;
        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;
        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;
        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;
        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;
        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;
        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;
        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;
        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;
        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;
        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;
        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;
      end case;

      -- length code's literal/length Huffman code (RFC 1951 3.2.6), inlined
      v_sym := v_lcode;
      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;
      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;
      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;
      else v_code := 192+(v_sym-280); v_nbits := 8;
      end if;
      v_rev := archive._pq_bit_reverse(v_code, v_nbits);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
      while v_acc_n >= 8 loop
        v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;
        v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
        if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;
      end loop;

      if v_lextra_bits > 0 then
        v_acc := v_acc | (v_lextra_val << v_acc_n); v_acc_n := v_acc_n + v_lextra_bits;
        while v_acc_n >= 8 loop
          v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;
          v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
          if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;
        end loop;
      end if;

      -- distance code: fixed 5-bit Huffman, identity-mapped (RFC 1951 3.2.6)
      v_rev := archive._pq_bit_reverse(v_dcode, 5);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 5;
      while v_acc_n >= 8 loop
        v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;
        v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
        if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;
      end loop;

      if v_dextra_bits > 0 then
        v_acc := v_acc | (v_dextra_val << v_acc_n); v_acc_n := v_acc_n + v_dextra_bits;
        while v_acc_n >= 8 loop
          v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;
          v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
          if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;
        end loop;
      end if;
    else
      v_sym := v_tok.val1;
      if v_sym <= 143 then v_code := 48+v_sym; v_nbits := 8;
      elsif v_sym <= 255 then v_code := 400+(v_sym-144); v_nbits := 9;
      elsif v_sym <= 279 then v_code := v_sym-256; v_nbits := 7;
      else v_code := 192+(v_sym-280); v_nbits := 8;
      end if;
      v_rev := archive._pq_bit_reverse(v_code, v_nbits);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
      while v_acc_n >= 8 loop
        v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;
        v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
        if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;
      end loop;
    end if;
  end loop;

  -- end-of-block (symbol 256): 7-bit code, value 0
  v_rev := archive._pq_bit_reverse(0, 7);
  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + 7;
  while v_acc_n >= 8 loop
    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;
    v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8;
    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;
  end loop;
  if v_acc_n > 0 then   -- pad final byte
    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;
    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;
  end if;

  if v_chunk_pos > 0 then
    chunk := substr(v_chunk, 1, v_chunk_pos); return next;
  end if;
  return;
end;
$$;

create or replace function archive._pq_deflate_encode(payload bytea) returns bytea
language sql as $$
  select coalesce((select string_agg(chunk, ''::bytea) from archive._pq_deflate_encode_chunks(payload)), ''::bytea);
$$;

-- the full RFC 1952 gzip container Parquet's GZIP codec expects (confirmed empirically: a real
-- pyarrow-written GZIP-compressed Parquet file's page bytes open with the 1f8b gzip magic and
-- read cleanly via Python's stdlib gzip reader end to end, not a bare zlib/RFC-1950 stream) --
-- 10-byte header, the DEFLATE stream, then a CRC-32 + ISIZE trailer over the ORIGINAL
-- (uncompressed) bytes.
create or replace function archive._pq_gzip_compress(payload bytea) returns bytea
language plpgsql as $$
declare
  v_deflate bytea := archive._pq_deflate_encode(payload);
  v_header bytea := decode('1f8b08000000000000ff', 'hex');
  v_crc bigint := archive._pq_crc32(payload);
  v_isize bigint := length(payload) & 4294967295;
  v_trailer bytea;
begin
  v_trailer := archive._pq_reverse_bytes(int4send((v_crc - 4294967296 * (v_crc >> 31))::int4))
            || archive._pq_reverse_bytes(int4send((v_isize - 4294967296 * (v_isize >> 31))::int4));
  return v_header || v_deflate || v_trailer;
end;
$$;

-- ---------------------------------------------------------------------------
-- Dynamic Huffman coding (issue #206), step 1 of 2: canonical code lengths and
-- code assignment (RFC 1951 3.2.2). archive._pq_gzip_compress above (fixed-Huffman)
-- stays defined and directly callable -- a valid, simpler, slightly cheaper-to-run
-- rung, kept rather than deleted -- but every GZIP call site this module drives on
-- its own (archive._pq_to_parquet, archive._pq_to_parquet_range,
-- archive._encode_upload_ndjson_single) now calls archive._pq_gzip_compress_dynamic
-- (below) instead: a pre-build measurement (reimplementing this project's own LZ77
-- matcher, cross-checked against real zlib's Z_FIXED vs default strategy) put the
-- expected win at ~20-30% additional size reduction over fixed Huffman on realistic
-- PLAIN-encoded column data, confirmed end to end afterward (both pyarrow and DuckDB
-- reading real compressed Parquet files, 24-35% smaller in the cases measured) --
-- strictly better compression for a modest extra cost building the per-block tree,
-- with no config surface added and nothing for an operator to opt into.
-- ---------------------------------------------------------------------------

-- Standard Huffman code-length construction, then length-limited to p_max_bits
-- (DEFLATE's own cap is 15). p_freqs is a 1-based array indexed by symbol+1
-- (i.e. p_freqs[i] is symbol i-1's frequency); returns an array of the same
-- shape, 0 for any symbol with zero frequency (unused, no code assigned).
--
-- Construction: repeatedly merge the two lowest-frequency groups (ties broken
-- by insertion order, ascending); every symbol in EITHER merged group gets +1
-- code length per merge -- one more bit to distinguish left vs right below it.
-- This reads code lengths straight off the merge sequence without building an
-- explicit tree.
--
-- Length limiting: clamp any length exceeding p_max_bits down to it (folding the
-- overflow into a bit-length histogram, bl_count[L] = how many symbols have
-- length L), then repeatedly repair the histogram -- move one leaf from the
-- shortest length still below the cap down to length+1 (which needs a new
-- sibling to stay a valid full binary tree, so that bucket gains TWO, not
-- one) and consume one unit of the max_bits overflow -- until total weight
-- (sum of bl_count[L] * 2^(p_max_bits-L), exact integer arithmetic throughout,
-- no floating point) lands EXACTLY on 2^p_max_bits. Finally reassigns actual
-- per-symbol lengths from the repaired histogram, longest-original-length
-- symbols first, so a symbol the unbounded tree considered rarer never ends
-- up shorter than one it considered more common.
--
-- This always terminates and always succeeds for any alphabet size <=
-- 2^p_max_bits (true here with room to spare: DEFLATE's litlen/dist alphabets
-- are 286/30 symbols against a 15-bit cap), since assigning every symbol
-- p_max_bits alone already satisfies Kraft with room left over. Landing on
-- an EXACTLY complete code (not just Kraft <= 1) matters in practice, not
-- just in theory: real DEFLATE decoders (confirmed against real zlib) reject
-- an incomplete multi-symbol code outright -- an earlier version of this
-- function used a floating-point Kraft comparison and a "lengthen the
-- shortest code" loop that could silently converge to an INCOMPLETE code
-- (there is no guarantee that repeatedly halving one term lands exactly on
-- the target rather than overshooting past it), and zlib's own decompressor
-- caught it immediately on real column data (a float8 price column) with
-- "invalid code lengths set" -- the bug this histogram-based repair fixes.
-- Verified against a 27-symbol Fibonacci-weighted worst case, the classic
-- adversarial input for unbounded Huffman (unbounded construction hits depth
-- 26 for 27 symbols; the length-limited pass correctly caps it to 15 with an
-- exactly complete code), and 2000+ randomized trials across uniform,
-- geometric, spiky, and Fibonacci frequency shapes at both real DEFLATE
-- alphabet sizes (286, 30) and smaller ones, all landing on an exactly
-- complete code within the requested cap.
create or replace function archive._pq_huffman_lengths(p_freqs bigint[], p_max_bits int default 15)
returns int4[]
language plpgsql as $$
declare
  n int4 := array_length(p_freqs, 1);
  v_lengths int4[] := array_fill(0, array[n]);
  i int4;
  v_node_id int4 := 0;
  v_ncount int4;
  v_id1 int4; v_id2 int4;
  v_f1 bigint; v_f2 bigint;
  v_freq bigint[];
  v_alive boolean[];
  v_group int4[];
  v_j int4;
  v_max_len int4;
  v_bl_count int4[];
  v_overflow int4;
  v_bits int4;
  v_weight bigint;
  v_target bigint;
  v_order int4[];
  v_new_lengths int4[];
  v_idx int4;
  v_l int4;
begin
  -- The merge queue lives in local arrays, indexed by node id: v_freq and v_alive per node, and
  -- v_group[symbol] = the node that currently holds it (0 = unused). It used to be a temp table
  -- created and dropped on every call, three calls per GZIP encode, and a dropped relation's locks
  -- are held to transaction end: ~15 shared lock-table entries per call, so one maintain() tick
  -- archiving enough compressed chunks exhausted the cluster's lock table (issue #587). Arrays take
  -- no lock at all. Node ids are handed out in the same order the table's were and the minimum is
  -- the same (freq, node_id), so the merge sequence, and every code, is unchanged.
  v_freq := array_fill(0::bigint, array[2 * n]);
  v_alive := array_fill(false, array[2 * n]);
  v_group := array_fill(0, array[n]);
  for i in 1..n loop
    if p_freqs[i] > 0 then
      v_node_id := v_node_id + 1;
      v_freq[v_node_id] := p_freqs[i];
      v_alive[v_node_id] := true;
      v_group[i] := v_node_id;
    end if;
  end loop;

  v_ncount := v_node_id;

  -- a length-limited prefix code for v_ncount symbols can only ever exist if
  -- v_ncount <= 2^p_max_bits (Kraft's inequality's own ceiling: v_ncount codes of
  -- exactly p_max_bits each already sum to v_ncount * 2^-p_max_bits, which must be
  -- <= 1). Never reachable from a real DEFLATE call (max_bits is always 15 there,
  -- alphabets max out at 286) -- guarded so a misuse fails loudly instead of
  -- infinite-looping in the Kraft-restore pass below.
  if v_ncount > power(2, p_max_bits)::bigint then
    raise exception 'archive._pq_huffman_lengths: % distinct symbols cannot fit a %-bit-limited prefix code (needs <= % symbols)',
      v_ncount, p_max_bits, power(2, p_max_bits)::bigint;
  end if;

  if v_ncount = 0 then
    return v_lengths;
  end if;

  if v_ncount = 1 then
    v_lengths[array_position(v_group, 1)] := 1;
    return v_lengths;
  end if;

  while v_ncount > 1 loop
    -- the two live nodes with the smallest (freq, node_id): scanning ids in ascending order and
    -- replacing only on a strictly smaller freq keeps the lower id on a tie.
    v_id1 := null; v_id2 := null;
    for v_j in 1..v_node_id loop
      if v_alive[v_j] then
        if v_id1 is null or v_freq[v_j] < v_f1 then
          v_id2 := v_id1; v_f2 := v_f1;
          v_id1 := v_j; v_f1 := v_freq[v_j];
        elsif v_id2 is null or v_freq[v_j] < v_f2 then
          v_id2 := v_j; v_f2 := v_freq[v_j];
        end if;
      end if;
    end loop;

    v_node_id := v_node_id + 1;
    v_freq[v_node_id] := v_f1 + v_f2;
    v_alive[v_node_id] := true;
    v_alive[v_id1] := false;
    v_alive[v_id2] := false;
    for i in 1..n loop
      if v_group[i] = v_id1 or v_group[i] = v_id2 then
        v_lengths[i] := v_lengths[i] + 1;
        v_group[i] := v_node_id;
      end if;
    end loop;

    v_ncount := v_ncount - 1;
  end loop;

  -- v_lengths now holds the UNBOUNDED assignment (always exactly complete: Kraft
  -- == 1 exactly, guaranteed by the merge construction above). Length-limit it.
  select max(v_lengths[gs]) into v_max_len from generate_series(1, n) gs;

  v_bl_count := array_fill(0, array[greatest(v_max_len, p_max_bits)]);
  for i in 1..n loop
    if v_lengths[i] > 0 then
      v_bl_count[v_lengths[i]] := v_bl_count[v_lengths[i]] + 1;
    end if;
  end loop;

  v_overflow := 0;
  for v_l in (p_max_bits + 1)..greatest(v_max_len, p_max_bits) loop
    v_overflow := v_overflow + v_bl_count[v_l];
  end loop;
  v_bl_count := v_bl_count[1:p_max_bits];
  v_bl_count[p_max_bits] := v_bl_count[p_max_bits] + v_overflow;

  v_target := power(2, p_max_bits)::bigint;
  v_weight := 0;
  for v_l in 1..p_max_bits loop
    v_weight := v_weight + v_bl_count[v_l]::bigint * power(2, p_max_bits - v_l)::bigint;
  end loop;

  while v_weight > v_target loop
    v_bits := p_max_bits - 1;
    while v_bl_count[v_bits] = 0 loop
      v_bits := v_bits - 1;
    end loop;
    v_bl_count[v_bits] := v_bl_count[v_bits] - 1;
    v_bl_count[v_bits + 1] := v_bl_count[v_bits + 1] + 2;
    v_bl_count[p_max_bits] := v_bl_count[p_max_bits] - 1;
    v_weight := v_weight - 1;
  end loop;

  -- reassign: symbols with the longest ORIGINAL (unbounded) length get the
  -- longest final length, and so on down, preserving the unbounded tree's
  -- relative ordering.
  select array_agg(gs order by v_lengths[gs] desc, gs) into v_order
    from generate_series(1, n) gs where v_lengths[gs] > 0;

  v_new_lengths := array_fill(0, array[n]);
  v_idx := 1;
  for v_l in reverse p_max_bits..1 loop
    for i in 1..v_bl_count[v_l] loop
      v_new_lengths[v_order[v_idx]] := v_l;
      v_idx := v_idx + 1;
    end loop;
  end loop;

  return v_new_lengths;
end;
$$;

-- Canonical code assignment from code lengths (RFC 1951 3.2.2): sort symbols by
-- (length, symbol value), assign codes starting at 0, incrementing by 1 within
-- a length and shifting left by 1 (i.e. *= 2) whenever the length grows. p_lengths
-- is the same 1-based, symbol-i-1-at-index-i shape archive._pq_huffman_lengths returns;
-- 0 means "unused". Returns the assigned code VALUE per symbol (not yet bit-
-- reversed for the wire -- Huffman codes are MSB-first, same convention
-- archive._pq_bit_reverse already exists to flip, reused unchanged when this gets wired
-- into a block encoder).
create or replace function archive._pq_canonical_codes(p_lengths int4[]) returns int4[]
language plpgsql as $$
declare
  n int4 := array_length(p_lengths, 1);
  v_codes int4[] := array_fill(0, array[n]);
  v_order int4[];
  v_code int4 := 0;
  v_prev_len int4 := 0;
  v_sym int4;
begin
  select array_agg(gs order by p_lengths[gs], gs) into v_order
    from generate_series(1, n) gs where p_lengths[gs] > 0;

  if v_order is null then
    return v_codes;
  end if;

  foreach v_sym in array v_order loop
    v_code := v_code << (p_lengths[v_sym] - v_prev_len);
    v_codes[v_sym] := v_code;
    v_code := v_code + 1;
    v_prev_len := p_lengths[v_sym];
  end loop;

  return v_codes;
end;
$$;

-- ---------------------------------------------------------------------------
-- Dynamic Huffman coding (issue #206), step 2 of 2: the full BTYPE=10 block
-- encoder. Factors the LZ77 matcher out of archive._pq_deflate_encode into its own
-- function so both encoders share one matching implementation rather than risking
-- a second, subtly different copy.
-- ---------------------------------------------------------------------------

-- The LZ77 matcher shared by archive._pq_deflate_encode and archive._pq_deflate_encode_dynamic:
-- single most-recent candidate per 3-byte hash, greedy, window 32768, max match 258. Returns one
-- row per token in stream order: literal (is_match=false, val1=byte 0-255) or match
-- (is_match=true, val1=length, val2=distance).
--
-- #366: candidates come from a fixed-size, in-place hash table (v_table), not a per-position temp
-- table + btree index -- that materialized one row per byte of the ENTIRE input up front, ~40x the
-- input size in peak memory, and degraded further across repeated calls in one backend session
-- (archive_batch > 1). v_table is one int4 slot per possible 3-byte value (2^24 = 16,777,216
-- entries, ~64 MiB, initialized to -1 = "no entry"), holding only the MOST RECENT position seen
-- for that exact 3-byte value -- sized to the full hash domain, not just the 32768-byte window,
-- specifically so there are zero collisions and a lookup is exactly "the largest pos < v_pos with
-- this exact hash", matching what the old exhaustive index computed, byte for byte. A table sized
-- to the window instead (the conventional zlib-style choice) would collide different 3-byte values
-- into the same slot and could silently hide a real, older match behind a newer, unrelated one --
-- still valid DEFLATE, but not byte-identical to today's output.
--
-- The old temp table held an entry for every position 0..n-3 regardless of whether the main loop's
-- greedy skip-ahead (v_pos := v_pos + v_mlen) ever visited it. A hash table that only records
-- positions the loop actually LANDS ON would silently skip the ones a match jumps over, finding
-- fewer candidates than before and producing valid but not byte-identical output. So a match's
-- branch below backfills v_table for every position it consumes (v_pos..v_pos+v_mlen-1), in
-- ascending order so ties resolve to the largest position -- not just advancing past them.
create or replace function archive._pq_lz77_tokens(payload bytea)
returns table(is_match boolean, val1 int4, val2 int4)
language plpgsql as $$
declare
  n int4 := length(payload);
  v_pos int4 := 0;
  v_hash int4; v_candidate int4; v_mlen int4;
  v_table int4[] := array_fill(-1, array[16777216]);
  v_end int4; v_j int4; v_h int4;
begin
  while v_pos < n loop
    v_candidate := null;
    if v_pos <= n - 3 then
      v_hash := (get_byte(payload,v_pos)<<16) | (get_byte(payload,v_pos+1)<<8) | get_byte(payload,v_pos+2);
      v_candidate := v_table[v_hash + 1];
      if v_candidate = -1 or v_pos - v_candidate > 32768 then
        v_candidate := null;
      end if;
    end if;
    if v_candidate is not null then
      v_mlen := archive._pq_lz_match_len(payload, v_pos, v_candidate, least(258, n - v_pos));
    else
      v_mlen := 0;
    end if;

    if v_mlen >= 3 then
      is_match := true; val1 := v_mlen; val2 := v_pos - v_candidate;
      return next;
      -- backfill every position this match consumes, including v_pos's own (never written
      -- before the lookup above) -- see the header note on why skipped positions still need
      -- an entry.
      v_end := least(v_pos + v_mlen - 1, n - 3);
      for v_j in v_pos..v_end loop
        v_h := (get_byte(payload,v_j)<<16) | (get_byte(payload,v_j+1)<<8) | get_byte(payload,v_j+2);
        v_table[v_h + 1] := v_j;
      end loop;
      v_pos := v_pos + v_mlen;
    else
      is_match := false; val1 := get_byte(payload, v_pos); val2 := null;
      return next;
      if v_pos <= n - 3 then
        v_table[v_hash + 1] := v_pos;
      end if;
      v_pos := v_pos + 1;
    end if;
  end loop;

  return;
end;
$$;

-- RFC 1951 3.2.7's code-length meta-alphabet: RLE-encodes p_lengths (the
-- combined litlen-then-dist code-length sequence a dynamic block transmits)
-- into a token stream over the 19-symbol code-length alphabet -- 0-15 mean
-- "this next code has length N" literally; 16 repeats the PREVIOUS length
-- 3-6 more times (2 extra bits); 17 repeats a zero length 3-10 times (3 extra
-- bits); 18 repeats a zero length 11-138 times (7 extra bits). Standard greedy
-- strategy: prefer the longest applicable repeat code for each run, falling
-- back to literal symbols for runs of 1-2 (too short for any repeat code) --
-- the DEFLATE format doesn't mandate a specific encoder strategy here, only
-- that the decoder can interpret whatever choices were made, so greedy is a
-- legal, simple choice.
create or replace function archive._pq_clc_rle(p_lengths int4[])
returns table(sym int4, extra_val int4, extra_bits int4)
language plpgsql as $$
declare
  n int4 := array_length(p_lengths, 1);
  i int4 := 1;
  v_val int4;
  v_run int4;
  v_j int4;
  v_take int4;
begin
  while i <= n loop
    v_val := p_lengths[i];
    v_j := i + 1;
    while v_j <= n and p_lengths[v_j] = v_val loop
      v_j := v_j + 1;
    end loop;
    v_run := v_j - i;

    if v_val = 0 then
      while v_run > 0 loop
        if v_run >= 11 then
          v_take := least(v_run, 138);
          sym := 18; extra_val := v_take - 11; extra_bits := 7;
        elsif v_run >= 3 then
          v_take := least(v_run, 10);
          sym := 17; extra_val := v_take - 3; extra_bits := 3;
        else
          v_take := 1;
          sym := 0; extra_val := 0; extra_bits := 0;
        end if;
        return next;
        v_run := v_run - v_take;
      end loop;
    else
      sym := v_val; extra_val := 0; extra_bits := 0;
      return next;
      v_run := v_run - 1;
      while v_run > 0 loop
        if v_run >= 3 then
          v_take := least(v_run, 6);
          sym := 16; extra_val := v_take - 3; extra_bits := 2;
        else
          v_take := 1;
          sym := v_val; extra_val := 0; extra_bits := 0;
        end if;
        return next;
        v_run := v_run - v_take;
      end loop;
    end if;

    i := v_j;
  end loop;
  return;
end;
$$;

-- The full dynamic-Huffman (BTYPE=10) block encoder: tokenizes via
-- archive._pq_lz77_tokens (pass 1, tallying the real litlen/distance symbol
-- frequencies), builds a genuine per-block Huffman code for each alphabet
-- (archive._pq_huffman_lengths/_canonical_codes -- pass 2), transmits both via the
-- code-length meta-alphabet (archive._pq_clc_rle, Huffman-coded the same way), then
-- re-tokenizes and emits the token stream under the new codes (pass 3). Same bit-
-- accumulator convention as archive._pq_deflate_encode (LSB-first byte packing,
-- Huffman codes bit-reversed via archive._pq_bit_reverse before packing since they're
-- conventionally written MSB-first, raw fields/extra-bits pushed unreversed).
--
-- #370: pass 3 calls archive._pq_lz77_tokens a SECOND time and recomputes each token's
-- length/distance code inline (duplicating pass 1's case blocks, the same way
-- archive._pq_deflate_encode already computes-and-immediately-uses these per token without
-- storing them) instead of replaying six parallel int4[] arrays (v_litlen_sym/_extra_val/
-- _extra_bits, v_dist_sym/_extra_val/_extra_bits) that pass 1 used to fill, one element per
-- LZ77 token. On poorly-compressible input (near one token per byte) those six arrays could
-- exceed Postgres's ~1GB single-value ceiling well before the raw payload did -- exactly
-- what production hit archiving a prompts."PromptRunLog" chunk. Re-running the matcher is a
-- bounded, cheap cost since #366 made it O(1) memory and fast; this trades that for removing
-- an O(token count) memory cost entirely. Also emits fixed-size chunks via `return next`,
-- same as archive._pq_deflate_encode_chunks above, instead of a growing v_bytes int4[] --
-- see that function's comment for why.
create or replace function archive._pq_deflate_encode_dynamic_chunks(payload bytea)
returns table(chunk bytea)
language plpgsql as $$
declare
  v_tok record;
  v_litlen_freq bigint[] := array_fill(0::bigint, array[286]);
  v_dist_freq bigint[] := array_fill(0::bigint, array[30]);

  v_litlen_lengths int4[]; v_litlen_codes int4[];
  v_dist_lengths int4[]; v_dist_codes int4[];

  v_lcode int4; v_lextra_bits int4; v_lextra_val int4;
  v_dcode int4; v_dextra_bits int4; v_dextra_val int4;
  v_len int4; v_dist int4;

  v_acc int4 := 0; v_acc_n int4 := 0;
  v_chunk_size constant int4 := 8192;
  v_chunk_empty constant bytea := decode(repeat('00', v_chunk_size), 'hex');
  v_chunk bytea := v_chunk_empty;
  v_chunk_pos int4 := 0;

  v_combined_lengths int4[];
  v_litlen_hi int4; v_dist_hi int4;
  v_hlit int4; v_hdist int4;
  v_clc_sym int4[] := '{}'; v_clc_extra_val int4[] := '{}'; v_clc_extra_bits int4[] := '{}';
  v_clc_freq bigint[] := array_fill(0::bigint, array[19]);
  v_clc_lengths int4[]; v_clc_codes int4[];
  v_clc_order int4[] := array[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];
  v_hclen int4;
  i int4; v_sym int4; v_code int4; v_nbits int4; v_rev int4;
begin
  -- ---- pass 1: tokenize, tally frequencies only (#370: no per-token array storage) ----
  for v_tok in select * from archive._pq_lz77_tokens(payload) loop
    if v_tok.is_match then
      v_len := v_tok.val1; v_dist := v_tok.val2;

      case
        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;
        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;
        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;
        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;
        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;
        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;
        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;
      end case;

      case
        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;
        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;
        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;
        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;
        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;
        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;
        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;
        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;
        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;
        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;
        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;
        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;
        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;
        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;
      end case;

      v_litlen_freq[v_lcode+1] := v_litlen_freq[v_lcode+1] + 1;
      v_dist_freq[v_dcode+1] := v_dist_freq[v_dcode+1] + 1;
    else
      v_litlen_freq[v_tok.val1+1] := v_litlen_freq[v_tok.val1+1] + 1;
    end if;
  end loop;

  v_litlen_freq[257] := v_litlen_freq[257] + 1;   -- symbol 256 (end-of-block), always present

  if (select count(*) from unnest(v_dist_freq) f where f > 0) = 0 then
    v_dist_freq[1] := 1;   -- RFC 1951 requires >=1 distance code even with zero matches
  end if;

  -- ---- pass 2: the real per-block Huffman codes ----
  v_litlen_lengths := archive._pq_huffman_lengths(v_litlen_freq, 15);
  v_litlen_codes := archive._pq_canonical_codes(v_litlen_lengths);
  v_dist_lengths := archive._pq_huffman_lengths(v_dist_freq, 15);
  v_dist_codes := archive._pq_canonical_codes(v_dist_lengths);

  -- meta-alphabet: RLE the combined length sequence, then Huffman-code THAT
  select max(gs) into v_litlen_hi from generate_series(1,286) gs where v_litlen_lengths[gs] > 0;
  if v_litlen_hi < 257 then v_litlen_hi := 257; end if;
  select max(gs) into v_dist_hi from generate_series(1,30) gs where v_dist_lengths[gs] > 0;
  if v_dist_hi is null then v_dist_hi := 1; end if;

  v_hlit := v_litlen_hi - 257;
  v_hdist := v_dist_hi - 1;

  v_combined_lengths := v_litlen_lengths[1:v_litlen_hi] || v_dist_lengths[1:v_dist_hi];

  for v_tok in select * from archive._pq_clc_rle(v_combined_lengths) loop
    v_clc_sym := array_append(v_clc_sym, v_tok.sym);
    v_clc_extra_val := array_append(v_clc_extra_val, v_tok.extra_val);
    v_clc_extra_bits := array_append(v_clc_extra_bits, v_tok.extra_bits);
    v_clc_freq[v_tok.sym+1] := v_clc_freq[v_tok.sym+1] + 1;
  end loop;

  v_clc_lengths := archive._pq_huffman_lengths(v_clc_freq, 7);
  v_clc_codes := archive._pq_canonical_codes(v_clc_lengths);

  v_hclen := 19;
  while v_hclen > 4 and v_clc_lengths[v_clc_order[v_hclen]+1] = 0 loop
    v_hclen := v_hclen - 1;
  end loop;

  -- ---- pass 3: re-tokenize, emit bits under the now-known dynamic codes ----
  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BFINAL=1
  v_acc := v_acc | (0 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE low bit
  v_acc := v_acc | (1 << v_acc_n); v_acc_n := v_acc_n + 1;                 -- BTYPE high bit (=10, dynamic)
  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;

  v_acc := v_acc | (v_hlit << v_acc_n); v_acc_n := v_acc_n + 5;
  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;
  v_acc := v_acc | (v_hdist << v_acc_n); v_acc_n := v_acc_n + 5;
  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;
  v_acc := v_acc | ((v_hclen - 4) << v_acc_n); v_acc_n := v_acc_n + 4;
  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;

  for i in 1..v_hclen loop
    v_acc := v_acc | (v_clc_lengths[v_clc_order[i]+1] << v_acc_n); v_acc_n := v_acc_n + 3;
    while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;
  end loop;

  for i in 1..array_length(v_clc_sym, 1) loop
    v_sym := v_clc_sym[i];
    v_nbits := v_clc_lengths[v_sym+1];
    v_code := v_clc_codes[v_sym+1];
    v_rev := archive._pq_bit_reverse(v_code, v_nbits);
    v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
    while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;

    if v_clc_extra_bits[i] > 0 then
      v_acc := v_acc | (v_clc_extra_val[i] << v_acc_n); v_acc_n := v_acc_n + v_clc_extra_bits[i];
      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;
    end if;
  end loop;

  for v_tok in select * from archive._pq_lz77_tokens(payload) loop
    if v_tok.is_match then
      v_len := v_tok.val1; v_dist := v_tok.val2;

      case
        when v_len between 3 and 10 then v_lcode := 257+(v_len-3); v_lextra_bits := 0; v_lextra_val := 0;
        when v_len between 11 and 18 then v_lcode := 265+(v_len-11)/2; v_lextra_bits := 1; v_lextra_val := (v_len-11)%2;
        when v_len between 19 and 34 then v_lcode := 269+(v_len-19)/4; v_lextra_bits := 2; v_lextra_val := (v_len-19)%4;
        when v_len between 35 and 66 then v_lcode := 273+(v_len-35)/8; v_lextra_bits := 3; v_lextra_val := (v_len-35)%8;
        when v_len between 67 and 130 then v_lcode := 277+(v_len-67)/16; v_lextra_bits := 4; v_lextra_val := (v_len-67)%16;
        when v_len between 131 and 257 then v_lcode := 281+(v_len-131)/32; v_lextra_bits := 5; v_lextra_val := (v_len-131)%32;
        else v_lcode := 285; v_lextra_bits := 0; v_lextra_val := 0;
      end case;

      case
        when v_dist between 1 and 4 then v_dcode := v_dist-1; v_dextra_bits := 0; v_dextra_val := 0;
        when v_dist between 5 and 8 then v_dcode := 4+(v_dist-5)/2; v_dextra_bits := 1; v_dextra_val := (v_dist-5)%2;
        when v_dist between 9 and 16 then v_dcode := 6+(v_dist-9)/4; v_dextra_bits := 2; v_dextra_val := (v_dist-9)%4;
        when v_dist between 17 and 32 then v_dcode := 8+(v_dist-17)/8; v_dextra_bits := 3; v_dextra_val := (v_dist-17)%8;
        when v_dist between 33 and 64 then v_dcode := 10+(v_dist-33)/16; v_dextra_bits := 4; v_dextra_val := (v_dist-33)%16;
        when v_dist between 65 and 128 then v_dcode := 12+(v_dist-65)/32; v_dextra_bits := 5; v_dextra_val := (v_dist-65)%32;
        when v_dist between 129 and 256 then v_dcode := 14+(v_dist-129)/64; v_dextra_bits := 6; v_dextra_val := (v_dist-129)%64;
        when v_dist between 257 and 512 then v_dcode := 16+(v_dist-257)/128; v_dextra_bits := 7; v_dextra_val := (v_dist-257)%128;
        when v_dist between 513 and 1024 then v_dcode := 18+(v_dist-513)/256; v_dextra_bits := 8; v_dextra_val := (v_dist-513)%256;
        when v_dist between 1025 and 2048 then v_dcode := 20+(v_dist-1025)/512; v_dextra_bits := 9; v_dextra_val := (v_dist-1025)%512;
        when v_dist between 2049 and 4096 then v_dcode := 22+(v_dist-2049)/1024; v_dextra_bits := 10; v_dextra_val := (v_dist-2049)%1024;
        when v_dist between 4097 and 8192 then v_dcode := 24+(v_dist-4097)/2048; v_dextra_bits := 11; v_dextra_val := (v_dist-4097)%2048;
        when v_dist between 8193 and 16384 then v_dcode := 26+(v_dist-8193)/4096; v_dextra_bits := 12; v_dextra_val := (v_dist-8193)%4096;
        else v_dcode := 28+(v_dist-16385)/8192; v_dextra_bits := 13; v_dextra_val := (v_dist-16385)%8192;
      end case;

      v_sym := v_lcode;
      v_nbits := v_litlen_lengths[v_sym+1];
      v_code := v_litlen_codes[v_sym+1];
      v_rev := archive._pq_bit_reverse(v_code, v_nbits);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;

      if v_lextra_bits > 0 then
        v_acc := v_acc | (v_lextra_val << v_acc_n); v_acc_n := v_acc_n + v_lextra_bits;
        while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;
      end if;

      v_sym := v_dcode;
      v_nbits := v_dist_lengths[v_sym+1];
      v_code := v_dist_codes[v_sym+1];
      v_rev := archive._pq_bit_reverse(v_code, v_nbits);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;

      if v_dextra_bits > 0 then
        v_acc := v_acc | (v_dextra_val << v_acc_n); v_acc_n := v_acc_n + v_dextra_bits;
        while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;
      end if;
    else
      v_sym := v_tok.val1;
      v_nbits := v_litlen_lengths[v_sym+1];
      v_code := v_litlen_codes[v_sym+1];
      v_rev := archive._pq_bit_reverse(v_code, v_nbits);
      v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
      while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;
    end if;
  end loop;

  -- end-of-block symbol (256), dynamic code
  v_nbits := v_litlen_lengths[257];
  v_code := v_litlen_codes[257];
  v_rev := archive._pq_bit_reverse(v_code, v_nbits);
  v_acc := v_acc | (v_rev << v_acc_n); v_acc_n := v_acc_n + v_nbits;
  while v_acc_n >= 8 loop v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1; v_acc := v_acc >> 8; v_acc_n := v_acc_n - 8; if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if; end loop;

  if v_acc_n > 0 then
    v_chunk := set_byte(v_chunk, v_chunk_pos, v_acc & 255); v_chunk_pos := v_chunk_pos + 1;
    if v_chunk_pos = v_chunk_size then chunk := v_chunk; return next; v_chunk := v_chunk_empty; v_chunk_pos := 0; end if;
  end if;

  if v_chunk_pos > 0 then
    chunk := substr(v_chunk, 1, v_chunk_pos); return next;
  end if;
  return;
end;
$$;

create or replace function archive._pq_deflate_encode_dynamic(payload bytea) returns bytea
language sql as $$
  select coalesce((select string_agg(chunk, ''::bytea) from archive._pq_deflate_encode_dynamic_chunks(payload)), ''::bytea);
$$;

-- Same RFC 1952 gzip container as archive._pq_gzip_compress, wrapping the dynamic-Huffman
-- encoder instead of the fixed one.
create or replace function archive._pq_gzip_compress_dynamic(payload bytea) returns bytea
language plpgsql as $$
declare
  v_deflate bytea := archive._pq_deflate_encode_dynamic(payload);
  v_header bytea := decode('1f8b08000000000000ff', 'hex');
  v_crc bigint := archive._pq_crc32(payload);
  v_isize bigint := length(payload) & 4294967295;
  v_trailer bytea;
begin
  v_trailer := archive._pq_reverse_bytes(int4send((v_crc - 4294967296 * (v_crc >> 31))::int4))
            || archive._pq_reverse_bytes(int4send((v_isize - 4294967296 * (v_isize >> 31))::int4));
  return v_header || v_deflate || v_trailer;
end;
$$;

-- ---------------------------------------------------------------------------
-- Struct builders (SchemaElement / DataPageHeader / PageHeader /
-- ColumnMetaData / ColumnChunk / RowGroup / FileMetaData)
-- ---------------------------------------------------------------------------

create or replace function archive._pq_build_schema_root(p_num_children int4) returns bytea
language sql immutable as $$
  select archive._pq_write_binary(0, 4, convert_to('root', 'UTF8'))
      || archive._pq_write_i32(4, 5, p_num_children)
      || archive._pq_stop();
$$;

-- The Thrift `union LogicalType` (parquet.thrift) selecting TIMESTAMP with the given adjustment flag
-- and a MICROS unit, as a struct payload for _pq_build_schema_leaf's p_logical_type. The writer emits
-- it for both timestamp types. For `timestamp` (without time zone) p_adjusted_to_utc is false: the
-- legacy ConvertedType TIMESTAMP_MICROS that every timestamp column also carries has no way to say
-- "this is a wall clock, not an instant" (readers take it as isAdjustedToUTC=true), and a wall clock is
-- what a `timestamp` is (issue #465). For `timestamptz` it is true, an instant. That leaf used to keep
-- its ConvertedType alone on the theory that readers already take it as an instant, and pyarrow does
-- (tz=UTC), but DuckDB does not: it read the column as a naive TIMESTAMP, not TIMESTAMP WITH TIME ZONE,
-- against the README's promise that a reader shows the instant in its own zone (#711). Either way the
-- annotation goes BESIDE the ConvertedType rather than replacing it, which is what pyarrow writes
-- (ARROW-5878): a reader that knows logical types prefers this one, and one that predates them still
-- sees a timestamp rather than a bare INT64.
create or replace function archive._pq_logical_timestamp_micros(p_adjusted_to_utc boolean) returns bytea
language sql immutable as $$
  select archive._pq_write_struct(0, 8,                                          -- LogicalType.TIMESTAMP
             archive._pq_write_bool(0, 1, p_adjusted_to_utc)                     --   isAdjustedToUTC
          || archive._pq_write_struct(1, 2,                                      --   unit: TimeUnit
                 archive._pq_write_struct(0, 2, archive._pq_stop())              --     TimeUnit.MICROS {}
              || archive._pq_stop())
          || archive._pq_stop())
      || archive._pq_stop();
$$;

-- p_converted: parquet ConvertedType code, or -1 for "none"
-- p_type_length (FIXED_LEN_BYTE_ARRAY's declared byte width -- uuid's fixed 16, or a decimal
-- column's own computed width), p_scale/p_precision (DECIMAL's schema-level annotation) and
-- p_logical_type (an already-encoded `union LogicalType` payload, today only
-- _pq_logical_timestamp_micros for a `timestamp` or `timestamptz` column) are all optional trailing params,
-- each omitted from the Thrift struct when null -- byte-for-byte unchanged for the six original
-- types, which pass none of them. Field-id deltas are tracked via v_last rather than hardcoded
-- literals, since which fields actually get written now varies.
create or replace function archive._pq_build_schema_leaf(
  p_name text, p_ptype int4, p_converted int4, p_nullable boolean,
  p_type_length int4 default null, p_scale int4 default null, p_precision int4 default null,
  p_logical_type bytea default null
) returns bytea
language plpgsql immutable as $$
declare
  buf bytea := ''::bytea;
  v_last int4 := 0;
begin
  buf := buf || archive._pq_write_i32(v_last, 1, p_ptype); v_last := 1;                     -- type
  if p_type_length is not null then
    buf := buf || archive._pq_write_i32(v_last, 2, p_type_length); v_last := 2;             -- type_length
  end if;
  buf := buf || archive._pq_write_i32(v_last, 3, case when p_nullable then 1 else 0 end); v_last := 3; -- repetition_type
  buf := buf || archive._pq_write_binary(v_last, 4, convert_to(p_name, 'UTF8')); v_last := 4;          -- name
  if p_converted >= 0 then
    buf := buf || archive._pq_write_i32(v_last, 6, p_converted); v_last := 6;               -- converted_type
  end if;
  if p_scale is not null then
    buf := buf || archive._pq_write_i32(v_last, 7, p_scale); v_last := 7;                   -- scale
  end if;
  if p_precision is not null then
    buf := buf || archive._pq_write_i32(v_last, 8, p_precision); v_last := 8;               -- precision
  end if;
  if p_logical_type is not null then
    buf := buf || archive._pq_write_struct(v_last, 10, p_logical_type); v_last := 10;       -- logicalType
  end if;
  buf := buf || archive._pq_stop();
  return buf;
end;
$$;

create or replace function archive._pq_build_data_page_header(p_num_values int4) returns bytea
language sql immutable as $$
  select archive._pq_write_i32(0, 1, p_num_values)      -- num_values
      || archive._pq_write_i32(1, 2, 0)                 -- encoding = PLAIN
      || archive._pq_write_i32(2, 3, 3)                  -- definition_level_encoding = RLE
      || archive._pq_write_i32(3, 4, 3)                  -- repetition_level_encoding = RLE
      || archive._pq_stop();
$$;

-- p_compressed_len defaults to p_uncompressed_len (codec = UNCOMPRESSED, the existing
-- behavior unchanged); pass a smaller value when the page bytes going into the file are
-- actually archive._pq_gzip_compress_dynamic(...) output rather than the raw encoded bytes.
create or replace function archive._pq_build_page_header(p_num_values int4, p_uncompressed_len int4, p_compressed_len int4 default null) returns bytea
language plpgsql immutable as $$
declare
  dph bytea := archive._pq_build_data_page_header(p_num_values);
  v_compressed_len int4 := coalesce(p_compressed_len, p_uncompressed_len);
  buf bytea;
begin
  buf := archive._pq_write_i32(0, 1, 0);                        -- type = DATA_PAGE
  buf := buf || archive._pq_write_i32(1, 2, p_uncompressed_len); -- uncompressed_page_size
  buf := buf || archive._pq_write_i32(2, 3, v_compressed_len);   -- compressed_page_size
  buf := buf || archive._pq_write_struct(3, 5, dph);             -- data_page_header
  buf := buf || archive._pq_stop();
  return buf;
end;
$$;

-- p_codec: 0 = UNCOMPRESSED (default, existing behavior), 2 = GZIP. p_total_compressed
-- defaults to p_total_uncompressed for the UNCOMPRESSED case.
create or replace function archive._pq_build_column_metadata(
    p_ptype int4, p_colname text, p_num_values bigint,
    p_total_uncompressed bigint, p_data_page_offset bigint,
    p_codec int4 default 0, p_total_compressed bigint default null
) returns bytea
language plpgsql immutable as $$
declare
  v_total_compressed bigint := coalesce(p_total_compressed, p_total_uncompressed);
  buf bytea;
begin
  buf := archive._pq_write_i32(0, 1, p_ptype);                                              -- type
  buf := buf || archive._pq_write_list_i32(1, 2, array[0]);                                 -- encodings = [PLAIN]
  buf := buf || archive._pq_write_list_binary(2, 3, array[convert_to(p_colname,'UTF8')]);   -- path_in_schema
  buf := buf || archive._pq_write_i32(3, 4, p_codec);                                       -- codec
  buf := buf || archive._pq_write_i64(4, 5, p_num_values);                                  -- num_values
  buf := buf || archive._pq_write_i64(5, 6, p_total_uncompressed);                          -- total_uncompressed_size
  buf := buf || archive._pq_write_i64(6, 7, v_total_compressed);                            -- total_compressed_size
  buf := buf || archive._pq_write_i64(7, 9, p_data_page_offset);                            -- data_page_offset
  buf := buf || archive._pq_stop();
  return buf;
end;
$$;

create or replace function archive._pq_build_column_chunk(p_metadata bytea) returns bytea
language sql immutable as $$
  select archive._pq_write_i64(0, 2, 0)              -- file_offset (deprecated, 0)
      || archive._pq_write_struct(2, 3, p_metadata)  -- meta_data
      || archive._pq_stop();
$$;

create or replace function archive._pq_build_row_group(p_chunks bytea[], p_total_bytes bigint, p_num_rows bigint) returns bytea
language sql immutable as $$
  select archive._pq_write_list_struct(0, 1, p_chunks)      -- columns
      || archive._pq_write_i64(1, 2, p_total_bytes)         -- total_byte_size
      || archive._pq_write_i64(2, 3, p_num_rows)            -- num_rows
      || archive._pq_stop();
$$;

create or replace function archive._pq_build_file_metadata(p_schema bytea[], p_num_rows bigint, p_row_groups bytea[]) returns bytea
language sql immutable as $$
  select archive._pq_write_i32(0, 1, 1)                                                       -- version
      || archive._pq_write_list_struct(1, 2, p_schema)                                        -- schema
      || archive._pq_write_i64(2, 3, p_num_rows)                                               -- num_rows
      || archive._pq_write_list_struct(3, 4, p_row_groups)                                     -- row_groups
      || archive._pq_write_binary(4, 6, convert_to('pg_partition_magician parquet prototype', 'UTF8')) -- created_by
      || archive._pq_stop();
$$;

-- ---------------------------------------------------------------------------
-- Column data extraction (server-side aggregation, ctid-ordered by default so
-- every column's array lines up on the same row order)
-- ---------------------------------------------------------------------------

-- Whether a numeric column of the snapshot an encoder is about to write holds a NaN (#635). NaN is
-- written as null (see the numeric branch of _pq_encode_column_data), so a NOT NULL numeric(p,s) column
-- holding one needs an OPTIONAL leaf in that file; both encoders ask this before they encode such a
-- column, and only for such a column: a nullable leaf is OPTIONAL already, and a file whose NOT NULL
-- column holds no NaN keeps its REQUIRED leaf, byte for byte as before.
create or replace function archive._pq_has_nan(p_schema name, p_table name, p_col name)
returns boolean language plpgsql stable as $$
declare v boolean;
begin
  execute format('select exists (select 1 from %I.%I where %I = ''NaN''::numeric)', p_schema, p_table, p_col) into v;
  return v;
end;
$$;

-- archive._pq_from_item builds the FROM item every read in this section runs against, and is the
-- ONLY place in the module that builds one. Both shapes come out of %I/%L over typed inputs: a
-- whole relation from p_schema/p_table, and a half-open [p_lo, p_hi) range on p_control when a
-- control column is given. Callers pass catalog values (n.nspname, c.relname) and the encoder's own
-- parameters straight in -- nobody assembles the string themselves, which is the point.
--
-- WHY IT EXISTS. This used to be assembled by each caller and handed to
-- archive._pq_encode_column_data as a `p_from_sql text` that the encoder then spliced with a bare
-- %s, no quoting, in all seven type branches -- the one place among the module's audited
-- `execute format(...)` sites where a text parameter reached the statement unquoted (issue #408,
-- from the #346 audit). Nothing untrusted ever reached it: both callers built it out of %I-quoted
-- catalog names. But the guarantee lived in the callers, so the encoder promised nothing on its
-- own and a third caller written later would have inherited nothing. Building it here, from typed
-- inputs, puts the guarantee where a future caller cannot route around it.
--
-- `x` aliases the range subquery because a subquery in a FROM item needs a name. Immutable and SQL,
-- not plpgsql: it is pure text assembly with no catalog lookup of its own.
create or replace function archive._pq_from_item(
  p_schema name, p_table name, p_control name default null, p_lo text default null, p_hi text default null
) returns text
language sql immutable as $$
  select case
    when p_control is null then format('%I.%I', p_schema, p_table)
    else format('(select * from %I.%I where %I >= %L and %I < %L) x',
                p_schema, p_table, p_control, p_lo, p_control, p_hi)
  end;
$$;

-- p_nullable columns interleave nulls with real values; is_present[i] tracks which rows had a
-- value so the OPTIONAL path can prepend a definition-levels bitmap, while the values-only
-- payload always contains just the non-null values, in row order. For a NOT NULL column every
-- row is guaranteed non-null (Postgres enforces that at the table level), so this collapses to
-- the old unconditional-encode behavior byte-for-byte; only p_nullable decides whether the
-- definition-levels block gets prepended at all.
--
-- NO PARAMETER OF THIS FUNCTION CARRIES SQL (issue #408). The relation arrives as p_schema/p_table
-- and the range as p_control/p_lo/p_hi, both of which go to archive._pq_from_item above to be
-- %I/%L-quoted; the ordering arrives as p_order_by `name[]` and is quote_ident'd element by element
-- here, into v_order_q, before anything is spliced. Before that, p_from_sql and p_order_by were
-- `text` spliced with a bare %s, twice each, in every branch below -- safe only because both
-- callers happened to build them out of catalog-derived, already-quoted pieces. Keep it this way:
-- if a future variant needs a shape neither p_control nor p_order_by can express, widen
-- _pq_from_item's typed parameters rather than reintroducing a parameter that is pasted in whole.
-- tests/archive/db/10_encode_boundary_test.sql drives a statement terminator through every one of
-- these parameters and pins the signature against exactly that regression.
--
-- p_order_by defaults to {ctid}, the whole-relation ordering this function was written for and the
-- one bench/archive_encode_memory.sh still drives it with directly. Since #462 neither encoder points
-- it at the source relation at all: archive._pq_snapshot (below) materialises the rows once, in the
-- order the encoder wants -- ctid for the whole-relation entry point, '(control column, key
-- columns)' for the range one, since ctid is not comparable once a read spans more than one child's
-- heap -- and numbers them, and both encoders then pass {archive_pq_ord} over that table.
-- quote_ident('ctid') is `ctid` -- a system column needs no special case here. Every caller
-- guarantees p_order_by is a strict total order with no ties: ctid is unique per live row, and a
-- row_number() ordinal is unique by construction, which is what both encoders pass since #462 (the
-- range variant's control-and-key order, or control column alone on a keyless parent (#597), only
-- decides the ordinal archive._pq_snapshot assigns once). That matters below,
-- where is_present and values_payload are two SEPARATE aggregate calls sharing the same ORDER BY
-- text rather than one shared array: with no ties, there is only one valid row ordering for
-- p_order_by, so the two sorts can't land on different sequences relative to each other. This one
-- definition serves both callers -- it is deliberately NOT redeclared with a different parameter
-- list anywhere else, since Postgres overload resolution is keyed on the parameter type list (not
-- names or defaults): a second, differently-aritied "replacement" would coexist as a distinct
-- overload rather than actually replacing this one, and a 4-arg call would become ambiguous
-- between the two (see #209).
-- p_decimal_scale/p_decimal_bytes are only meaningful (and only passed) for p_pgtype = 'numeric':
-- the scale to multiply by before rounding to an integer, and the fixed byte width
-- _pq_decimal_byte_width already sized to the column's own declared precision.
-- Builds one column's data page: a per-row null bitmap (is_present) plus the concatenated
-- PLAIN-encoded bytes of every non-null value, in p_order_by order. Each branch runs ONE dynamic
-- query directly against the FROM item with two real aggregates -- array_agg for is_present, and
-- string_agg (or array_agg again for bool) for values_payload -- never a PL/pgSQL loop that grows
-- values_payload with `||`. That distinction matters: `:=`-with-`||` reassigns an immutable
-- bytea/array value, so N appends copy the entire accumulated buffer each time (O(n^2) total);
-- string_agg/array_agg are real aggregates with amortized-growth internals. Mirrors the pattern
-- this file already uses correctly elsewhere for list/array encoding
-- (archive._pq_write_list_struct/_pq_write_list_i32/_pq_write_list_binary). An earlier version
-- fetched the whole column into an array_agg first, then re-aggregated a SECOND time over
-- unnest(...) with ordinality to derive is_present/values_payload -- that held two full-size
-- copies of the column at once (plus the transient doubling each aggregate's own growth costs),
-- ~6x peak RSS on a large text column (issue #368); querying the FROM item directly, once, removes
-- the intermediate array entirely. string_agg/array_agg skip NULL inputs on their own; `filter
-- (where ... is not null)` makes that explicit and is what replaces each old loop's `if ... is not
-- null then` guard.
create or replace function archive._pq_encode_column_data(
  p_schema name, p_table name, p_col text, p_pgtype text, p_nullable boolean,
  p_order_by name[] default array['ctid']::name[],
  p_decimal_scale int4 default null, p_decimal_bytes int4 default null,
  p_control name default null, p_lo text default null, p_hi text default null
) returns bytea
-- extra_float_digits is pinned because an array column is written as array_to_json TEXT, and a float in
-- that text follows the session's setting: under 0 (the pre-PG12 default, still set by ALTER ROLE or ALTER
-- DATABASE on some clusters and inherited by a tick) a float8[] element was written to 15 significant
-- digits, a value the row never held (#781). 1 is shortest-exact (any value above 0 is), the PostgreSQL 12+
-- default, so a file written from a default session is unchanged. The scalar float8 leaf is binary.
language plpgsql set extra_float_digits = 1 as $$
declare
  values_payload bytea := ''::bytea;
  is_present boolean[] := '{}';
  present_bools boolean[] := '{}';
  v_from_q text;
  v_order_q text;
begin
  v_from_q := archive._pq_from_item(p_schema, p_table, p_control, p_lo, p_hi);
  select string_agg(quote_ident(c), ', ' order by ord) into v_order_q
    from unnest(p_order_by) with ordinality as t(c, ord);
  if v_order_q is null then
    raise exception 'archive._pq_encode_column_data: p_order_by is empty; the two aggregates below are separately sorted and need a total order to agree on';
  end if;

  if p_pgtype = 'int4' then
    execute format(
      'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
              coalesce(string_agg(archive._pq_plain_int32(%I::int4), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
         from %s',
      p_col, v_order_q, p_col, v_order_q, p_col, v_from_q)
      into is_present, values_payload;
  elsif p_pgtype = 'int8' then
    execute format(
      'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
              coalesce(string_agg(archive._pq_plain_int64(%I::int8), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
         from %s',
      p_col, v_order_q, p_col, v_order_q, p_col, v_from_q)
      into is_present, values_payload;
  elsif p_pgtype = 'float8' then
    execute format(
      'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
              coalesce(string_agg(archive._pq_plain_double(%I::float8), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
         from %s',
      p_col, v_order_q, p_col, v_order_q, p_col, v_from_q)
      into is_present, values_payload;
  elsif p_pgtype = 'bool' then
    execute format(
      'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
              coalesce(array_agg(%I::boolean order by %s) filter (where %I is not null), ''{}''::boolean[])
         from %s',
      p_col, v_order_q, p_col, v_order_q, p_col, v_from_q)
      into is_present, present_bools;
    values_payload := archive._pq_plain_boolean_array(present_bools);
  elsif p_pgtype in ('text', 'array_json') then
    execute format(
      case when p_pgtype = 'array_json'
        then 'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
                     coalesce(string_agg(archive._pq_plain_text(array_to_json(%I)::text), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
                from %s'
        else 'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
                     coalesce(string_agg(archive._pq_plain_text(%I::text), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
                from %s'
      end,
      p_col, v_order_q, p_col, v_order_q, p_col, v_from_q)
      into is_present, values_payload;
  elsif p_pgtype in ('timestamptz','timestamp') then
    -- Both land as INT64 microseconds since the Unix epoch, but they get there differently. A
    -- timestamptz is an instant: extract(epoch) of it is the same number in every session. A
    -- `timestamp` is a wall clock with no instant of its own, and `%I::timestamptz` would read that
    -- wall clock in the SESSION zone, so the same table archived by the pg_cron worker (cluster
    -- default zone) and by `call pgpm.maintain()` from a differently-zoned psql produced different
    -- bytes, while NDJSON's row_to_json kept the wall clock either way (issue #465). `at time zone
    -- 'UTC'` reads the wall clock as if it were UTC, Parquet's representation of a naive timestamp,
    -- and the leaf says so (LogicalType TIMESTAMP isAdjustedToUTC=false, _pq_logical_timestamp_micros).
    -- archive._pq_epoch_micros turns either into the INT64, 'infinity' and '-infinity' included (#586).
    execute format(
      case when p_pgtype = 'timestamp'
        then 'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
                     coalesce(string_agg(archive._pq_plain_int64(archive._pq_epoch_micros(%I at time zone ''UTC'')), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
                from %s'
        else 'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
                     coalesce(string_agg(archive._pq_plain_int64(archive._pq_epoch_micros(%I::timestamptz)), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
                from %s'
      end,
      p_col, v_order_q, p_col, v_order_q, p_col, v_from_q)
      into is_present, values_payload;
  elsif p_pgtype = 'uuid' then
    execute format(
      'select coalesce(array_agg(%I is not null order by %s), ''{}''::boolean[]),
              coalesce(string_agg(archive._pq_plain_uuid(%I::uuid), ''''::bytea order by %s) filter (where %I is not null), ''''::bytea)
         from %s',
      p_col, v_order_q, p_col, v_order_q, p_col, v_from_q)
      into is_present, values_payload;
  elsif p_pgtype = 'numeric' then
    -- NaN, a legal value of numeric(p,s), has no DECIMAL representation (an unscaled integer), and
    -- reaching archive._pq_plain_decimal it raised 'cannot convert NaN to integer' on every encode of its
    -- chunk: skip_archive every tick, the partition never covered or retired, the #586 wedge on the
    -- DECIMAL leaf (#635). It is written as null instead, Spark's reading of a NaN cast to DECIMAL: absent
    -- from the values, false in is_present. A NOT NULL column holding one gets an OPTIONAL leaf in that
    -- file (archive._pq_has_nan, in both encoders), so the definition levels that carry the null exist.
    execute format(
      'select coalesce(array_agg(%I is not null and %I <> ''NaN''::numeric order by %s), ''{}''::boolean[]),
              coalesce(string_agg(archive._pq_plain_decimal(%I::numeric, %L, %L), ''''::bytea order by %s) filter (where %I is not null and %I <> ''NaN''::numeric), ''''::bytea)
         from %s',
      p_col, p_col, v_order_q, p_col, p_decimal_scale, p_decimal_bytes, v_order_q, p_col, p_col, v_from_q)
      into is_present, values_payload;
  else
    raise exception 'archive._pq_encode_column_data: unsupported column type % for column %', p_pgtype, p_col;
  end if;

  if p_nullable then
    return archive._pq_definition_levels(is_present) || values_payload;
  else
    return values_payload;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- The read: one statement, one snapshot (issue #462)
-- ---------------------------------------------------------------------------

-- archive._pq_snapshot: materialises the rows an encoder is about to write, in their final row
-- order, into the session temp table pg_temp.archive_pq_snapshot, in ONE statement, and returns how
-- many rows that statement saw. Every column the encoder reads from the table afterwards therefore
-- has exactly that many rows, in exactly that order, whatever else commits meanwhile.
--
-- WHY. archive._pq_encode_column_data runs one query per column, and a VOLATILE plpgsql function
-- under READ COMMITTED takes a fresh snapshot for every statement it runs. Pointed straight at the
-- relation, N columns were N snapshots, plus one more for the count(*) that sized the page headers.
-- A row committing between two of those reads was in the later columns and not the earlier ones,
-- and from that column on every value sat one row away from the row it belonged to. The file was
-- well-formed (every column had exactly count(*) values), so no reader could tell: the hunt read
-- 8000 of 8000 rows with a tag belonging to a different row's id. Reading from a table only this
-- session can see, filled by one statement, gives every column the same rows in the same order no
-- matter how many statements it takes to encode them. It does so without a lock that would block
-- writers for the length of the encode, and without REPEATABLE READ, which a function cannot switch
-- to mid-transaction (SET TRANSACTION is legal only before the transaction's first query).
--
-- archive_pq_ord is the row's position under p_order_by, computed once here so the per-column reads
-- sort a bigint instead of re-sorting the key. Under a strict total order (ctid, or the control
-- column and a key) a row's position is fixed, so `order by archive_pq_ord` reproduces p_order_by
-- exactly and the file's bytes do not change: verified byte-for-byte against the pre-#462 encoder,
-- both entry points, compressed and not. On a keyless parent (#597) p_order_by is the control column
-- alone and ties take whatever order this one row_number() gives them; that is still ONE order, the
-- one every column is read in, so a row's values stay on one row. The
-- ordinal has to be a column of its own because ctid, the whole-relation encoder's order, does not
-- survive a copy (the temp table has ctids of its own), and a fresh heap's insertion order is not a
-- documented property to lean on.
--
-- MEMORY. This is not another copy of the data in process memory: a temp table lives in temp_buffers
-- and spills to the backend's temp files, so the encoder's peak RSS is still set by the one column it
-- is encoding plus the compressed body it has built so far (the shape bench/archive_*_memory.sh pin
-- for #366/#368/#370), not by the width of the row. It is one more copy ON DISK for the life of the
-- call, and one sort (the row_number) in place of N sorts of the key over the source. The encoders
-- empty it as soon as the last column is read; ON COMMIT DROP removes it when the transaction ends.
-- pg_temp is the only schema the name can resolve in, so it can never drop anything but this
-- session's own.
--
-- LOCKS. The relation is REUSED, not rebuilt, by every later encode of the same shape in the same
-- transaction: emptied (TRUNCATE) and refilled by one INSERT ... SELECT, which is still one statement
-- and so still one snapshot. Creating a relation and dropping it took about eight entries in the
-- SHARED lock table (the table, its TOAST table and TOAST index, its row type and array type), and a
-- dropped relation's locks are held to transaction end, so an encoder that built a fresh one per call
-- grew a transaction's lock entries by eight per encode. pgpm._archive_step runs one encode per chunk
-- for up to archive_batch partitions of ONE parent in one transaction, so that was eight per chunk
-- until the tick committed: the #587 cliff again (issue #632, F5-04). Reusing the relation takes its
-- locks once, so the entries a transaction holds no longer grow with the number of encodes it runs.
-- The shape is checked, not assumed: the relation is reused only when its columns are exactly the
-- ones this call would create (names, types, typmods and collations, in order, then the ordinal),
-- and otherwise it is dropped and built again, so encodes of differently shaped tables in one
-- transaction stay correct and cost one set of entries per change of shape, not per encode.
--
-- Nothing here carries SQL (#408): the relation arrives as p_schema/p_table and the range as
-- p_control/p_lo/p_hi (both go to archive._pq_from_item), the column list and the ordering as
-- name[], quote_ident'd element by element.
create or replace function archive._pq_snapshot(
  p_schema name, p_table name, p_cols name[], p_order_by name[],
  p_control name default null, p_lo text default null, p_hi text default null
) returns bigint
language plpgsql as $$
declare
  v_from_q text; v_cols_q text; v_order_q text; v_num_rows bigint;
  v_snap regclass; v_want text[]; v_have text[];
begin
  if 'archive_pq_ord' = any (p_cols) then
    raise exception 'archive._pq_snapshot: %.% has a column named archive_pq_ord, the name the Parquet encoder reserves for its row ordinal; rename it to archive the table as Parquet', p_schema, p_table;
  end if;
  select string_agg(quote_ident(c), ', ' order by ord) into v_cols_q
    from unnest(p_cols) with ordinality as t(c, ord);
  select string_agg(quote_ident(c), ', ' order by ord) into v_order_q
    from unnest(p_order_by) with ordinality as t(c, ord);
  if v_cols_q is null or v_order_q is null then
    raise exception 'archive._pq_snapshot: p_cols and p_order_by must both be non-empty';
  end if;
  v_from_q := archive._pq_from_item(p_schema, p_table, p_control, p_lo, p_hi);

  -- The shape check runs on every call, the first included, and so does the TRUNCATE and the INSERT
  -- below: the first encode in a transaction then takes every lock a later one takes, and a later one
  -- takes none of its own. The columns this call's CREATE would give the relation, then the ordinal:
  v_snap := to_regclass('pg_temp.archive_pq_snapshot');
  select array_agg(format('%s %s %s %s', a.attname, a.atttypid, a.atttypmod, a.attcollation) order by t.ord)
    into v_want
    from unnest(p_cols) with ordinality as t(c, ord)
    join pg_namespace n on n.nspname = p_schema
    join pg_class r on r.relnamespace = n.oid and r.relname = p_table
    join pg_attribute a on a.attrelid = r.oid and a.attname = t.c and a.attnum > 0 and not a.attisdropped;
  v_want := v_want || format('%s %s %s %s', 'archive_pq_ord', 'int8'::regtype::oid, -1, 0);
  -- and the columns the relation already there has (none when there is none)
  select array_agg(format('%s %s %s %s', a.attname, a.atttypid, a.atttypmod, a.attcollation) order by a.attnum)
    into v_have
    from pg_attribute a join pg_class c on c.oid = a.attrelid
   where a.attrelid = v_snap and c.relkind = 'r' and a.attnum > 0 and not a.attisdropped;
  if v_snap is not null and v_have is distinct from v_want then
    drop table pg_temp.archive_pq_snapshot;
    v_snap := null;
  end if;
  -- built empty, then filled by the same two statements a reuse runs
  if v_snap is null then
    execute format(
      'create temp table archive_pq_snapshot on commit drop as
         select %s, row_number() over (order by %s) as archive_pq_ord from %s with no data',
      v_cols_q, v_order_q, v_from_q);
  end if;
  truncate pg_temp.archive_pq_snapshot;
  -- ONE statement, so ONE snapshot: every row the encoder writes is a row this statement saw.
  execute format(
    'insert into pg_temp.archive_pq_snapshot
       select %s, row_number() over (order by %s) as archive_pq_ord from %s',
    v_cols_q, v_order_q, v_from_q);
  get diagnostics v_num_rows = row_count;
  return v_num_rows;
end;
$$;

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

create or replace function archive._pq_to_parquet(p_relation regclass, p_compress boolean default true) returns bytea
language plpgsql as $$
declare
  v_schema name; v_table name;
  v_col record;
  v_col_names text[] := '{}';
  v_col_pgtypes text[] := '{}';
  v_col_ptypes int4[] := '{}';
  v_col_converted int4[] := '{}';
  v_col_nullable boolean[] := '{}';
  v_col_typelen int4[] := '{}';
  v_col_scale int4[] := '{}';
  v_col_precision int4[] := '{}';
  v_precision int4; v_scale int4;
  v_ncols int4;
  v_num_rows bigint;
  v_magic bytea := convert_to('PAR1', 'UTF8');
  v_body bytea;
  v_data bytea; v_page_bytes bytea; v_page_header bytea; v_page_offset bigint;
  v_column_chunks bytea[] := '{}';
  v_schema_elements bytea[] := '{}';
  v_total_uncompressed bigint;
  v_row_group bytea;
  v_schema_list bytea[];
  v_footer bytea;
  i int4;
begin
  select n.nspname, c.relname into v_schema, v_table
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.oid = p_relation;

  for v_col in
    select a.attname, a.attnotnull, t.typname, t.typtype, t.typcategory, t.typelem, a.atttypmod
    from pg_attribute a join pg_type t on t.oid = a.atttypid
    where a.attrelid = p_relation and a.attnum > 0 and not a.attisdropped
    order by a.attnum
  loop
    v_col_names := v_col_names || v_col.attname;
    v_col_nullable := v_col_nullable || (not v_col.attnotnull);

    if v_col.typtype = 'e' then
      v_col_pgtypes := v_col_pgtypes || 'text'::text; v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 0;
      v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
    elsif v_col.typcategory = 'A' and v_col.typelem <> 0 then
      v_col_pgtypes := v_col_pgtypes || 'array_json'::text; v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 19;
      v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
    else
      case v_col.typname
      when 'int4'        then v_col_pgtypes := v_col_pgtypes || 'int4'::text;        v_col_ptypes := v_col_ptypes || 1; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'int8'        then v_col_pgtypes := v_col_pgtypes || 'int8'::text;        v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'float8'      then v_col_pgtypes := v_col_pgtypes || 'float8'::text;      v_col_ptypes := v_col_ptypes || 5; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'bool'        then v_col_pgtypes := v_col_pgtypes || 'bool'::text;        v_col_ptypes := v_col_ptypes || 0; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'text'        then v_col_pgtypes := v_col_pgtypes || 'text'::text;        v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 0;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'timestamptz' then v_col_pgtypes := v_col_pgtypes || 'timestamptz'::text; v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'timestamp'   then v_col_pgtypes := v_col_pgtypes || 'timestamp'::text;   v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'uuid'        then v_col_pgtypes := v_col_pgtypes || 'uuid'::text;        v_col_ptypes := v_col_ptypes || 7; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || 16; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'json'        then v_col_pgtypes := v_col_pgtypes || 'text'::text;        v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 19;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'jsonb'       then v_col_pgtypes := v_col_pgtypes || 'text'::text;        v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 19;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'numeric'     then
        if v_col.atttypmod = -1 then
          raise exception 'archive._pq_to_parquet: column % is numeric with no declared precision/scale; declare it numeric(p,s) to archive it as Parquet DECIMAL', v_col.attname;
        end if;
        select d.p_precision, d.p_scale into v_precision, v_scale from archive._pq_decimal_shape(v_col.atttypmod) d;
        v_col_pgtypes := v_col_pgtypes || 'numeric'::text; v_col_ptypes := v_col_ptypes || 7; v_col_converted := v_col_converted || 5;
        v_col_typelen := v_col_typelen || archive._pq_decimal_byte_width(v_precision); v_col_scale := v_col_scale || v_scale; v_col_precision := v_col_precision || v_precision;
        else raise exception 'archive._pq_to_parquet: unsupported column type % for column %', v_col.typname, v_col.attname;
      end case;
    end if;
  end loop;

  v_ncols := array_length(v_col_names, 1);
  if v_ncols is null then
    raise exception 'archive._pq_to_parquet: relation % has no supported columns', p_relation;
  end if;

  -- ONE statement, ONE snapshot (#462): every column below is read from this materialisation, so a
  -- write that commits while the columns are being encoded is in all of them or in none, and the
  -- row count that sizes the page headers and the footer is the count of rows the file holds, not
  -- a count(*) that saw a snapshot of its own. ctid order, as this entry point has always written a
  -- single heap; archive._pq_snapshot numbers the rows in that order once.
  v_num_rows := archive._pq_snapshot(v_schema, v_table, v_col_names::name[], array['ctid']::name[]);

  v_body := v_magic;
  for i in 1..v_ncols loop
    -- a NaN is written as null, so a NOT NULL numeric column holding one is OPTIONAL in this file (#635)
    if v_col_pgtypes[i] = 'numeric' and not v_col_nullable[i]
       and archive._pq_has_nan('pg_temp', 'archive_pq_snapshot', v_col_names[i]) then
      v_col_nullable[i] := true;
    end if;
    -- named notation, and not just for length: it is what makes the absence of a SQL-carrying
    -- argument legible at the call site, which is the whole point of #408's signature.
    v_data := archive._pq_encode_column_data(
      p_schema => 'pg_temp', p_table => 'archive_pq_snapshot',
      p_col => v_col_names[i], p_pgtype => v_col_pgtypes[i], p_nullable => v_col_nullable[i],
      p_order_by => array['archive_pq_ord']::name[],
      p_decimal_scale => v_col_scale[i], p_decimal_bytes => v_col_typelen[i]);
    if p_compress then
      v_page_bytes := archive._pq_gzip_compress_dynamic(v_data);
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data), length(v_page_bytes));
    else
      v_page_bytes := v_data;
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data));
    end if;
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_page_bytes;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || archive._pq_build_column_chunk(
        archive._pq_build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset,
          case when p_compress then 2 else 0 end,
          case when p_compress then length(v_page_header) + length(v_page_bytes) else null end));
    v_schema_elements := v_schema_elements || archive._pq_build_schema_leaf(v_col_names[i], v_col_ptypes[i], v_col_converted[i], v_col_nullable[i],
      v_col_typelen[i], v_col_scale[i], v_col_precision[i],
      -- a `timestamp` is a wall clock, not an instant: say so, or readers take TIMESTAMP_MICROS as UTC-adjusted (#465);
      -- a `timestamptz` is an instant: say that too, or DuckDB reads it as a naive TIMESTAMP (#711)
      p_logical_type => case when v_col_pgtypes[i] = 'timestamp' then archive._pq_logical_timestamp_micros(false)
                             when v_col_pgtypes[i] = 'timestamptz' then archive._pq_logical_timestamp_micros(true) end);
  end loop;

  v_row_group := archive._pq_build_row_group(v_column_chunks, length(v_body) - length(v_magic), v_num_rows);

  v_schema_list := array_prepend(archive._pq_build_schema_root(v_ncols), v_schema_elements);
  v_footer := archive._pq_build_file_metadata(v_schema_list, v_num_rows, array[v_row_group]);

  truncate pg_temp.archive_pq_snapshot;  -- emptied, not dropped: the next encode reuses it (#632)
  return v_body || v_footer || archive._pq_reverse_bytes(int4send(length(v_footer))) || v_magic;
end;
$$;


-- ---------------------------------------------------------------------------
-- The range-based Parquet encoder (reads a [lo, hi) range off the parent,
-- relying on Postgres's own partition pruning), the derived watermark, and
-- the gate.
-- ---------------------------------------------------------------------------

-- archive._pq_to_parquet_range_counted: reads [p_lo, p_hi) of p_control off p_parent (typically a
-- partitioned parent), relying on Postgres's own partition pruning, and returns the file (p_file)
-- together with the number of rows it holds (p_num_rows), both from the one snapshot
-- archive._pq_snapshot took. p_lo/p_hi are literals already typed for p_control's actual column
-- type -- e.g. for a uuidv7-kind control column, translate a pgpm native-grid (timestamptz) value
-- via pgpm._encode first, the same way pgpm.regrain_step builds its own v_lo_lit/v_hi_lit before
-- using them.
--
-- Two names for one encode, on purpose. archive._encode_upload_parquet needs the row count for the
-- ledger's rows_archived and used to get it from a count(*) of its own, a statement later and a
-- snapshot apart from the file, so under a concurrent write it matched neither the file nor the
-- child (#462); it calls this. archive._pq_to_parquet_range (below) keeps its bytea signature for
-- every caller that only wants the file (scripts/verify_parquet_range.py, the bench/ memory guards)
-- and is a one-line wrapper over this, so there is exactly one encoder. Exceptions raised here are
-- worded under the wrapper's name, which is the name callers know.
create or replace function archive._pq_to_parquet_range_counted(
  p_parent regclass, p_control name, p_lo text, p_hi text, p_compress boolean,
  out p_file bytea, out p_num_rows bigint)
language plpgsql as $$
declare
  v_schema name; v_table name; v_order_cols name[]; v_key_cols name[];
  v_col record;
  v_col_names text[] := '{}';
  v_col_pgtypes text[] := '{}';
  v_col_ptypes int4[] := '{}';
  v_col_converted int4[] := '{}';
  v_col_nullable boolean[] := '{}';
  v_col_typelen int4[] := '{}';
  v_col_scale int4[] := '{}';
  v_col_precision int4[] := '{}';
  v_precision int4; v_scale int4;
  v_ncols int4;
  v_num_rows bigint;
  v_magic bytea := convert_to('PAR1', 'UTF8');
  v_body bytea;
  v_data bytea; v_page_bytes bytea; v_page_header bytea; v_page_offset bigint;
  v_column_chunks bytea[] := '{}';
  v_schema_elements bytea[] := '{}';
  v_total_uncompressed bigint;
  v_row_group bytea;
  v_schema_list bytea[];
  v_footer bytea;
  i int4;
begin
  select n.nspname, c.relname into v_schema, v_table
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.oid = p_parent;

  -- the ordering travels as column NAMES, not as a joined SQL fragment: the encoder quote_ident's
  -- each one itself (#408). The control column leads, the key columns, when there are any, tiebreak it.
  --
  -- A keyless parent is archived too, ordered by the control column alone (#597). It used to be
  -- refused here, on every chunk, for want of a tiebreak, while pgpm.set_archive_fn accepted the
  -- strategy for it and transmute partitions keyless tables as a supported shape: every maintain()
  -- tick logged skip_archive and nothing of the table was ever covered or retired. The tiebreak buys
  -- nothing since #462. Every column is read from ONE materialisation (archive._pq_snapshot) whose
  -- row_number() is assigned once, so rows tied on the control column land in some order, the same
  -- order in every column; and the read is one statement with no pagination (pgpm._next_archive_chunk
  -- extends a chunk to the next distinct control value, so a run of ties is never split across two
  -- chunks). With a key the order among ties is still the key's, so a keyed table's bytes do not change.
  v_key_cols := archive._key_columns(p_parent);
  v_order_cols := array[p_control] || coalesce(v_key_cols, '{}'::name[]);

  for v_col in
    select a.attname, a.attnotnull, t.typname, t.typtype, t.typcategory, t.typelem, a.atttypmod
    from pg_attribute a join pg_type t on t.oid = a.atttypid
    where a.attrelid = p_parent and a.attnum > 0 and not a.attisdropped
    order by a.attnum
  loop
    v_col_names := v_col_names || v_col.attname;
    v_col_nullable := v_col_nullable || (not v_col.attnotnull);

    if v_col.typtype = 'e' then
      v_col_pgtypes := v_col_pgtypes || 'text'::text; v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 0;
      v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
    elsif v_col.typcategory = 'A' and v_col.typelem <> 0 then
      v_col_pgtypes := v_col_pgtypes || 'array_json'::text; v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 19;
      v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
    else
      case v_col.typname
      when 'int4'        then v_col_pgtypes := v_col_pgtypes || 'int4'::text;        v_col_ptypes := v_col_ptypes || 1; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'int8'        then v_col_pgtypes := v_col_pgtypes || 'int8'::text;        v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'float8'      then v_col_pgtypes := v_col_pgtypes || 'float8'::text;      v_col_ptypes := v_col_ptypes || 5; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'bool'        then v_col_pgtypes := v_col_pgtypes || 'bool'::text;        v_col_ptypes := v_col_ptypes || 0; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'text'        then v_col_pgtypes := v_col_pgtypes || 'text'::text;        v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 0;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'timestamptz' then v_col_pgtypes := v_col_pgtypes || 'timestamptz'::text; v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'timestamp'   then v_col_pgtypes := v_col_pgtypes || 'timestamp'::text;   v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'uuid'        then v_col_pgtypes := v_col_pgtypes || 'uuid'::text;        v_col_ptypes := v_col_ptypes || 7; v_col_converted := v_col_converted || -1;
                              v_col_typelen := v_col_typelen || 16; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'json'        then v_col_pgtypes := v_col_pgtypes || 'text'::text;        v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 19;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'jsonb'       then v_col_pgtypes := v_col_pgtypes || 'text'::text;        v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 19;
                              v_col_typelen := v_col_typelen || null::int4; v_col_scale := v_col_scale || null::int4; v_col_precision := v_col_precision || null::int4;
      when 'numeric'     then
        if v_col.atttypmod = -1 then
          raise exception 'archive._pq_to_parquet_range: column % is numeric with no declared precision/scale; declare it numeric(p,s) to archive it as Parquet DECIMAL', v_col.attname;
        end if;
        select d.p_precision, d.p_scale into v_precision, v_scale from archive._pq_decimal_shape(v_col.atttypmod) d;
        v_col_pgtypes := v_col_pgtypes || 'numeric'::text; v_col_ptypes := v_col_ptypes || 7; v_col_converted := v_col_converted || 5;
        v_col_typelen := v_col_typelen || archive._pq_decimal_byte_width(v_precision); v_col_scale := v_col_scale || v_scale; v_col_precision := v_col_precision || v_precision;
        else raise exception 'archive._pq_to_parquet_range: unsupported column type % for column %', v_col.typname, v_col.attname;
      end case;
    end if;
  end loop;

  v_ncols := array_length(v_col_names, 1);
  if v_ncols is null then
    raise exception 'archive._pq_to_parquet_range: relation % has no supported columns', p_parent;
  end if;

  -- ONE statement, ONE snapshot (#462), in this encoder's own order: the control column leading and
  -- the key columns tiebreaking it (v_order_cols). The range predicate is applied here, once; the
  -- per-column reads below see only the materialised rows, so they need neither the range nor the
  -- key, just the ordinal.
  v_num_rows := archive._pq_snapshot(v_schema, v_table, v_col_names::name[], v_order_cols, p_control, p_lo, p_hi);

  v_body := v_magic;
  for i in 1..v_ncols loop
    -- a NaN is written as null, so a NOT NULL numeric column holding one is OPTIONAL in this file (#635)
    if v_col_pgtypes[i] = 'numeric' and not v_col_nullable[i]
       and archive._pq_has_nan('pg_temp', 'archive_pq_snapshot', v_col_names[i]) then
      v_col_nullable[i] := true;
    end if;
    v_data := archive._pq_encode_column_data(
      p_schema => 'pg_temp', p_table => 'archive_pq_snapshot',
      p_col => v_col_names[i], p_pgtype => v_col_pgtypes[i], p_nullable => v_col_nullable[i],
      p_order_by => array['archive_pq_ord']::name[],
      p_decimal_scale => v_col_scale[i], p_decimal_bytes => v_col_typelen[i]);
    if p_compress then
      v_page_bytes := archive._pq_gzip_compress_dynamic(v_data);
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data), length(v_page_bytes));
    else
      v_page_bytes := v_data;
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data));
    end if;
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_page_bytes;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || archive._pq_build_column_chunk(
        archive._pq_build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset,
          case when p_compress then 2 else 0 end,
          case when p_compress then length(v_page_header) + length(v_page_bytes) else null end));
    v_schema_elements := v_schema_elements || archive._pq_build_schema_leaf(v_col_names[i], v_col_ptypes[i], v_col_converted[i], v_col_nullable[i],
      v_col_typelen[i], v_col_scale[i], v_col_precision[i],
      -- a `timestamp` is a wall clock, not an instant: say so, or readers take TIMESTAMP_MICROS as UTC-adjusted (#465);
      -- a `timestamptz` is an instant: say that too, or DuckDB reads it as a naive TIMESTAMP (#711)
      p_logical_type => case when v_col_pgtypes[i] = 'timestamp' then archive._pq_logical_timestamp_micros(false)
                             when v_col_pgtypes[i] = 'timestamptz' then archive._pq_logical_timestamp_micros(true) end);
  end loop;

  v_row_group := archive._pq_build_row_group(v_column_chunks, length(v_body) - length(v_magic), v_num_rows);

  v_schema_list := array_prepend(archive._pq_build_schema_root(v_ncols), v_schema_elements);
  v_footer := archive._pq_build_file_metadata(v_schema_list, v_num_rows, array[v_row_group]);

  truncate pg_temp.archive_pq_snapshot;  -- emptied, not dropped: the next encode reuses it (#632)
  p_file := v_body || v_footer || archive._pq_reverse_bytes(int4send(length(v_footer))) || v_magic;
  p_num_rows := v_num_rows;
end;
$$;

-- The bytea entry point every existing caller uses: the same encode, minus the count. One select,
-- so there is nothing in it to drift from the encoder above.
create or replace function archive._pq_to_parquet_range(p_parent regclass, p_control name, p_lo text, p_hi text, p_compress boolean default true) returns bytea
language sql as $$
  select c.p_file from archive._pq_to_parquet_range_counted(p_parent, p_control, p_lo, p_hi, p_compress) c;
$$;

-- pgpm_archive's old range-picking, drop-gating, and self-driving-retire-sweep apparatus
-- (archive._file_watermark, archive.file_gate, archive._next_range_partition_aligned,
-- archive._next_range_byte_budget, archive._retire_covered) is gone entirely (issue #240):
-- pgpm._next_archive_chunk/_archive_fully_covered/_archive_step in pgpm_core replaced it.

-- ---------------------------------------------------------------------------
-- The encode/upload transport: given a [lo, hi) range, produce and PUT the
-- archived object, returning what a ledger insert needs. Matching shapes --
-- (p_parent, p_lo, p_hi, p_compress) in, (s3_key, etag, rows_archived) out --
-- called directly by whichever pgpm.archive_to_s3_* strategy (below) a table's
-- config.archive_fn names. Connection settings (bucket/region/endpoint/prefix/
-- vault key names) come from archive.config, not local deployment constants.
--
-- Parquet has no internal-commits variant, and cannot: a Parquet file's footer
-- needs every row group's byte offset, known only once the whole file's bytes
-- exist, so there is no way to COMMIT partway through building one -- a
-- structural fact about the format, not a gap (see README.md's Limits section, #211).
-- ---------------------------------------------------------------------------

-- The stem of a chunk's object key: what sits between `<prefix><schema>.<table>_` and the extension. p_lo
-- is the chunk's NATIVE lo (pgpm._native_type): numeric text for the id kind, timestamptz text for every
-- other kind. Two chunks of one table must never share a key, because the store overwrites whatever
-- object already sits at one while the ledger records both rows as archived (#502).
--
-- The id kind's text is kept whole. It is already `-?[0-9]+(\.[0-9]+)?`, which S3 accepts as is, and
-- the sign and the point are exactly what the digits-only projection this replaces threw away: lo
-- -10000 and lo 10000 collapsed onto one key, and on a numeric control so would 10.5 and 105. A
-- non-negative integer lo produces the same stem as before, so an existing bucket's keys still match.
--
-- A timestamptz text is re-rendered IN UTC before its digits are taken (`2024-01-01 00:00:00+00` ->
-- `2024010100000000`), which is why this function pins TimeZone and DateStyle (#551). Native time text
-- is rendered by whichever session wrote it (pgpm._ts_text pins DateStyle, not the zone), so its digits
-- used to carry the session's offset with the offset's SIGN dropped: 2024-01-01 00:00Z rendered in
-- Asia/Karachi (05:00:00+05) and 10:00Z rendered in America/Bogota (05:00:00-05) both stemmed to
-- 2024010105000005, and the second chunk's PUT overwrote the first. With the offset fixed at +00 the
-- digits name one instant, the stem of a chunk no longer depends on who ticks it, and keys sort by time.
-- A stem written from a UTC session (pg_cron's, usually) is unchanged.
--
-- The digits alone still lost two distinctions (#823). The UTC rendering of a BC instant ends ` BC`
-- (`2024-01-01 00:00:00+00 BC`), and the era was one of the characters thrown away, so a chunk at 2024-01-01
-- BC and one at 2024-01-01 AD of one table shared a key and the second PUT replaced the first while both
-- reported their rows archived. And a fraction of a second has no fixed width, so `00:00:00.1+00` in 2024
-- and `00:00:01+00` in the five-digit year 20240 both left 20240101000000100. So the decimal point is kept
-- and a BC instant's stem ends `BC`: everything after the year is fixed-width once the point marks where a
-- fraction starts (ISO output never ends a fraction in 0, so the last two digits are always the `+00`
-- offset), and the stem reads back to one instant. A whole-second AD instant with a four-digit year has
-- neither, so its stem, every stem written so far in practice, is unchanged.
create or replace function archive._object_stem(p_kind text, p_lo text)
returns text language sql stable set timezone = 'UTC' set datestyle = 'ISO, MDY' as $$
  select case when p_kind = 'id' then p_lo
              else regexp_replace(p_lo::timestamptz::text, '[^0-9.]', '', 'g')
                   || case when p_lo::timestamptz::text like '% BC' then 'BC' else '' end end;
$$;

-- Claims the whole object key p_key for p_parent's p_kind of object holding the rows of relation p_relation
-- (#890, #976, see archive.object_key_claim and archive._owned_key, below) and returns the claim the key
-- holds afterwards: this writer's own when it was free or already this writer's, another writer's when not.
-- ON CONFLICT waits out a concurrent claim of the same key, and the read after it is a new statement, so it
-- sees that claim once committed. The three-argument form (#890) recorded no relation and is dropped.
drop function if exists archive._claim_object_key(text, regclass, text);
create or replace function archive._claim_object_key(p_key text, p_parent regclass, p_kind text, p_relation oid)
returns archive.object_key_claim language plpgsql as $$
declare v archive.object_key_claim;
begin
  insert into archive.object_key_claim (object_key, parent_oid, kind, relation_oid)
    values (p_key, p_parent::oid, p_kind, p_relation)
    on conflict (object_key) do nothing;
  select * into v from archive.object_key_claim k where k.object_key = p_key;
  return v;
end;
$$;

-- Every object key this module writes is assembled here and nowhere else (#872), and every key is CLAIMED
-- here before anything is PUT to it. A key is <base>[.<oid>]<tail>: the base is <prefix><schema>.<name>, the
-- name being p_child when one is given (a synchronous export names its partition) and p_parent's own relname
-- when it is null (an archive_fn chunk names its table); the tail is whatever follows the name, the chunk's
-- _<stem><ext> or the export's <ext>. archive._object_key and archive._child_object_key are the two shapes'
-- entry points, and both only call this. scripts/check_archive_object_keys.py fails CI when a prefix is
-- assembled into a string anywhere else in this file, and tests/archive/db/39 takes every path that writes
-- an object through a namesake.
--
-- The relation is named by IDENTITY, quote_ident(schema) || '.' || quote_ident(name), never by
-- p_parent::text (#551). regclass output leaves the schema out whenever the calling session's search_path
-- reaches the relation, so one table was keyed `events_...` from one session and `public.events_...` from
-- another, and two parents named `evt` in two schemas, sharing a prefix (archive.configure's default
-- `events/` is shared by every table) and each ticked under its own schema's search_path, wrote ONE
-- object: the second PUT overwrote the first while both ledger rows recorded it, and retire() then dropped
-- the first table's partition. The synchronous exports keyed the bare child name the same way until #711.
--
-- A name is not an identity, though, and every path PUTs unconditionally (#822). After the runbook's "drop
-- the table and run pgpm.forget_missing()", which deletes the dropped table's ledger rows, a new managed
-- table taking the same name and prefix archived its [0, 10000) to the same key and replaced the old
-- table's only copy of the rows retire() had dropped; and after the documented to_s3-then-drop workflow, a
-- new table's archive.to_s3 of its same-named partition replaced the dropped table's export the same way
-- (#872, which the #822 fix had left to the synchronous keys). So the base is claimed in
-- archive.object_key_owner by the first relation to write under it, which keeps the shape it always had,
-- and any other relation gets <base>.<oid><tail>. That shape cannot collide with a claimed one: a claimed
-- base never ends in `.` and digits (quote_ident quotes an identifier that starts with a digit or holds a
-- dot), and a chunk's stem holds no underscore, so a chunk key's last `_` ends its base. The claim is taken
-- in the caller's own transaction, before the PUT, so a call that rolls back leaves no claim, and a
-- snapshot missing a concurrent claim can only land on the oid shape, never on another relation's key.
-- What is left is oid reuse: after the OID counter wraps, a relation given a dropped one's oid AND its name
-- could reach the old key again.
--
-- A base claim does not see across the two shapes, though (#890): the export of a relation named
-- <table>_<stem>, under any parent in that schema, spells <prefix><schema>.<table>_<stem><ext>, a chunk key
-- of <table>, under a base of its own, so both base claims succeeded and the export PUT over the chunk, the
-- only copy of the rows retire() dropped (or the chunk over the export, the other way round). So the key is
-- then claimed WHOLE in archive.object_key_claim, by its parent and its kind, and a key another writer
-- holds is not written: the call takes the oid shape instead, which no other writer's key in the plain shape
-- can spell (the argument above), and is refused if even that is held. A refusal rolls the call back whole,
-- so neither claim survives it.
--
-- And the parent and the kind are not the writer's whole identity (#976): the same parent exports any
-- relation in its schema, so a re-run export and the export of a new relation that took a dropped one's
-- name were one writer to the claim, and the second PUT over the first export, after the documented
-- export-then-drop workflow the only copy of the dropped relation's rows. So the claim also records the
-- relation whose rows the object holds (the parent itself for a chunk), resolved here by name in the
-- parent's schema as archive._resolve_child resolved it, and a key held for another relation of the same
-- parent and kind is refused outright: the oid shape names the parent, which is this writer too, so there
-- is no key of its own to divert to. A claim whose relation is unrecorded (made before #976) is refused the
-- same way, since nothing says the relation now spelling its key is the one it holds.
create or replace function archive._owned_key(p_parent regclass, p_prefix text, p_child name, p_tail text)
returns text language plpgsql as $$
declare v_base_q text; v_owner oid; v_key text; v_held archive.object_key_claim; v_relation oid; v_name name;
        v_nsp name; v_kind text := case when p_child is null then 'chunk' else 'export' end;
begin
  select p_prefix || quote_ident(n.nspname) || '.' || quote_ident(coalesce(p_child, c.relname))
    into v_base_q
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = p_parent;
  -- the relation whose rows the object holds (#976): the parent for a chunk, the child for an export
  select n.nspname, coalesce(p_child, c.relname),
         case when p_child is null then c.oid
              else (select r.oid from pg_class r where r.relnamespace = n.oid and r.relname = p_child) end
    into v_nsp, v_name, v_relation
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = p_parent;
  if v_relation is null then
    raise exception 'pg_partition_magician: %.% does not exist; no object key is claimed for it',
      quote_ident(v_nsp), quote_ident(p_child);
  end if;
  insert into archive.object_key_owner (key_base, parent_oid) values (v_base_q, p_parent::oid)
    on conflict (key_base) do nothing
    returning parent_oid into v_owner;
  if v_owner is null then
    select o.parent_oid into v_owner from archive.object_key_owner o where o.key_base = v_base_q;
  end if;
  v_key := v_base_q
      || case when v_owner is not distinct from p_parent::oid then '' else '.' || p_parent::oid::text end
      || p_tail;
  v_held := archive._claim_object_key(v_key, p_parent, v_kind, v_relation);
  if (v_held.parent_oid, v_held.kind) is distinct from (p_parent::oid, v_kind) and v_owner = p_parent::oid then
    v_key := v_base_q || '.' || p_parent::oid::text || p_tail;
    v_held := archive._claim_object_key(v_key, p_parent, v_kind, v_relation);
  end if;
  if (v_held.parent_oid, v_held.kind) is distinct from (p_parent::oid, v_kind) then
    raise exception 'pg_partition_magician: the object key % is already claimed by the % of relation %; refusing to write the % of % over it (archive.object_key_claim)',
      v_key, v_held.kind, v_held.parent_oid, v_kind, p_parent;
  end if;
  if v_held.relation_oid is distinct from v_relation then
    raise exception 'pg_partition_magician: the object key % is already claimed by the % of relation % through %; refusing to write the % of %.% (relation %) over it (archive.object_key_claim)',
      v_key, v_held.kind, coalesce(v_held.relation_oid::text, '(unrecorded)'), p_parent, v_kind,
      quote_ident(v_nsp), quote_ident(v_name), v_relation;
  end if;
  return v_key;
end;
$$;

-- A chunk's object key: <prefix><schema>.<table>_<stem><ext>, or <prefix><schema>.<table>.<oid>_<stem><ext>
-- for a relation that did not claim the name first, or whose plain key an export already holds (#890;
-- archive._owned_key, above). Keys already in
-- pgpm.archive_ledger stay as written: nothing derives a key from a chunk's bounds after the upload, so an
-- existing object stays findable through its row.
create or replace function archive._object_key(p_parent regclass, p_prefix text, p_kind text, p_lo text, p_ext text)
returns text language sql as $$
  select archive._owned_key(p_parent, p_prefix, null, '_' || archive._object_stem(p_kind, p_lo) || p_ext);
$$;

-- Seeds archive.object_key_owner from the keys pgpm.archive_ledger already records (#822), so a table that
-- archived before the claims existed owns its base too, and a new table taking its name after a drop and
-- pgpm.forget_missing() still gets the oid shape. A ledger key's base is the key up to its last `_`; keys
-- already in the oid shape (`.<digits>_` before the stem) name a base that is not theirs and are skipped.
-- Where several relations recorded one base, the earliest archived owns it: if two tables already
-- collided before this release, the first one's surviving objects are the ones left to protect. Run by
-- install, below, on every (re-)install; claims already made are left as they are.
create or replace function archive._claim_archived_key_bases() returns int language sql as $$
  with claimed as (
    insert into archive.object_key_owner (key_base, parent_oid, claimed_at)
    select distinct on (b.key_base) b.key_base, b.parent_oid, b.archived_at
      from (select regexp_replace(l.s3_key, '_[^_]*$', '') as key_base, l.parent_table::oid as parent_oid, l.archived_at
              from pgpm.archive_ledger l
             where l.s3_key like '%\_%' and l.s3_key !~ '\.[0-9]+_[^_]*$') b
     order by b.key_base, b.archived_at, b.parent_oid
    on conflict (key_base) do nothing
    returning 1)
  select count(*)::int from claimed;
$$;
do $$ begin perform archive._claim_archived_key_bases(); end $$;

-- Seeds archive.object_key_claim the same way (#890): every key pgpm.archive_ledger records is a chunk's
-- object, claimed whole for the relation that archived it (the earliest, where several recorded one key), so
-- a chunk archived before the whole-key claims existed cannot be overwritten by an export whose key spells
-- it. Run by install on every (re-)install; claims already made are left as they are.
create or replace function archive._claim_archived_keys() returns int language sql as $$
  with claimed as (
    insert into archive.object_key_claim (object_key, parent_oid, kind, claimed_at, relation_oid)
    select distinct on (l.s3_key) l.s3_key, l.parent_table::oid, 'chunk', l.archived_at, l.parent_table::oid
      from pgpm.archive_ledger l
     where l.s3_key is not null
     order by l.s3_key, l.archived_at, l.parent_table::oid
    on conflict (object_key) do nothing
    returning 1)
  select count(*)::int from claimed;
$$;
do $$ begin perform archive._claim_archived_keys(); end $$;

-- Records the relation of every whole-key claim made before archive.object_key_claim had the column (#976),
-- where it is known: a chunk holds its parent's rows, so its relation is its parent. An export's relation
-- was never recorded and is not guessed from the name its key spells, which a namesake created after the
-- export's relation was dropped spells too; it stays null, and archive._owned_key refuses every export
-- over it. Run by install on every (re-)install; returns how many claims it recorded.
create or replace function archive._record_claim_relations() returns int language sql as $$
  with recorded as (
    update archive.object_key_claim set relation_oid = parent_oid
     where kind = 'chunk' and relation_oid is null
    returning 1)
  select count(*)::int from recorded;
$$;
do $$ begin perform archive._record_claim_relations(); end $$;

-- An archive_fn strategy writes over the object pgpm.archive_ledger records a chunk at only to reproduce that
-- chunk (#975). A chunk's key is derived from its lo alone, and the whole-key claim above admits the same parent
-- and kind, so the claim cannot tell the tick that archived a chunk from a later direct call aimed at its key.
-- #969's range check (archive._refuse_empty_range, below) refuses only an empty or inverted SHAPE. A direct call
-- with the chunk's lo and a shorter hi PUT a subset over the chunk's object while the ledger still recorded
-- [lo, hi) there, and retire() then dropped the partition with the rest of the rows copied nowhere; and after
-- retire() a call with the chunk's own [lo, hi) read no row and PUT an empty object over the only copy.
--
-- So every strategy asks here, with the key it is about to PUT to and the row count of the read it is about to
-- send, after both are known and before anything is sent. Where the ledger records a chunk at that key, the
-- write is admitted only when it reproduces the chunk: the same [lo, hi), compared as the grid's native type
-- (text would refuse a re-run spelling the same instant another way), and the read finding the rows the chunk
-- recorded. That is the re-run the documentation describes: the chunk's own range while its rows are still in
-- the table, which is safe because a covered partition stays write-blocked (#452). A key the ledger records
-- nothing at, which is every key pgpm._archive_step hands a strategy (it resumes past what is recorded), is not
-- this function's business. Looked up within p_parent's own rows: another relation's ledger row cannot name a
-- key p_parent holds, because archive._owned_key has already refused a key claimed by anyone else.
create or replace function archive._refuse_recorded_chunk_overwrite(
  p_routine text, p_parent regclass, p_kind text, p_key text, p_lo text, p_hi text, p_rows bigint)
returns void language plpgsql as $$
declare l record; v_why text;
begin
  for l in select a.lo, a.hi, a.rows_archived from pgpm.archive_ledger a
            where a.parent_table = p_parent and a.s3_key = p_key loop
    if pgpm._native_gt(p_kind, l.lo, p_lo) or pgpm._native_gt(p_kind, p_lo, l.lo)
       or pgpm._native_gt(p_kind, l.hi, p_hi) or pgpm._native_gt(p_kind, p_hi, l.hi) then
      v_why := 'this call''s range is not that chunk''s';
    elsif (l.rows_archived is null and coalesce(p_rows, 0) = 0)
          or (l.rows_archived is not null and p_rows is distinct from l.rows_archived) then
      v_why := format('the read found %s row(s) in it now', coalesce(p_rows, 0));
    end if;
    if v_why is not null then
      raise exception 'pg_partition_magician: % refuses to write [%, %) of % to the object key %: pgpm.archive_ledger records the chunk [%, %) of % row(s) there, and %. That object is the record of the chunk, and once retire() has dropped its partition the only copy of its rows; a re-run may only reproduce it: the chunk''s own [lo, hi), while its rows are still in the table.',
        p_routine, p_lo, p_hi, p_parent, p_key, l.lo, l.hi, coalesce(l.rows_archived::text, 'an unrecorded number of'), v_why;
    end if;
  end loop;
end;
$$;

-- single read, single PUT (optionally one gzip member for the whole body). No pagination, so no
-- tiebreak is needed: a plain `order by` with no LIMIT never splits a run of ties across pages.
--
-- extra_float_digits is pinned for the same reason _object_stem pins TimeZone and DateStyle (#551): the
-- payload is row_to_json text, and a float in it follows the session's setting. Under 0, which ALTER ROLE
-- or ALTER DATABASE can give the tick, every float8 was archived to 15 significant digits and every float4
-- to 6 (123456789.12345679 -> 123456789.123457), the ledger recorded the chunk and retire() then dropped
-- the only exact copy (#781). 1 is shortest-exact, the PostgreSQL 12+ default, so the bytes a default
-- session wrote are unchanged; the SET clause restores the caller's setting on return.
create or replace function archive._encode_upload_ndjson_single(p_parent regclass, p_lo text, p_hi text, p_compress boolean default false)
returns table(s3_key text, etag text, rows_archived bigint)
language plpgsql set extra_float_digits = 1 as $$
declare
  cfg archive.config; pcfg pgpm.config; v_nsp name; v_rel name;
  v_payload text; v_body bytea; v_key text;
  v_key_id text; v_secret text; v_resp record; h record; v_etag text; v_rows bigint;   -- records: no http type named (#984)
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive._encode_upload_ndjson_single: % has no archive.config row', p_parent; end if;
  select * into pcfg from pgpm.config where parent_table = p_parent;
  pcfg := pgpm._control_followed(pcfg);
  if not found then raise exception 'archive._encode_upload_ndjson_single: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- [p_lo, p_hi) as literals of the column's type, rendered in config.partition_tz like every other
  -- reader of a chunk in pgpm_core (#501). On a timestamptz column any zone's rendering names the same
  -- instant. On a naive timestamp or date column the literal's offset is dropped and its WALL CLOCK is
  -- what the predicate compares, so it has to be the wall clock in the zone the grid was recorded in:
  -- left to pgpm._encode's UTC default, a New York grid had its chunk read five hours late here while
  -- covered_hi = p_hi still opened retire()'s drop gate for the rows that were never read.
  --
  -- The row is rendered as row_to_json(t.*), never row_to_json(t): PostgreSQL resolves a bare name as a
  -- COLUMN before it tries a whole-row reference, so on a table with a column named t the bare form was
  -- that column (a composite's fields alone, archived in place of the row, or a raise on a timestamptz),
  -- while `t.*` resolves against the FROM item's alias only (#821). archive.to_s3 renders the same way.
  execute format(
    'select coalesce(string_agg(row_to_json(t.*)::text, e''\n'' order by t.%I), ''''), count(*)
       from %I.%I t where t.%I >= %L and t.%I < %L',
    pcfg.control_column, v_nsp, v_rel, pcfg.control_column,
    pgpm._encode(pcfg.control_kind, p_lo, pcfg.text_time_prefix, pcfg.text_time_width,
                 pcfg.text_time_radix, pcfg.text_time_unit, pcfg.text_time_alphabet,
                 pcfg.text_time_discard_bits, pcfg.text_time_epoch, pcfg.partition_tz),
    pcfg.control_column,
    pgpm._encode(pcfg.control_kind, p_hi, pcfg.text_time_prefix, pcfg.text_time_width,
                 pcfg.text_time_radix, pcfg.text_time_unit, pcfg.text_time_alphabet,
                 pcfg.text_time_discard_bits, pcfg.text_time_epoch, pcfg.partition_tz))
    into v_payload, v_rows;

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  if v_key_id is null or v_secret is null then
    raise exception 'archive._encode_upload_ndjson_single: credentials missing from vault';
  end if;

  -- the whole key, `.gz` included, so the claim names the object the PUT writes (#890)
  v_key := archive._object_key(p_parent, cfg.prefix, pcfg.control_kind, p_lo,
                               case when p_compress then '.ndjson.gz' else '.ndjson' end);
  -- #975: never over a recorded chunk this read does not reproduce
  perform archive._refuse_recorded_chunk_overwrite('archive_to_s3_ndjson', p_parent, pcfg.control_kind, v_key, p_lo, p_hi, v_rows);
  if p_compress then
    v_body := archive._pq_gzip_compress_dynamic(convert_to(v_payload, 'UTF8'));
    v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                              'application/gzip', v_body, v_key_id, v_secret);
  else
    v_resp := archive.s3_signed_request('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                       'application/x-ndjson', v_payload, v_key_id, v_secret);
  end if;
  if v_resp.status not between 200 and 299 then
    raise exception 'archive._encode_upload_ndjson_single: PUT of % failed: HTTP % %', v_key, v_resp.status, left(v_resp.content, 200);
  end if;
  foreach h in array v_resp.headers loop
    if lower(h.field) = 'etag' then v_etag := h.value; end if;
  end loop;

  s3_key := v_key; etag := v_etag; rows_archived := v_rows;
  return next;
end;
$$;

-- archive._encode_upload_ndjson_commits, the third format (per-part-COMMIT, for an otherwise-
-- unbounded single read) is gone (issue #240): its only caller was the deleted archive.archive_range,
-- and the archive_fn strategies below cannot use a COMMIT-ing procedure anyway -- archive_fn is a
-- plain function, and PL/pgSQL forbids transaction control inside one regardless of call context.
-- They don't need to: pgpm._next_archive_chunk already bounds every call's own [lo, hi) to
-- config.archive_byte_budget before archive_fn ever runs, so the vacuum-horizon hold is already
-- small by construction.

-- thin wrapper around the range-based Parquet encoder + a PUT.
create or replace function archive._encode_upload_parquet(p_parent regclass, p_lo text, p_hi text, p_compress boolean default true)
returns table(s3_key text, etag text, rows_archived bigint)
language plpgsql as $$
declare
  cfg archive.config; pcfg pgpm.config;
  v_payload bytea; v_key text; v_key_id text; v_secret text; v_lo_lit text; v_hi_lit text;
  v_resp record; h record; v_etag text; v_rows bigint;   -- records: no http type named (#984)
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive._encode_upload_parquet: % has no archive.config row', p_parent; end if;
  select * into pcfg from pgpm.config where parent_table = p_parent;
  pcfg := pgpm._control_followed(pcfg);
  if not found then raise exception 'archive._encode_upload_parquet: % is not managed', p_parent; end if;

  -- in config.partition_tz, for the reason given in _encode_upload_ndjson_single (#501)
  v_lo_lit := pgpm._encode(pcfg.control_kind, p_lo, pcfg.text_time_prefix, pcfg.text_time_width,
                           pcfg.text_time_radix, pcfg.text_time_unit, pcfg.text_time_alphabet,
                           pcfg.text_time_discard_bits, pcfg.text_time_epoch, pcfg.partition_tz);
  v_hi_lit := pgpm._encode(pcfg.control_kind, p_hi, pcfg.text_time_prefix, pcfg.text_time_width,
                           pcfg.text_time_radix, pcfg.text_time_unit, pcfg.text_time_alphabet,
                           pcfg.text_time_discard_bits, pcfg.text_time_epoch, pcfg.partition_tz);
  -- The file and its row count come out of the same read (#462). rows_archived used to be a count(*)
  -- run after the encode, a statement later and a snapshot apart, so under a concurrent write it
  -- matched neither the file nor the child. The counted encoder reports how many rows the one
  -- snapshot it encoded held, which is what the ledger row is meant to record.
  select c.p_file, c.p_num_rows into v_payload, v_rows
    from archive._pq_to_parquet_range_counted(p_parent, pcfg.control_column, v_lo_lit, v_hi_lit, p_compress) c;

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  if v_key_id is null or v_secret is null then
    raise exception 'archive._encode_upload_parquet: credentials missing from vault';
  end if;

  v_key := archive._object_key(p_parent, cfg.prefix, pcfg.control_kind, p_lo, '.parquet');
  -- #975: as _encode_upload_ndjson_single's
  perform archive._refuse_recorded_chunk_overwrite('archive_to_s3_parquet', p_parent, pcfg.control_kind, v_key, p_lo, p_hi, v_rows);
  v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                            'application/vnd.apache.parquet', v_payload, v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then
    raise exception 'archive._encode_upload_parquet: PUT of % failed: HTTP % %', v_key, v_resp.status, left(v_resp.content, 200);
  end if;
  foreach h in array v_resp.headers loop
    if lower(h.field) = 'etag' then v_etag := h.value; end if;
  end loop;

  s3_key := v_key; etag := v_etag; rows_archived := v_rows;
  return next;
end;
$$;

-- pgpm_archive's old paced worker (archive.archive_range/archive_partition/_tick_one/tick/run_all,
-- driven by archive.config's boundary_rule/drop_trigger knobs and a pgpm-archiver pg_cron job) is
-- gone entirely (issue #240): pgpm.maintain()'s own archive_fn-driven chunking replaced it, with no
-- second scheduled job -- archiving now rides maintain()'s existing cadence.

-- ---------------------------------------------------------------------------
-- The synchronous functions: archive a partition INLINE, called directly (no
-- ledger, no automatic scheduling), just archive.config's connection
-- settings.
-- ---------------------------------------------------------------------------

-- Both synchronous functions take the child as a NAME, and a name is only a relation relative to a
-- schema. This resolves it in p_parent's schema, never through the caller's search_path:
-- archive.to_s3_parquet used to cast the bare name to regclass, so a session whose search_path did
-- not reach the parent's schema was refused the real child with `relation does not exist`, and once
-- any relation of that name existed in public, that relation's rows went out under the partition's
-- key (issue #464). archive.to_s3 always read `%I.%I` off the parent's namespace and was right about
-- the schema, but a name in the right schema can still be the wrong relation.
--
-- So, second, the resolved oid is compared against the one pgpm.part recorded when the partition
-- entered it, exactly as the automatic path's pgpm._archive_step does before it reads a child
-- (fail_archive_identity, #421): this is the manual path's twin of that check. A raise rather than a
-- log row, because there is no tick to skip and the caller is a session that will read the error.
-- A null child_oid is unanchored and skips the comparison, same as everywhere else, so an upgrade
-- never wedges a manual archive it has nothing to compare against; and a name pgpm.part has no row
-- for at all is resolved but not checked, since the synchronous functions never required the child
-- to be tracked.
--
-- And third, the relation resolved is HELD (#1030): ACCESS SHARE, to the end of the caller's transaction,
-- the lock every read of it takes anyway. Each export resolves its child, claims its object key for that
-- oid (archive._owned_key) and reads it, all in one transaction, and archive.to_s3 used to read it later
-- by name with nothing held in between. A second session that dropped the child and created another
-- relation by its name in that window had the export read the NEW relation's rows and PUT them under the
-- OLD relation's claim, over its export: after the documented export-then-drop workflow, the only copy of
-- those rows. Held, a concurrent DROP, RENAME or ALTER of the child waits until the export has committed.
-- LOCK TABLE resolves the name again once the lock is granted, so the oid read after it is the relation
-- held; one that differs from the first resolution was dropped or replaced while this waited, and is
-- refused rather than exported in its place.
create or replace function archive._resolve_child(p_parent regclass, p_child name, p_caller text)
returns regclass language plpgsql as $$
declare v_nsp name; v_now regclass; v_held regclass; v_anchor oid;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_now := to_regclass(format('%I.%I', v_nsp, p_child));
  if v_now is null then
    raise exception 'pg_partition_magician: %.% does not exist; % resolves p_child in the schema of p_parent, not through search_path',
      quote_ident(v_nsp), quote_ident(p_child), p_caller;
  end if;
  execute format('lock table %I.%I in access share mode', v_nsp, p_child);
  v_held := to_regclass(format('%I.%I', v_nsp, p_child));
  if v_held is distinct from v_now then
    raise exception 'pg_partition_magician: %.% was dropped or replaced while % was resolving it (oid % then, % now); refusing to export it',
      quote_ident(v_nsp), quote_ident(p_child), p_caller, v_now::oid, coalesce(v_held::oid::text, 'none');
  end if;
  select p.child_oid into v_anchor from pgpm.part p where p.parent_table = p_parent and p.child_name = p_child;
  if v_anchor is not null and v_now::oid <> v_anchor then
    raise exception 'pg_partition_magician: %.% is oid % now, not the oid % recorded for this partition; refusing to archive it',
      quote_ident(v_nsp), quote_ident(p_child), v_now::oid, v_anchor;
  end if;
  return v_now;
end;
$$;

-- The object key of a synchronous export, <prefix><schema>.<child><ext>, or <prefix><schema>.<child>.<oid><ext>
-- for a parent that did not claim the name first, or whose plain key a chunk already holds (#890: a child
-- named <table>_<stem> spells a chunk key of <table>; archive._owned_key, above, which assembles every key).
-- The child is named by IDENTITY with p_parent's schema, the one _resolve_child read the child from.
-- archive.to_s3 and archive.to_s3_parquet keyed on <prefix><child><ext>, the bare name, and pgpm names a
-- child after its parent's relname, so two parents named `evt` in two schemas sharing a prefix exported
-- their [0, 10000) partitions to ONE key (#711). Then the schema-qualified key had no owner, so a table
-- created after the first was dropped and forgotten exported its same-named partition over the first one's
-- export, after the documented to_s3-then-drop workflow the only copy of those rows (#872). Both functions
-- take their key from here and nowhere else.
create or replace function archive._child_object_key(p_parent regclass, p_prefix text, p_child name, p_ext text)
returns text language sql as $$
  select archive._owned_key(p_parent, p_prefix, p_child, p_ext);
$$;

-- Aborts every multipart upload in flight at exactly p_key, returning how many it aborted. This is
-- how archive.to_s3 cleans up after an initiate it never saw the answer to (issue #636): a cancel or
-- an error inside the CreateMultipartUpload POST can land after the store created the upload and
-- before its UploadId reached the caller, so there is no id to abort by, only the key. S3 lists
-- uploads by key PREFIX, so the listing is filtered to the exact key: an upload at a longer key this
-- one is a prefix of belongs to another object and is left alone. Any upload in flight at the key is
-- taken, which also clears one an earlier failed export leaked there; a concurrent export of the
-- SAME object from another session would lose its upload and fail loudly at its next part or at
-- complete, never silently.
--
-- Every page of the listing is read, p_page_size uploads at a time (S3's own maximum, 1000, by
-- default), following the key and upload-id markers while the store says the listing is truncated
-- (#711). It used to read the first page only, so past the thousandth upload under the prefix an
-- orphan at the key could be left in flight. The ids are collected first and aborted after the last
-- page, so no abort moves the listing under the markers. MinIO leaves NextKeyMarker empty, so the last
-- listed upload's key stands in for it; a page that does not move the markers ends the read rather
-- than repeating it.
create or replace function archive._s3_abort_uploads_at(
  p_endpoint text, p_bucket text, p_region text, p_key text, p_key_id text, p_secret text,
  p_page_size int default 1000
) returns int language plpgsql as $$
declare
  v_resp record; v_doc xml; v_ids text[] := '{}'; v_page_ids text[]; v_id text; n int := 0;   -- record: #984
  v_key_marker text; v_id_marker text; v_truncated text; v_next_key text; v_next_id text; v_last_key text;
begin
  if p_page_size is null or p_page_size < 1 then
    raise exception 'archive._s3_abort_uploads_at: p_page_size must be a positive number of uploads, not %', p_page_size;
  end if;
  loop
    -- the canonical query string: keys in byte order, values percent-encoded
    v_resp := archive.s3_signed_request('GET', p_endpoint, p_bucket, p_region, '',
                case when v_key_marker is null then '' else 'key-marker=' || archive.s3_url_encode(v_key_marker) || '&' end
             || 'max-uploads=' || p_page_size || '&prefix=' || archive.s3_url_encode(p_key)
             || case when v_id_marker is null then '' else '&upload-id-marker=' || archive.s3_url_encode(v_id_marker) end
             || '&uploads=',
                'text/plain', '', p_key_id, p_secret);
    if v_resp.status not between 200 and 299 then
      raise exception 'archive._s3_abort_uploads_at: listing uploads at % failed: HTTP % %', p_key, v_resp.status, left(v_resp.content, 200);
    end if;
    v_doc := v_resp.content::xml;
    -- xmltable, not xpath(): its text columns are the unescaped values, so a key holding & or < compares
    select coalesce(array_agg(u.upload_id order by u.ord), '{}')
      into v_page_ids
      from xmltable('//*[local-name()=''Upload'']' passing v_doc
                    columns ord for ordinality,
                            upload_key text path '*[local-name()=''Key'']',
                            upload_id  text path '*[local-name()=''UploadId'']') u
     where u.upload_key = p_key
    ;
    v_ids := v_ids || v_page_ids;
    select x.truncated, nullif(x.next_key, ''), nullif(x.next_id, '')
      into v_truncated, v_next_key, v_next_id
      from xmltable('/*' passing v_doc
                    columns truncated text path '*[local-name()=''IsTruncated'']',
                            next_key  text path '*[local-name()=''NextKeyMarker'']',
                            next_id   text path '*[local-name()=''NextUploadIdMarker'']') x;
    exit when v_truncated is distinct from 'true';
    select u.upload_key into v_last_key
      from xmltable('//*[local-name()=''Upload'']' passing v_doc
                    columns ord for ordinality, upload_key text path '*[local-name()=''Key'']') u
     order by u.ord desc limit 1;
    v_next_key := coalesce(v_next_key, v_last_key);
    exit when v_next_key is null
           or (v_next_key is not distinct from v_key_marker and v_next_id is not distinct from v_id_marker);
    v_key_marker := v_next_key; v_id_marker := v_next_id;
  end loop;
  foreach v_id in array v_ids loop
    perform archive.s3_signed_request('DELETE', p_endpoint, p_bucket, p_region, p_key,
                                     'uploadId=' || archive.s3_url_encode(v_id),
                                     'text/plain', '', p_key_id, p_secret);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- archive.to_s3's keyset cursor, as text that reads back as the same value in ANY session (#834). The
-- cursor's control value travels from one page's query to the next as text and is cast back with
-- `$1::<type>` in the caller's session. Rendered in that session's own DateStyle and TimeZone, a
-- timestamptz named its zone by ABBREVIATION under any non-ISO DateStyle, and several zones' own
-- abbreviations read back as another zone: Asia/Shanghai's `CST` is read as US Central, so under
-- DateStyle Postgres the cursor landed 14 hours past the last paged row, the next page skipped every
-- row in between, and the conservation check refused every multi-page export with nothing writing.
-- Pinned the way archive._object_stem is (#551), the text is ISO with a numeric offset of +00
-- (`2024-01-01 00:00:00+00`), which every DateStyle and TimeZone reads back as the same instant; a
-- `timestamp` or `date` is ISO too, and every other control type's text does not depend on either
-- setting. Called once per page, on the page's last value, never per row.
create or replace function archive._cursor_text(p_value anyelement)
returns text language sql stable set timezone = 'UTC' set datestyle = 'ISO, MDY' as $$
  select p_value::text;
$$;

-- Small partitions (one part's worth or less) take a plain single PUT; bigger ones stream
-- through S3 multipart, holding at most one part in memory at a time. With archive.config.compress
-- on, the same two paths carry a gzip stream instead of plain NDJSON (the fold inside the loop says
-- how), at <prefix><schema>.<child>.ndjson.gz. extra_float_digits is pinned to shortest-exact for the
-- reason given at archive._encode_upload_ndjson_single (#781): row_to_json renders a float by the session's
-- setting, and the conservation fingerprint below hashes that same text on both sides, so it could not see
-- a float rounded to 15 digits.
create or replace function archive.to_s3(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql set extra_float_digits = 1 as $$
declare
  cfg archive.config; pcfg pgpm.config; v_ctltype text;
  v_gzip boolean; v_ctype text; v_body bytea := '';
  v_key_id text; v_secret text; v_nsp name; v_key text;
  v_child regclass;   -- the relation resolved, held and claimed; every read below goes by it, never by name (#1030)
  v_part_payload text; v_chunk text; v_cursor text; v_cursor_tid tid; v_done boolean := false;
  v_page_rows bigint; v_written bigint := 0; v_expected bigint;
  v_page_h numeric; v_written_h numeric := 0; v_expected_h numeric;   -- the rows' identity, not only their count (#673)
  v_upload_id text; v_part int := 0; v_etag text; v_parts_xml text := '';
  v_initiating boolean := false;
  v_resp record; h record;   -- records: no http type named, so any session search_path compiles this (#984)
begin
  -- #969: refused before anything is read or sent. p_lo and p_hi are not read (the export is the whole
  -- partition), so their null is accepted.
  perform pgpm._refuse_null_arguments('archive.to_s3', json_build_object('p_parent', p_parent, 'p_child', p_child));
-- The export runs in its own block so that a CANCEL can reach the multipart abort as well as an
-- error. `when others` does not catch query_canceled (57014), so a statement_timeout or a
-- pg_cancel_backend used to leave the upload and its parts in the bucket (issue #595). Naming the
-- cancel in the same handler is not enough: a cancel that arrives while another error is being raised
-- stays pending into the handler and is taken at its first statement, outside any scope that catches
-- it, and a statement_timeout landing inside a pgsql-http transfer was measured to arrive that way
-- (a handler naming query_canceled still leaked the upload against MinIO). The enclosing block's
-- handler catches the cancel wherever it surfaced, in the export or in the handler below, and aborts
-- whatever upload is still recorded as in flight.
<<export>>
begin
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive.to_s3: % has no archive.config row', p_parent; end if;
  select * into pcfg from pgpm.config where parent_table = p_parent;
  pcfg := pgpm._control_followed(pcfg);
  if not found then raise exception 'archive.to_s3: % is not managed', p_parent; end if;
  -- archive.configure refuses this now (#594), but a row written before it did, or by a raw UPDATE,
  -- still reaches here: with part_bytes <= 0 the read loop below never reads, and the part loop PUTs
  -- empty parts until the store refuses part 10001. Refuse before anything is sent.
  if cfg.part_bytes <= 0 then
    raise exception 'archive.to_s3: % has archive.config.part_bytes %; it must be a positive number of bytes (set it with archive.configure)',
      p_parent, cfg.part_bytes;
  end if;
  -- the same for fetch_rows (#636): 0 would read no page and a negative value fails on LIMIT
  if cfg.fetch_rows < 1 then
    raise exception 'archive.to_s3: % has archive.config.fetch_rows %; it must be a positive number of rows (set it with archive.configure)',
      p_parent, cfg.fetch_rows;
  end if;

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  if v_key_id is null or v_secret is null then
    raise exception 'archive.to_s3: credentials missing from vault';
  end if;

  -- identity before any read of the child (#464), held to the end of this transaction (#1030); and the
  -- caller's row-level security on it (#873), since the export and its conservation check both read it as
  -- the caller and would agree on an object holding only the rows its policies admit
  v_child := archive._resolve_child(p_parent, p_child, 'archive.to_s3');
  perform pgpm._refuse_filtered_reads(v_child, 'export', 'the object would hold only those rows');
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select a.atttypid::regtype::text into v_ctltype
    from pg_attribute a where a.attrelid = p_parent and a.attname = pcfg.control_column;
  -- The object's form follows archive.config.compress, as it does on every other path this module
  -- ships (#520): plain NDJSON at <prefix><schema>.<child>.ndjson or, with the flag on, a GZIP stream
  -- at <prefix><schema>.<child>.ndjson.gz, the suffix the automatic NDJSON strategy already uses for a
  -- compressed object. The flag is read here, once, and nowhere else in this function. The key names
  -- the child with its schema (archive._child_object_key, #711).
  v_gzip := cfg.compress;
  if v_gzip then
    v_key := archive._child_object_key(p_parent, cfg.prefix, p_child, '.ndjson.gz'); v_ctype := 'application/gzip';
  else
    v_key := archive._child_object_key(p_parent, cfg.prefix, p_child, '.ndjson');    v_ctype := 'application/x-ndjson';
  end if;

  -- Conservation (#673): every page's rows are summed into a count AND a content fingerprint (a sum of
  -- 64-bit hashes of each exported line, as numeric so it cannot overflow), and after the last page both
  -- are compared with the partition as it stands then; the export is refused rather than completed when
  -- they differ (below), so a paging defect or a concurrent writer surfaces as an error, never as a 200
  -- with rows missing. It used to compare a row COUNT taken as the export began, and a count is
  -- invariant under compensating writes: one UPDATE that moved a row not yet paged behind the cursor
  -- (-1) and a paged row ahead of it (+1) passed it, and the object landed without a row the partition
  -- held before and after. The fingerprint hashes the very text each line carries (row_to_json, rendered
  -- by this session in both reads), so equal fingerprints mean the object holds exactly the rows the
  -- partition holds after the last page, whatever order or snapshot each page was read in. Both reads
  -- render the row as row_to_json(t.*), the whole-row reference a column named t cannot shadow (#821, see
  -- archive._encode_upload_ndjson_single).

  v_part_payload := '';
  v_cursor := null; v_cursor_tid := null;
  <<parts>>
  loop
    while not v_done and octet_length(v_part_payload) < cfg.part_bytes loop
      -- Page by the TOTAL order (control, ctid), never by the control column alone. The control column
      -- need not be unique, and a cursor set to a page's max(control) lands ON a run of equal values
      -- when the page boundary falls inside one; the next page's `> cursor` then skips the rest of the
      -- run (issue #463). ctid breaks the tie and is stable for the whole export because nothing here
      -- moves tuples: the automatic path exports a write-blocked child, and this synchronous path
      -- leaves quiescence to the caller (a concurrent UPDATE or VACUUM FULL cannot lose rows silently
      -- either, it trips the conservation check below). The planner derives the `control >= cursor`
      -- index condition from the row comparison itself, so an index on the control column still
      -- drives each page. The cursor's control value crosses to the next page as text rendered by
      -- archive._cursor_text, never in this session's DateStyle and TimeZone (#834). The child is read as
      -- v_child, the relation resolved and claimed, never as its schema and name (#1030): a regclass renders
      -- as the name that reaches that oid in this session at the moment of rendering, so a schema renamed
      -- away and a namesake created in its place cannot stand in for it.
      execute format(
        'select coalesce(string_agg(j, e''\n'' order by k, c), ''''),
                archive._cursor_text((array_agg(k order by k desc, c desc))[1]),
                (array_agg(c order by k desc, c desc))[1],
                count(*), coalesce(sum(hashtextextended(j, 0)), 0)
           from (select row_to_json(t.*)::text as j, t.%I as k, t.ctid as c from %s t
                  where $1 is null or (t.%I, t.ctid) > ($1::%s, $2)
                  order by t.%I, t.ctid limit $3) s',
        pcfg.control_column, v_child::text, pcfg.control_column, v_ctltype, pcfg.control_column)
        into v_chunk, v_cursor, v_cursor_tid, v_page_rows, v_page_h using v_cursor, v_cursor_tid, cfg.fetch_rows;
      if v_page_rows = 0 then v_done := true;
      else
        v_written := v_written + v_page_rows; v_written_h := v_written_h + v_page_h;
        v_part_payload := v_part_payload || v_chunk || e'\n';
      end if;
    end loop;

    -- The last page has been read: everything past this point only uploads. Refuse here, before the
    -- single PUT or the final part, so a short export never becomes a complete object; the handler
    -- below aborts an in-flight multipart upload on the way out. The partition is read once more, in a
    -- snapshot later than every page's, and must hold exactly the rows that were paged (#673).
    if v_done then
      execute format('select count(*), coalesce(sum(hashtextextended(row_to_json(t.*)::text, 0)), 0) from %s t',
                     v_child::text) into v_expected, v_expected_h;
      if v_written <> v_expected or v_written_h <> v_expected_h then
        raise exception 'pg_partition_magician: archive.to_s3 of %.% %, after the last page; a write changed the partition during the export, so refusing to write an incomplete object',
          v_nsp, p_child,
          case when v_written <> v_expected
            then format('paged %s rows but the partition holds %s', v_written, v_expected)
            else format('paged %s rows and the partition holds %s, but not the same rows (their content fingerprints differ)', v_written, v_expected)
          end;
      end if;
    end if;

    -- Fold the text chunk into the outgoing part body. Plain, the body IS the chunk's bytes. Compressed,
    -- the chunk becomes one gzip member appended to the body, and the body is not sent until it is a
    -- full part: S3 and MinIO refuse a non-final multipart part under 5 MiB (EntityTooSmall), and a
    -- compressed chunk is usually far under it. Concatenated members are one valid gzip file (RFC
    -- 1952 section 2.2), which is how gunzip, zcat, Python's gzip, DuckDB and Hadoop read them, so the
    -- compressed export keeps the plain one's bound of one text chunk and one part body in memory at
    -- a time. An empty partition still gets one member (header, an empty block, CRC-32 0, ISIZE 0), so
    -- the object at the .gz key is always a gzip file a reader can open.
    if v_gzip then
      if v_part_payload <> '' or (v_part = 0 and octet_length(v_body) = 0) then
        v_body := v_body || archive._pq_gzip_compress_dynamic(convert_to(v_part_payload, 'UTF8'));
      end if;
    else
      v_body := convert_to(v_part_payload, 'UTF8');
    end if;
    v_part_payload := '';
    continue parts when v_gzip and not v_done and octet_length(v_body) < cfg.part_bytes;

    exit parts when v_done and v_part > 0 and octet_length(v_body) = 0;

    -- Both bodies go through the bytea signer: the plain one is the same bytes the text signer would
    -- have hashed and sent, and the compressed one is binary.
    if v_part = 0 and v_done then
      v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                                v_ctype, v_body, v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive.to_s3: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      return;
    end if;

    if v_part = 0 then
      -- From here until v_upload_id is set, the store may hold an upload whose id this function has
      -- not seen: a cancel or an error inside the POST, after the store acted on it, left that upload
      -- with nothing to abort it (issue #636). v_initiating says so to both handlers, which then find
      -- it by its key instead of by its id.
      v_initiating := true;
      v_resp := archive.s3_signed_request('POST', cfg.endpoint, cfg.bucket, cfg.region, v_key, 'uploads=',
                                         v_ctype, '', v_key_id, v_secret);
      if v_resp.status not between 200 and 299 then
        raise exception 'archive.to_s3: initiate multipart for % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
      end if;
      v_upload_id := (xpath('//*[local-name()=''UploadId'']/text()', v_resp.content::xml))[1]::text;
      v_initiating := false;
    end if;

    v_part := v_part + 1;
    v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                              'partNumber=' || v_part || '&uploadId=' || archive.s3_url_encode(v_upload_id),
                                              v_ctype, v_body, v_key_id, v_secret);
    if v_resp.status not between 200 and 299 then
      raise exception 'archive.to_s3: part % of % failed: HTTP % %', v_part, p_child, v_resp.status, left(v_resp.content, 200);
    end if;
    v_etag := null;
    foreach h in array v_resp.headers loop
      if lower(h.field) = 'etag' then v_etag := h.value; end if;
    end loop;
    v_parts_xml := v_parts_xml || format('<Part><PartNumber>%s</PartNumber><ETag>%s</ETag></Part>', v_part, v_etag);
    v_body := '';
    exit parts when v_done;
  end loop;

  -- complete. S3's one famous quirk: complete can return HTTP 200 with an <Error> body, so check both.
  v_resp := archive.s3_signed_request('POST', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                     'uploadId=' || archive.s3_url_encode(v_upload_id),
                                     'application/xml',
                                     '<CompleteMultipartUpload>' || v_parts_xml || '</CompleteMultipartUpload>',
                                     v_key_id, v_secret);
  if v_resp.status not between 200 and 299 or v_resp.content like '%<Error>%' then
    raise exception 'archive.to_s3: complete multipart for % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
  end if;
exception when others then
  -- abort the in-flight upload so no invisible incomplete parts accrue storage, then re-raise so
  -- retain() keeps the partition. (Belt and braces: also set a bucket lifecycle rule that expires
  -- incomplete multipart uploads, for the day even this abort cannot reach S3.)
  if v_upload_id is not null then
    begin
      perform archive.s3_signed_request('DELETE', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                       'uploadId=' || archive.s3_url_encode(v_upload_id),
                                       'text/plain', '', v_key_id, v_secret);
    exception when others then null;
    end;
    -- attempted: the enclosing handler need not send it again. A cancel that cut this handler short
    -- never gets here, so the id is still set for that handler to abort.
    v_upload_id := null;
  elsif v_initiating then
    begin
      perform archive._s3_abort_uploads_at(cfg.endpoint, cfg.bucket, cfg.region, v_key, v_key_id, v_secret);
    exception when others then null;
    end;
    v_initiating := false;
  end if;
  raise;
end export;
exception when query_canceled then
  -- a cancel, from the export or from the handler above before it could abort (see the top of the
  -- body). It is taken by now, so this DELETE runs; the cancel is re-raised either way.
  if v_upload_id is not null then
    begin
      perform archive.s3_signed_request('DELETE', cfg.endpoint, cfg.bucket, cfg.region, v_key,
                                       'uploadId=' || archive.s3_url_encode(v_upload_id),
                                       'text/plain', '', v_key_id, v_secret);
    exception when others then null;
    end;
  elsif v_initiating then
    begin
      perform archive._s3_abort_uploads_at(cfg.endpoint, cfg.bucket, cfg.region, v_key, v_key_id, v_secret);
    exception when others then null;
    end;
  end if;
  raise;
end;
$$;

-- The Parquet function: single PUT, same shape and ceiling as archive.to_s3's basic (non-multipart)
-- variant. archive._pq_to_parquet materialises every column in ONE statement (archive._pq_snapshot,
-- #462) and encodes from that, so a write that commits mid-encode is either wholly in the file or
-- wholly out of it, never in some columns and not others. Snapshot and encode run inside this one
-- transaction, so the vacuum horizon is held for the whole read+upload, structurally, not as an
-- oversight. What this function does NOT have is a write fence: unlike the archive_fn path, whose
-- child is pgpm_write_block'ed before it is archived, nothing here stops a writer, so a row that
-- commits after the snapshot is simply not in the file. Quiesce the partition first, or use the
-- automatic path (README).
create or replace function archive.to_s3_parquet(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  cfg archive.config; v_child regclass;
  v_key_id text; v_secret text; v_key text; v_payload bytea; v_resp record;   -- record: #984
begin
  -- #969: as archive.to_s3's (p_lo and p_hi are not read)
  perform pgpm._refuse_null_arguments('archive.to_s3_parquet', json_build_object('p_parent', p_parent, 'p_child', p_child));
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'archive.to_s3_parquet: % has no archive.config row', p_parent; end if;

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  if v_key_id is null or v_secret is null then
    raise exception 'archive.to_s3_parquet: credentials missing from vault';
  end if;

  -- in the parent's schema and checked against pgpm.part's oid (#464), not `p_child::regclass`,
  -- which resolved the bare name through the caller's search_path
  v_child := archive._resolve_child(p_parent, p_child, 'archive.to_s3_parquet');
  perform pgpm._refuse_filtered_reads(v_child, 'export', 'the object would hold only those rows');   -- #873
  v_payload := archive._pq_to_parquet(v_child, cfg.compress);
  v_key := archive._child_object_key(p_parent, cfg.prefix, p_child, '.parquet');   -- named with its schema (#711)

  v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                            'application/vnd.apache.parquet', v_payload, v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then
    raise exception 'archive.to_s3_parquet: PUT of % failed: HTTP % %', p_child, v_resp.status, left(v_resp.content, 200);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- archive_fn-conforming S3 strategies (issue #239): the same transport as the
-- synchronous functions above (archive._encode_upload_ndjson_single /
-- archive._encode_upload_parquet), adapted to pgpm.config.archive_fn's calling contract --
-- (p_parent, p_child, p_lo, p_hi) returns pgpm.archive_result -- so a table can set
-- archive_fn directly and ride pgpm.maintain()'s own byte-budget chunking
-- (pgpm._next_archive_chunk/_archive_step, #237). Connection settings (bucket/region/endpoint/
-- prefix/vault key names/compress) still come from archive.config -- one config surface, not two.
--
-- archive._encode_upload_ndjson_commits (the third format, with internal COMMITs to bound an
-- otherwise-unbounded single read) has no archive_fn counterpart and is gone (#240): archive_fn is
-- a plain FUNCTION, and PL/pgSQL forbids transaction control inside a function regardless of call
-- context, so it could never call a COMMIT-ing procedure anyway. It also doesn't need to --
-- pgpm._next_archive_chunk already bounds every call's own [lo, hi) to
-- config.archive_byte_budget before archive_fn ever runs, so the vacuum-horizon hold this
-- call needs to bound is already small by construction, the same goal ndjson_commits'
-- internal commits existed to reach a different way.
--
-- p_child is part of the archive_fn contract's required shape but unused here:
-- archive._encode_upload_ndjson_single/_encode_upload_parquet already scope their read to
-- [p_lo, p_hi) off p_parent directly, which pgpm._next_archive_chunk guarantees never spans
-- more than p_child's own bounds.
--
-- archive.to_s3/archive.to_s3_parquet (the synchronous functions above) are untouched and keep
-- working exactly as before; the paced worker they used to sit alongside is gone entirely (#240).

-- The range an archive_fn strategy is handed must hold something (#969). A chunk's object key is derived
-- from its lo alone (archive._object_key), so a call for [lo, lo), or for a range whose hi is below its lo,
-- read no row and PUT an empty object over the key the chunk [lo, hi) was archived to, which after retire()
-- dropped the partition is the only copy of its rows. pgpm._next_archive_chunk never asks for such a range;
-- a direct call could, and nothing refused it. Compared as the grid's native type (numeric for an id grid,
-- timestamptz otherwise), never as text, where '9' sorts after '10'.
create or replace function archive._refuse_empty_range(p_routine text, p_parent regclass, p_lo text, p_hi text)
returns void language plpgsql as $$
declare v_kind text;
begin
  select c.control_kind into v_kind from pgpm.config c where c.parent_table = p_parent;
  if not found then
    raise exception 'pg_partition_magician: % cannot archive a chunk of % -- it is not managed by pgpm', p_routine, p_parent;
  end if;
  if not pgpm._native_gt(v_kind, p_hi, p_lo) then
    raise exception 'pg_partition_magician: % refuses the range [%, %) of % -- it is empty or inverted, and the object key is derived from lo alone, so the call would read no row and write an empty object over the one the chunk at % was archived to. Pass the chunk''s own [lo, hi).',
      p_routine, p_lo, p_hi, p_parent, p_lo;
  end if;
end;
$$;

create or replace function pgpm.archive_to_s3_ndjson(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare
  cfg archive.config; v_result pgpm.archive_result;
  v_s3_key text; v_etag text; v_rows bigint;
begin
  -- #969: refused before anything is read or sent. p_child is not read (the chunk is read through the
  -- parent), so its null is accepted. A null p_lo died raw on archive.object_key_claim's NOT NULL, and a
  -- null p_hi read no row and PUT an empty object over the chunk's key, which is derived from p_lo alone.
  perform pgpm._refuse_null_arguments('archive_to_s3_ndjson', json_build_object('p_parent', p_parent, 'p_lo', p_lo, 'p_hi', p_hi));
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'pgpm.archive_to_s3_ndjson: % has no archive.config row', p_parent; end if;
  -- #969: and an empty or inverted range, before anything is read or sent. The key is derived from p_lo
  -- alone, so [lo, lo) or [lo, below lo) read no row and PUT an empty object over the key the chunk
  -- [lo, hi) was archived to, which after retire() is the only copy of its rows. See archive._refuse_empty_range.
  perform archive._refuse_empty_range('archive_to_s3_ndjson', p_parent, p_lo, p_hi);
  -- #873: the chunk is read through the parent as the caller, and its ledger row opens retire()'s drop gate
  perform pgpm._refuse_filtered_reads(p_parent, 'archive a chunk of',
    'the object would hold only those rows, and retention would drop the others once it is recorded');

  select t.s3_key, t.etag, t.rows_archived into v_s3_key, v_etag, v_rows
    from archive._encode_upload_ndjson_single(p_parent, p_lo, p_hi, cfg.compress) t;

  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  v_result.s3_key := v_s3_key;
  v_result.etag := v_etag;
  return v_result;
end;
$$;

create or replace function pgpm.archive_to_s3_parquet(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare
  cfg archive.config; v_result pgpm.archive_result;
  v_s3_key text; v_etag text; v_rows bigint;
begin
  -- #969: as archive_to_s3_ndjson's
  perform pgpm._refuse_null_arguments('archive_to_s3_parquet', json_build_object('p_parent', p_parent, 'p_lo', p_lo, 'p_hi', p_hi));
  select * into cfg from archive.config where parent_table = p_parent;
  if not found then raise exception 'pgpm.archive_to_s3_parquet: % has no archive.config row', p_parent; end if;
  -- #969: as archive_to_s3_ndjson's
  perform archive._refuse_empty_range('archive_to_s3_parquet', p_parent, p_lo, p_hi);
  -- #873: as archive_to_s3_ndjson's
  perform pgpm._refuse_filtered_reads(p_parent, 'archive a chunk of',
    'the object would hold only those rows, and retention would drop the others once it is recorded');

  select t.s3_key, t.etag, t.rows_archived into v_s3_key, v_etag, v_rows
    from archive._encode_upload_parquet(p_parent, p_lo, p_hi, cfg.compress) t;

  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  v_result.s3_key := v_s3_key;
  v_result.etag := v_etag;
  return v_result;
end;
$$;

-- The paced worker's archive.schedule/unschedule (issue #233) -- wrapping a second, now-redundant
-- pgpm-archiver pg_cron job -- are gone entirely (issue #240): pgpm.maintain()'s own cadence
-- drives archiving, so there is nothing left to schedule. The old archive.configure/unconfigure
-- (issue #233's 15-arg signature, which also set the paced worker's own boundary_rule/drop_trigger
-- knobs) went with them -- but NOT the reintroduced, narrower archive.configure/unconfigure defined
-- earlier in this file (connection settings only): dropping THAT signature here would undo the very
-- functions this file just (re)created, since install.sql runs top to bottom.
drop function if exists archive.configure(regclass, text, text, text, text, text, text, text, boolean, bigint, int, bigint, int, text, text);
drop function if exists archive.schedule(text);
drop function if exists archive.unschedule();

-- archive._pq_build_schema_leaf and archive._pq_encode_column_data both grew new trailing
-- optional params (type_length/scale/precision, and p_decimal_scale/p_decimal_bytes -- uuid and
-- numeric(p,s) support). CREATE OR REPLACE does not change a function's arg count for an
-- already-installed old signature; drop it explicitly so re-running this file over a prior install
-- doesn't leave both the old- and new-arity versions coexisting as ambiguous overloads (#209's
-- gotcha, again).
drop function if exists archive._pq_build_schema_leaf(text, int4, int4, boolean);
drop function if exists archive._pq_encode_column_data(text, text, text, boolean, text);
-- ...and then #408 retyped the whole parameter list (no parameter carries SQL any more), which is a
-- different arity again, so the 7-arg version needs the same treatment. Leaving it installed would
-- be worse than a stale overload: it is the one that still splices a caller's text verbatim, and it
-- would stay resolvable by anything calling positionally.
drop function if exists archive._pq_encode_column_data(text, text, text, boolean, text, int4, int4);
-- archive._pq_build_schema_leaf again: #465 gave it an eighth trailing optional param
-- (p_logical_type), so its 7-arg version goes the same way. With both installed, a call passing only
-- the four required arguments matches both and is refused as "not unique".
drop function if exists archive._pq_build_schema_leaf(text, int4, int4, boolean, int4, int4, int4);
-- archive._s3_abort_uploads_at grew a trailing optional p_page_size (#711). With the 6-arg version still
-- installed, archive.to_s3's 6-argument calls would match both and be refused as "not unique".
drop function if exists archive._s3_abort_uploads_at(text, text, text, text, text, text);
