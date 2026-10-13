-- The PR body says archive._refuse_empty_range (#969) "still parses the raw text in the caller's session, so it
-- reads the same instant pgpm._native_text does". It does not any more: archive._bound_native reads an
-- offset-less bound in the grid's partition_tz while the refusal reads it in the caller's TimeZone, so the two
-- can order a range differently. On a 30-minute timestamptz grid whose partition_tz is America/New_York, a UTC
-- session's offset-less '2024-03-10 02:30:00' .. '03:00:00' is a valid half hour to the refusal (02:30Z < 03:00Z),
-- but 02:30 is inside New York's spring-forward gap, which PostgreSQL maps to 03:30 EDT (07:30Z), while 03:00
-- is 03:00 EDT (07:00Z): the encoder reads the INVERTED range [07:30Z, 07:00Z), finds no row, and PUTs an empty
-- Parquet object at the key of the live cell [07:30Z, 08:00Z), which holds row id 1. That is the write #969's
-- refusal exists to stop ("read no row and PUT an empty object over the key the chunk ... was archived to").
-- Fixture: id 1 at 07:40Z (inside the cell the empty object is keyed by), id 2 at 02:40Z (inside the session's
-- reading of the range, so a call that read the session's instant would archive exactly id 2).
create extension if not exists pgtap;
select plan(9);

create schema p1c;
select current_database() || '/p1c/' as p \gset
create function p1c.status(p_method text, p_key text) returns int language sql as $$
  select (archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                    'text/plain', '', 'minioadmin', 'minioadmin')).status $$;
create function p1c.try(p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  r := pgpm.archive_to_s3_parquet('p1c.ny', null, p_lo, p_hi);
  return r.s3_key || ' rows=' || coalesce(r.rows_archived::text, 'null');
exception when others then return 'ERR: ' || sqlerrm;
end $$;

create table p1c.ny (id bigint not null, ts timestamptz not null, primary key (ts, id));
insert into p1c.ny values (1, '2024-03-10 07:40:00+00'), (2, '2024-03-10 02:40:00+00');
set timezone = 'America/New_York';
call pgpm.transmute('p1c.ny', 'ts', interval '30 minutes', p_paused => true);
select archive.configure('p1c.ny', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select is((select partition_tz from pgpm.config where parent_table = 'p1c.ny'::regclass), 'America/New_York',
  'LIVENESS: the grid''s clock is America/New_York');
select p1c.status('DELETE', :'p' || 'p1c.ny_2024031007300000.parquet');
select is(p1c.status('GET', :'p' || 'p1c.ny_2024031007300000.parquet'), 404, 'fixture: no object at the 07:30Z cell''s key');

set timezone = 'UTC';
select ok(pgpm._native_gt('time', '2024-03-10 03:00:00', '2024-03-10 02:30:00'),
  'LIVENESS: the session (UTC) reads [02:30, 03:00) as a non-empty range, so archive._refuse_empty_range admits it');
select is(archive._bound_native('time', '2024-03-10 02:30:00', 'America/New_York'), '2024-03-10 03:30:00-04',
  'LIVENESS: on the grid''s clock 02:30 is in the DST gap and reads as 03:30 EDT (07:30Z)');
select is(archive._bound_native('time', '2024-03-10 03:00:00', 'America/New_York'), '2024-03-10 03:00:00-04',
  'LIVENESS: on the grid''s clock 03:00 reads as 03:00 EDT (07:00Z), BELOW the lo: the encoder''s range is inverted');
select is((select array_agg(id) from p1c.ny where ts >= '2024-03-10 07:30:00+00' and ts < '2024-03-10 08:00:00+00'),
  array[1]::bigint[], 'LIVENESS: the cell [07:30Z, 08:00Z), whose key the encoder derives from that lo, holds id 1');

select p1c.try('2024-03-10 02:30:00', '2024-03-10 03:00:00') as result \gset
reset timezone;

select ok(:'result'::text like 'ERR:%', format('the call was refused rather than carried out over an inverted range (got %s)', :'result'));
select alike(:'result'::text, '%empty or inverted%',
  'the refusal is archive._refuse_empty_range''s (#969), the check the PR body says still reads the instant the encoder reads');
select is(p1c.status('GET', :'p' || 'p1c.ny_2024031007300000.parquet'), 404,
  'no empty object was written at the key of the live cell [07:30Z, 08:00Z)');

select p1c.status('DELETE', :'p' || 'p1c.ny_2024031007300000.parquet');
select * from finish();
