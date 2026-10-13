-- On a date-column day grid (partition_tz UTC), a direct strategy call keys the object by the instant its lo
-- text names, but the read compares a DATE column, which truncates that instant to its whole day. A Tokyo
-- caller spelling its own midnight with its offset, lo = '2024-01-02 00:00:00+09' (= 2024-01-01 15:00Z), gets
-- the whole 1 January cell's rows (from 2024-01-01 00:00, not from 15:00) PUT at d.ev_2024010115000000, a
-- key no cell starts at, while a tick keys that same chunk d.ev_2024010100000000. The PR body promises the
-- stem is "the stem of the instant the call's range read began at" from any TimeZone; on a date grid the read
-- began at the day. The object should be keyed by the cell the read covers (or the bound refused).
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(6);

create schema d;
create table d.ev (d date not null, payload text not null, primary key (d, payload));
insert into d.ev values ('2024-01-01', 'jan1'), ('2024-01-02', 'jan2a'), ('2024-01-02', 'jan2b');
call pgpm.transmute('d.ev', 'd', interval '1 day', p_paused => true);
select pgpm.obtain('d.ev');
select 'v02-1304-' || current_database() || '/' as p \gset
select archive.configure('d.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
create function d.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function d.try(p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  r := pgpm.archive_to_s3_ndjson('d.ev', null, p_lo, p_hi);
  return r.s3_key || ' rows=' || coalesce(r.rows_archived::text, 'null');
exception when others then return 'ERR: ' || sqlerrm;
end $$;

set timezone = 'Asia/Tokyo';
select is((select partition_tz from pgpm.config where parent_table = 'd.ev'::regclass), 'UTC',
  'GUARD: the date grid''s clock is UTC (#504)');
select is(('2024-01-02 00:00:00+09'::timestamptz at time zone 'UTC')::date, '2024-01-01'::date,
  'LIVENESS: the lo instant falls inside the 1 January cell, at 15:00Z, not on a cell start');

select d.try('2024-01-02 00:00:00+09', '2024-01-03 00:00:00+09') as result \gset
select ok(:'result'::text like 'ERR:%' or :'result'::text like '% rows=1',
  format('LIVENESS: the call read the 1 January cell''s one row (or refused) (got %s)', :'result'));

-- the defect: the object holding the whole 1 January cell is keyed at an instant no cell starts at
select ok(:'result'::text like 'ERR:%' or :'result'::text like :'p'::text || 'd.ev_2024010100000000.ndjson rows=%',
  format('the chunk the read covers (the 1 January cell) is keyed by the cell''s start (got %s)', :'result'));
select is((d.req('GET', :'p' || 'd.ev_2024010115000000.ndjson')).status, 404,
  'no object lands at d.ev_2024010115000000, a key no cell of the grid starts at');
select ok(:'result'::text like 'ERR:%'
       or (d.req('GET', :'p' || 'd.ev_2024010100000000.ndjson')).content = '{"d":"2024-01-01","payload":"jan1"}',
  'the object at the 1 January cell''s key holds exactly the row jan1');

reset timezone;
select (d.req('DELETE', :'p' || 'd.ev_2024010115000000.ndjson')).status as c1 \gset
select (d.req('DELETE', :'p' || 'd.ev_2024010100000000.ndjson')).status as c2 \gset
select * from finish();
