-- Three pgpm_archive edges left after pass 4 (issue #711), each fixed where it starts:
--
--   A. archive.to_s3 and archive.to_s3_parquet keyed their object <prefix><child><ext>, the child's bare
--      relname. pgpm names a child after its parent's relname, so two parents named `evt` in two schemas
--      sharing a prefix (archive.configure's default `events/` is shared by every table) exported their
--      [0, 10000) partitions to ONE key, the second export replacing the first; after the documented
--      to_s3-then-drop workflow the first table's rows existed nowhere. The key now names the child with
--      its schema, <prefix><schema>.<child><ext> (archive._child_object_key), as #551 made the
--      automatic path name the parent.
--   B. The Parquet writer annotated only a `timestamp` leaf with a LogicalType. A `timestamptz` leaf
--      carried the legacy ConvertedType TIMESTAMP_MICROS alone, which DuckDB reads as a naive
--      TIMESTAMP, against the README's promise that a reader shows the instant in its own zone. It now
--      carries LogicalType TIMESTAMP(isAdjustedToUTC=true, MICROS) beside the ConvertedType. (The
--      readers' half, DuckDB and pyarrow on the file, is bench/archive_edges_pass5.sh's.)
--   C. archive._s3_abort_uploads_at read one page of ListMultipartUploads, so an orphan past the page
--      boundary was left in flight. It now follows the markers to the last page; the page size is a
--      parameter (S3's 1000 by default) so one page of ONE upload can show the walk against MinIO.
--
-- Fixtures are asymmetric so a clobbered or swapped object cannot pass an identity check: 2 rows against
-- 1 in the two `evt` tables, 3 uploads at the paged key. Every key this file writes is cleared and
-- witnessed absent first, because the bucket outlives a test database; keys carry current_database().
select plan(19);

create schema t30;

-- S3 through the module's signer, the instrument here and not the subject
create function t30.req(p_method text, p_key text, p_query text default '') returns http_response
language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, p_query,
                                   'text/plain', '', 'minioadmin', 'minioadmin')
$$;
-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below
create function t30.clear(p_key text) returns int language sql as $$
  select (t30.req('DELETE', p_key)).status * 0 + (t30.req('GET', p_key)).status
$$;
-- an NDJSON object's rows as sorted id:payload text, or null when there is no object
create function t30.rows(p_key text) returns text language plpgsql as $$
declare r http_response := t30.req('GET', p_key);
begin
  if r.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::int)
            from regexp_split_to_table(r.content, e'\n') l where l <> '');
end $$;
-- an object's bytes, or null when there is no object
create function t30.bytes(p_key text) returns bytea language plpgsql as $$
declare r http_response := t30.req('GET', p_key);
begin
  if r.status <> 200 then return null; end if;
  return text_to_bytea(r.content);
end $$;
-- the UploadIds MinIO lists in flight at exactly p_key (MinIO lists a prefix as the exact key), sorted
create function t30.inflight(p_key text) returns text[] language plpgsql as $$
declare r http_response := t30.req('GET', '', 'prefix=' || archive.s3_url_encode(p_key) || '&uploads=');
begin
  if r.status <> 200 then raise exception 'list uploads: HTTP % %', r.status, left(r.content, 200); end if;
  return (select coalesce(array_agg(x.id order by x.id), '{}') from xmltable('//*[local-name()=''Upload'']' passing (r.content::xml)
            columns k text path '*[local-name()=''Key'']', id text path '*[local-name()=''UploadId'']') x where x.k = p_key);
end $$;

-- ======================= A. the synchronous exports' keys name the schema =======================

create schema t30a;
create schema t30b;
create table t30a.evt (id bigint primary key, payload text);
create table t30b.evt (id bigint primary key, payload text);
insert into t30a.evt values (1, 'a'), (2, 'a');
insert into t30b.evt values (1, 'b');
call pgpm.transmute('t30a.evt', 'id', 10000::bigint);
call pgpm.transmute('t30b.evt', 'id', 10000::bigint);
select current_database() || '-t30/' as p \gset
select archive.configure('t30a.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select archive.configure('t30b.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select child_name as child from pgpm.part where parent_table = 't30a.evt'::regclass and lo = '0' \gset

select is((select child_name from pgpm.part where parent_table = 't30b.evt'::regclass and lo = '0'), :'child'::name,
  'LIVENESS: the two parents'' [0, 10000) partitions share one relname, and the two configs one prefix');
select is((select array_agg(t30.clear(:'p' || k || e) order by k, e)
             from unnest(array['', 't30a.', 't30b.']) k(k), unnest(array[:'child' || '.ndjson', :'child' || '.parquet']) e(e)),
  array[404, 404, 404, 404, 404, 404],
  'LIVENESS: no object at the bare keys or at either schema''s, before the exports');

-- NDJSON: t30a first, then t30b, the way an operator works through two tenants
select archive.to_s3('t30a.evt', :'child', '0', '10000');
select archive.to_s3('t30b.evt', :'child', '0', '10000');
select is(t30.rows(:'p' || 't30a.' || :'child' || '.ndjson'), '1:a,2:a',
  'archive.to_s3 wrote t30a.evt''s rows 1:a,2:a at <prefix>t30a.<child>.ndjson');
select is(t30.rows(:'p' || 't30b.' || :'child' || '.ndjson'), '1:b',
  'and t30b.evt''s row 1:b at <prefix>t30b.<child>.ndjson, not over t30a''s');
select is((t30.req('GET', :'p' || :'child' || '.ndjson')).status, 404,
  'nothing was written at the bare, schema-less key <prefix><child>.ndjson');

-- Parquet: the same, each object compared byte for byte with its own partition's encoding
select archive._pq_to_parquet(format('t30a.%I', :'child')::regclass, false) as a_pq \gset
select archive._pq_to_parquet(format('t30b.%I', :'child')::regclass, false) as b_pq \gset
select ok(:'a_pq'::bytea <> :'b_pq'::bytea, 'LIVENESS: the two partitions encode to different Parquet files');
select archive.to_s3_parquet('t30a.evt', :'child', '0', '10000');
select archive.to_s3_parquet('t30b.evt', :'child', '0', '10000');
select is(t30.bytes(:'p' || 't30a.' || :'child' || '.parquet'), :'a_pq'::bytea,
  'archive.to_s3_parquet wrote t30a.evt''s file at <prefix>t30a.<child>.parquet');
select is(t30.bytes(:'p' || 't30b.' || :'child' || '.parquet'), :'b_pq'::bytea,
  'and t30b.evt''s file at <prefix>t30b.<child>.parquet, not over t30a''s');
select is((t30.req('GET', :'p' || :'child' || '.parquet')).status, 404,
  'nothing was written at the bare, schema-less key <prefix><child>.parquet');

-- ======================= B. a timestamptz leaf says it is an instant =======================

-- Thrift compact protocol, by hand: 1 type=INT64 (15 04), 3 repetition=REQUIRED (25 00), 4 name
-- (18 04 'tstz'), 6 converted_type=TIMESTAMP_MICROS (25 14), 10 logicalType (4c) = union LogicalType
-- field 8 TIMESTAMP (8c) { 1 isAdjustedToUTC=TRUE (11), 2 unit (1c) = TimeUnit field 2 MICROS (2c) {}
-- (00) } (00) } (00) } (00), and the element's own stop (00). The `timestamp` leaf of tests/archive/db/14
-- is the same but for 12, isAdjustedToUTC=false.
select is(archive._pq_build_schema_leaf('tstz', 2, 10, false, p_logical_type => archive._pq_logical_timestamp_micros(true)),
  '\x1504250018047473747a25144c8c111c2c0000000000'::bytea,
  'the tstz leaf: LogicalType TIMESTAMP(isAdjustedToUTC=true, MICROS) after ConvertedType TIMESTAMP_MICROS');

create table public.tz30 (id int4 primary key, tstz timestamptz not null);
insert into public.tz30 values (1, '2024-01-15 18:30:00+00'), (2, '2024-07-15 18:30:00+00');
-- a table, not a temp one: bench/archive_edges_pass5.sh reads these two files back with DuckDB and pyarrow
create table t30.pq as
  select 'whole' as label, archive._pq_to_parquet('public.tz30', false) as bytes
  union all
  select 'range', archive._pq_to_parquet_range('public.tz30', 'id', '0', '100', false);

select is((select array_agg(position('\x1504250018047473747a25144c8c111c2c0000000000'::bytea in bytes) > 0 order by label) from t30.pq),
  array[true, true],
  'both encoders'' footers carry that tstz leaf');
select is((select array_agg(position('\x1504250018047473747a251400'::bytea in bytes) order by label) from t30.pq),
  array[0, 0],
  'and neither carries the old one, ConvertedType alone, which DuckDB read as a naive timestamp');

-- ======================= C. the orphan sweep reads every page =======================

select current_database() || '-t30/paged.ndjson' as pk \gset
-- abort whatever an earlier run left at the key, so what is listed afterwards came from this run
select count(t30.req('DELETE', :'pk', 'uploadId=' || archive.s3_url_encode(u))) from unnest(t30.inflight(:'pk')) u;
select is(t30.inflight(:'pk'), '{}'::text[], 'LIVENESS: no upload is in flight at the paged key before the file starts three');

select (xpath('//*[local-name()=''UploadId'']/text()', (t30.req('POST', :'pk', 'uploads=')).content::xml))[1]::text as u1 \gset
select (xpath('//*[local-name()=''UploadId'']/text()', (t30.req('POST', :'pk', 'uploads=')).content::xml))[1]::text as u2 \gset
select (xpath('//*[local-name()=''UploadId'']/text()', (t30.req('POST', :'pk', 'uploads=')).content::xml))[1]::text as u3 \gset
select is(t30.inflight(:'pk'), (select array_agg(u order by u) from unnest(array[:'u1', :'u2', :'u3']) u),
  'LIVENESS: the three uploads this file started are in flight at the key');
select is((xpath('//*[local-name()=''IsTruncated'']/text()',
               (t30.req('GET', '', 'max-uploads=1&prefix=' || archive.s3_url_encode(:'pk') || '&uploads=')).content::xml))[1]::text,
  'true',
  'LIVENESS: at one upload per page the store truncates the listing, so the sweep has pages to follow');

select is(archive._s3_abort_uploads_at('http://minio:9000', 'archive-test-bucket', 'us-east-1', :'pk', 'minioadmin', 'minioadmin',
                                       p_page_size => 1),
  3, 'archive._s3_abort_uploads_at, one upload per page, aborts all three');
select is(t30.inflight(:'pk'), '{}'::text[], 'and nothing is left in flight at the key: not one past the first page');

select throws_like(
  $$ select archive._s3_abort_uploads_at('http://minio:9000', 'archive-test-bucket', 'us-east-1', 'x', 'minioadmin', 'minioadmin', p_page_size => 0) $$,
  'archive._s3_abort_uploads_at: p_page_size must be a positive number of uploads, not 0',
  'a page size under one is refused rather than looping');
select is(archive._s3_abort_uploads_at('http://minio:9000', 'archive-test-bucket', 'us-east-1', :'pk', 'minioadmin', 'minioadmin'),
  0, 'at the default page size, a key with nothing in flight aborts nothing');

select * from finish();
