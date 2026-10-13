-- PR #1304 says both encoders read p_lo and p_hi once, canonically (pgpm._native_text), so that the range
-- read, the recorded-chunk check and the object key all take the session's reading. In this tree
-- archive._encode_upload_ndjson_single canonicalises p_hi ONLY (install.sql:3073): p_lo reaches
-- archive._object_key as the caller spelled it, and archive._object_stem parses that spelling under its own
-- pinned 'ISO, MDY' / UTC. So from a 'SQL, DMY' session '02/01/2024 00:00:00+00' is still read as 2 January
-- (the rows the object holds) and keyed 2024020100000000 (1 February), which is #814's archive bullet
-- unchanged for NDJSON; and on an id grid '0100' is keyed _0100, not the _100 a tick keys that chunk.
-- The parquet encoder in the same tree reads both bounds, so the defect is the NDJSON encoder's alone.
--
-- Asymmetric fixtures: the day the session reads holds ids 1 and 2, the day the stem's reading names holds
-- id 3 alone; the id chunk [100, 200) holds 150 and 160, [200, 300) holds 250.
create extension if not exists pgtap;
select plan(14);

create schema p1;
select current_database() || '/p1/' as p \gset

create function p1.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- the ids an NDJSON object holds, by identity (null when there is no object)
create function p1.ids(p_key text) returns bigint[] language plpgsql as $$
declare r http_response;
begin
  r := p1.req('GET', p_key);
  if r.status not between 200 and 299 then return null; end if;
  return (select array_agg((l::jsonb ->> 'id')::bigint order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(r.content, e'\n') l where l <> '');
end $$;
-- DELETE then GET: 404 means nothing sits at the key before the work below
create function p1.clear(p_key text) returns int language plpgsql as $$
begin perform p1.req('DELETE', p_key); return (p1.req('GET', p_key)).status; end $$;
-- what the default DateStyle and zone read a bound text as: the reading _object_stem applies to raw text
create function p1.default_reading(p_text text) returns text
language sql stable set timezone = 'UTC' set datestyle = 'ISO, MDY' as $$ select pgpm._ts_text(p_text::timestamptz) $$;

-- ---- part 1: a time grid, NDJSON, from a 'SQL, DMY' session ----
create table p1.nd (id bigint not null, ts timestamptz not null, primary key (ts, id));
insert into p1.nd values (1, '2024-01-02 12:00:00+00'), (2, '2024-01-02 13:00:00+00'), (3, '2024-02-01 12:00:00+00');
call pgpm.transmute('p1.nd', 'ts', interval '1 day', p_paused => true);
select archive.configure('p1.nd', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is(p1.clear(:'p' || 'p1.nd_2024010200000000.ndjson'), 404, 'fixture: no object at the 2 January key');
select is(p1.clear(:'p' || 'p1.nd_2024020100000000.ndjson'), 404, 'fixture: no object at the 1 February key');

set datestyle = 'SQL, DMY';
select is(pgpm._ts_text('02/01/2024 00:00:00+00'::timestamptz), '2024-01-02 00:00:00+00',
  'LIVENESS: under DateStyle SQL, DMY the session reads 02/01/2024 as 2 January');
select is(p1.default_reading('02/01/2024 00:00:00+00'), '2024-02-01 00:00:00+00',
  'LIVENESS: the same text names 1 February under the default DateStyle, so the stem''s own reading of it differs');
select is((select array_agg(id order by id) from p1.nd where ts >= '02/01/2024 00:00:00+00' and ts < '03/01/2024 00:00:00+00'),
  array[1, 2]::bigint[], 'LIVENESS: the range [02/01/2024, 03/01/2024) as this session reads it holds ids 1 and 2');

select (pgpm.archive_to_s3_ndjson('p1.nd', null, '02/01/2024 00:00:00+00', '03/01/2024 00:00:00+00')).* \gset nd_
reset datestyle;

select is(:'nd_rows_archived'::bigint, 2::bigint, 'LIVENESS: the NDJSON call read and archived the two rows of 2 January');
-- the defect: the object is keyed by the stem's reading of the caller's spelling, not by the instant the call read
select is(:'nd_s3_key'::text, :'p' || 'p1.nd_2024010200000000.ndjson',
  'the NDJSON object is keyed by the 2 January the call read, not the 1 February the raw text names to the stem');
select is(p1.ids(:'p' || 'p1.nd_2024010200000000.ndjson'), array[1, 2]::bigint[],
  'the object at the 2 January key holds exactly ids 1 and 2');
select is((p1.req('GET', :'p' || 'p1.nd_2024020100000000.ndjson')).status, 404,
  'nothing holding the 2 January rows sits at the 1 February chunk''s key');

-- ---- part 2: an id grid, NDJSON, lo spelled with a leading zero ----
create table p1.id (id bigint primary key);
insert into p1.id values (150), (160), (250);
call pgpm.transmute('p1.id', 'id', 100::bigint, p_paused => true);
select archive.configure('p1.id', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is(p1.clear(:'p' || 'p1.id_100.ndjson'), 404, 'fixture: no object at the key for lo 100');
select is(p1.clear(:'p' || 'p1.id_0100.ndjson'), 404, 'fixture: no object at the key spelled _0100');
select is(pgpm._native_text('id', '0100'), '100', 'LIVENESS: the id kind reads ''0100'' as 100, the lo a tick keys as _100');

select (pgpm.archive_to_s3_ndjson('p1.id', null, '0100', '0200')).* \gset id_
select is(:'id_s3_key'::text, :'p' || 'p1.id_100.ndjson', 'the id object is keyed by the lo 100 the call read, as a tick keys it');
select is(p1.ids(:'p' || 'p1.id_100.ndjson'), array[150, 160]::bigint[], 'the object at the key for lo 100 holds exactly ids 150 and 160');

-- clean the bucket of whatever this run left at any candidate key
select p1.clear(:'p' || 'p1.nd_2024010200000000.ndjson'), p1.clear(:'p' || 'p1.nd_2024020100000000.ndjson'),
       p1.clear(:'p' || 'p1.id_100.ndjson'), p1.clear(:'p' || 'p1.id_0100.ndjson');

select * from finish();
