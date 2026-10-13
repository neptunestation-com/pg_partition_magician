-- archive._encode_upload_ndjson_single reads only p_hi through archive._bound_native (install.sql:3090);
-- its p_lo is never read, so the NDJSON strategy still hands the caller's own spelling of lo to the range
-- read (pgpm._encode, parsed in the caller's session) and to archive._object_key (archive._object_stem,
-- parsed under its pinned UTC / 'ISO, MDY'). The Parquet encoder reads both bounds (3181-3182).
--
-- Two consequences, each paired with the Parquet strategy as a control of the same call from the same session:
--   A. from a 'SQL, DMY' session, lo '02/01/2024 00:00:00+00' reads the 2 January rows (ids 1, 2) and PUTs them
--      at the 1 February chunk's key (the F19-03 shape the PR says both encoders now fix);
--   B. on a date grid from a session EAST of the grid (Asia/Tokyo), lo '2024-01-02' is read as 2024-01-01 15:00Z,
--      which the date column truncates to 1 January, so the object keyed 2 January (the stem's UTC reading)
--      holds the 1 January row (id 9) as well: the key misstates the object's rows.
-- Fixtures are asymmetric: the session's range holds 2 rows (A) or 3 (B); the other reading's range holds 1 or 2.
create extension if not exists pgtap;
select plan(14);

create schema p1a;
select current_database() || '/p1a/' as p \gset

create function p1a.status(p_method text, p_key text) returns int language sql as $$
  select (archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                    'text/plain', '', 'minioadmin', 'minioadmin')).status $$;
create function p1a.ids(p_key text) returns bigint[] language plpgsql as $$
declare r record;
begin
  r := archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                 'text/plain', '', 'minioadmin', 'minioadmin');
  if r.status not between 200 and 299 then return null; end if;
  return (select array_agg((l::jsonb ->> 'id')::bigint order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(r.content, e'\n') l where l <> '');
end $$;
create function p1a.clear(p_key text) returns int language plpgsql as $$
begin perform p1a.status('DELETE', p_key); return p1a.status('GET', p_key); end $$;

-- ===== A: NDJSON from 'SQL, DMY' on a timestamptz day grid (ids 1, 2 on 2 January; 3 on 1 February) =====
create table p1a.nd (id bigint not null, ts timestamptz not null, primary key (ts, id));
create table p1a.pq (id bigint not null, ts timestamptz not null, primary key (ts, id));
insert into p1a.nd values (1, '2024-01-02 12:00:00+00'), (2, '2024-01-02 13:00:00+00'), (3, '2024-02-01 12:00:00+00');
insert into p1a.pq select * from p1a.nd;
set timezone = 'UTC';
call pgpm.transmute('p1a.nd', 'ts', interval '1 day', p_paused => true);
call pgpm.transmute('p1a.pq', 'ts', interval '1 day', p_paused => true);
select archive.configure('p1a.nd', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select archive.configure('p1a.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is(p1a.clear(:'p' || 'p1a.nd_2024010200000000.ndjson'), 404, 'fixture: no object at p1a.nd''s 2 January key');
select is(p1a.clear(:'p' || 'p1a.nd_2024020100000000.ndjson'), 404, 'fixture: no object at p1a.nd''s 1 February key');

set datestyle = 'SQL, DMY';
select is(pgpm._ts_text('02/01/2024 00:00:00+00'::timestamptz), '2024-01-02 00:00:00+00',
  'LIVENESS: under DateStyle SQL, DMY the session reads 02/01/2024 as 2 January');
select is(archive._object_stem('time', '02/01/2024 00:00:00+00'), '2024020100000000',
  'LIVENESS: the stem''s pinned parse reads the same spelling as 1 February');
select is((select array_agg(id order by id) from p1a.nd where ts >= '02/01/2024 00:00:00+00' and ts < '03/01/2024 00:00:00+00'),
  array[1, 2]::bigint[], 'LIVENESS: the range as this session reads it holds ids 1 and 2');
select (pgpm.archive_to_s3_ndjson('p1a.nd', null, '02/01/2024 00:00:00+00', '03/01/2024 00:00:00+00')).* \gset nd_
select (pgpm.archive_to_s3_parquet('p1a.pq', null, '02/01/2024 00:00:00+00', '03/01/2024 00:00:00+00')).* \gset pq_
reset datestyle;

select is(:'pq_s3_key'::text, :'p' || 'p1a.pq_2024010200000000.parquet',
  'GUARD: the Parquet strategy, which reads its lo, keys the same call by the 2 January it read');
select is(:'nd_rows_archived'::bigint, 2::bigint, 'LIVENESS: the NDJSON call read the two rows of 2 January');
select is(:'nd_s3_key'::text, :'p' || 'p1a.nd_2024010200000000.ndjson',
  'the NDJSON object is keyed by the 2 January the call read, not the 1 February the stem read');
select is(p1a.status('GET', :'p' || 'p1a.nd_2024020100000000.ndjson'), 404,
  'nothing holding the 2 January rows sits at the 1 February chunk''s key');

-- ===== B: NDJSON on a date grid from Asia/Tokyo (id 9 on 1 January; 1, 2 on 2 January; 4 on 3 January) =====
create table p1a.dd (id bigint not null, d date not null, primary key (d, id));
insert into p1a.dd values (9, '2024-01-01'), (1, '2024-01-02'), (2, '2024-01-02'), (4, '2024-01-03');
set timezone = 'UTC';
call pgpm.transmute('p1a.dd', 'd', interval '1 day', p_paused => true);
select archive.configure('p1a.dd', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select is(p1a.clear(:'p' || 'p1a.dd_2024010200000000.ndjson'), 404, 'fixture: no object at p1a.dd''s 2 January key');
select is((select partition_tz from pgpm.config where parent_table = 'p1a.dd'::regclass), 'UTC',
  'LIVENESS: the date grid runs on UTC, so 2 January''s cell starts at 00:00Z');

set timezone = 'Asia/Tokyo';
select is(pgpm._ts_text('2024-01-02'::timestamptz), '2024-01-02 00:00:00+09',
  'LIVENESS: a Tokyo session reads 2024-01-02 as 2024-01-01 15:00Z, inside the 1 January cell');
select (pgpm.archive_to_s3_ndjson('p1a.dd', null, '2024-01-02', '2024-01-03')).* \gset dd_
reset timezone;

select is(:'dd_s3_key'::text, :'p' || 'p1a.dd_2024010200000000.ndjson', 'LIVENESS: the object is keyed by the 2 January cell');
select is(p1a.ids(:'dd_s3_key'), array[1, 2]::bigint[],
  'the object at the 2 January cell''s key holds exactly that cell''s rows (ids 1 and 2), not 1 January''s id 9');

select p1a.clear(:'p' || 'p1a.nd_2024010200000000.ndjson'), p1a.clear(:'p' || 'p1a.nd_2024020100000000.ndjson'),
       p1a.clear(:'p' || 'p1a.pq_2024010200000000.parquet'), p1a.clear(:'p' || 'p1a.dd_2024010200000000.ndjson');
select * from finish();
