-- A direct strategy call reads its range under the SESSION's DateStyle (archive._refuse_empty_range,
-- pgpm._encode in archive._encode_upload_ndjson_single, archive._refuse_recorded_chunk_overwrite all
-- parse p_lo there) but names its object by archive._object_stem, which parses the same p_lo under its
-- own pinned 'ISO, MDY'. Under DateStyle 'SQL, DMY' the lo '02/01/2024 00:00:00+00' is read as 2 January
-- (the rows the object holds) and keyed 2024020100000000 (1 February): the object's name misstates its
-- contents, and it sits at the key the real 1 February chunk is archived to.
create extension if not exists pgtap;
select plan(7);

create schema f19d;
create table f19d.ev (ts timestamptz not null, payload text not null, primary key (ts, payload));
insert into f19d.ev values ('2024-01-02 12:00:00+00', 'jan2'), ('2024-02-01 12:00:00+00', 'feb1');
call pgpm.transmute('f19d.ev', 'ts', interval '1 day', p_paused => true);
select pgpm.obtain('f19d.ev');
select 'f19-03-' || current_database() || '/' as p \gset
select archive.configure('f19d.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

create function f19d.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- the strategy's s3_key and rows_archived, or the error it raised
create function f19d.try(p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  r := pgpm.archive_to_s3_ndjson('f19d.ev', null, p_lo, p_hi);
  return r.s3_key || ' rows=' || coalesce(r.rows_archived::text, 'null');
exception when others then return 'ERR: ' || sqlerrm;
end $$;

set datestyle = 'SQL, DMY';
select is(pgpm._ts_text('02/01/2024 00:00:00+00'::timestamptz), '2024-01-02 00:00:00+00',
  'LIVENESS: under DateStyle SQL, DMY the session reads 02/01/2024 as 2 January');
select is((select string_agg(payload, ',') from f19d.ev where ts >= '02/01/2024 00:00:00+00' and ts < '03/01/2024 00:00:00+00'),
  'jan2', 'LIVENESS: the range [02/01/2024, 03/01/2024) as this session reads it holds the row jan2 alone');
select archive._object_stem('time', pgpm._ts_text('02/01/2024 00:00:00+00'::timestamptz)) as stem_read \gset
select is(:'stem_read'::text, '2024010200000000', 'LIVENESS: the stem of the instant the session reads is 2 January');

select f19d.try('02/01/2024 00:00:00+00', '03/01/2024 00:00:00+00') as result \gset
select alike(:'result'::text, '% rows=1', 'LIVENESS: the strategy archived one row of that range (or refused the spelling)')
 where not :'result' like 'ERR:%'
union all select pass('LIVENESS: the strategy refused the spelling') where :'result' like 'ERR:%';

-- the defect: the object is keyed by another day than the one the call read
select ok(:'result'::text like 'ERR:%' or :'result'::text like :'p'::text || 'f19d.ev_' || :'stem_read'::text || '.ndjson rows=%',
  format('the chunk read as [2024-01-02, 2024-01-03) is keyed by the stem of 2 January, not 1 February (got %s)', :'result'));
select is((f19d.req('GET', :'p' || 'f19d.ev_2024020100000000.ndjson')).status, 404,
  'no object holding the 2 January row lands at the 1 February chunk''s key');
select is((f19d.req('GET', :'p' || 'f19d.ev_2024010200000000.ndjson')).content, '{"ts":"2024-01-02T12:00:00+00:00","payload":"jan2"}',
  'the object at the 2 January key holds the row jan2')
 where not :'result' like 'ERR:%'
union all select pass('fixture: refused, nothing to read back') where :'result' like 'ERR:%';
reset datestyle;
select (f19d.req('DELETE', :'p' || 'f19d.ev_2024020100000000.ndjson')).status as c1 \gset
select (f19d.req('DELETE', :'p' || 'f19d.ev_2024010200000000.ndjson')).status as c2 \gset

select * from finish();
