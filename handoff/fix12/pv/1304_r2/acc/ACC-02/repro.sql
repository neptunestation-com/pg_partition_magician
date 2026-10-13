-- A direct archive_fn strategy call on a DATE-column day grid, from a session whose TimeZone is not the
-- grid's partition_tz (UTC for a date column), keys the chunk by an instant no chunk starts at (#814's
-- contract: the key names the chunk the call read, whatever the session). The head reads p_lo once with
-- pgpm._native_text in the session ('2024-01-02' -> 2024-01-02 05:00Z from New York) and keys from that,
-- but the date column's read truncates the literal to the date 2024-01-02, so the object holds the whole
-- 2 January chunk (the day cell [2024-01-02 00:00Z, 2024-01-03 00:00Z)) at the key ..._2024010205000000, while the same call
-- from a UTC session writes the same rows to ..._2024010200000000: one chunk, two keys, by session zone.
-- The recorded-chunk check (#975) looks up the session-shaped key, so it never sees the ledger row a tick
-- recorded at the chunk's real key.
create extension if not exists pgtap;
select plan(7);

create schema v1;
create table v1.d (id bigint not null, d date not null, primary key (d, id));
insert into v1.d values (1, '2024-01-02'), (2, '2024-01-02'), (3, '2024-01-03');
call pgpm.transmute('v1.d', 'd', interval '1 day', p_paused => true);
select 'v1-' || current_database() || '/' as p \gset
select archive.configure('v1.d', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

create function v1.req(p_method text, p_key text) returns int language sql as $$
  select (archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                    'text/plain', '', 'minioadmin', 'minioadmin')).status $$;
select v1.req('DELETE', :'p' || 'v1.d_2024010200000000.ndjson') as c0 \gset
select v1.req('DELETE', :'p' || 'v1.d_2024010205000000.ndjson') as c1 \gset

select is((select partition_tz from pgpm.config where parent_table = 'v1.d'::regclass), 'UTC',
  'GUARD: a date grid''s partition_tz is UTC');
select ok((select partition_anchor::timestamptz = '2000-01-01 00:00:00+00'::timestamptz and partition_step = '1 day'
             from pgpm.config where parent_table = 'v1.d'::regclass),
  'LIVENESS: the day grid''s cells start at 00:00Z (anchor 2000-01-01 00:00Z, step 1 day), so 2 January''s cell is [2024-01-02 00:00Z, 2024-01-03 00:00Z) and no cell starts at 05:00Z');

set timezone = 'America/New_York';
select is(pgpm._ts_text('2024-01-02'::timestamptz), '2024-01-02 00:00:00-05',
  'LIVENESS: a New York session reads 2024-01-02 as 05:00Z, not the chunk''s 00:00Z');
select (pgpm.archive_to_s3_ndjson('v1.d', null, '2024-01-02', '2024-01-03')).* \gset ny_
reset timezone;

select is(:'ny_rows_archived'::bigint, 2::bigint,
  'LIVENESS: the call read the whole 2 January chunk (ids 1 and 2), as the date column truncates its bound');

-- the defect checks
select is(:'ny_s3_key'::text, :'p' || 'v1.d_2024010200000000.ndjson',
  format('the 2 January chunk read from New York is keyed by its lo, 2024010200000000 (got %s)', :'ny_s3_key'));
select is(v1.req('GET', :'p' || 'v1.d_2024010205000000.ndjson'), 404,
  'nothing lands at a 05:00Z key no chunk of the day grid starts at');
select (pgpm.archive_to_s3_ndjson('v1.d', null, '2024-01-02', '2024-01-03')).s3_key as utc_key \gset
select is(:'ny_s3_key'::text, :'utc_key'::text,
  'the same chunk, the same rows, gets the same key from a New York session and a UTC one');

select v1.req('DELETE', :'p' || 'v1.d_2024010200000000.ndjson') as d0 \gset
select v1.req('DELETE', :'p' || 'v1.d_2024010205000000.ndjson') as d1 \gset
select * from finish();
