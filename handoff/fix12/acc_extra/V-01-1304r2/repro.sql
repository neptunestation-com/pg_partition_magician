-- #969: a direct strategy call refuses an empty or inverted range before anything is read or sent, because the
-- key is derived from lo alone and an empty read PUTs an empty object at the chunk's key. The head reads the
-- bounds on the grid's clock (archive._bound_native: an offset-less bound in partition_tz), but
-- archive._refuse_empty_range still compares the RAW text in the caller's session. On a timestamptz grid with
-- partition_tz Asia/Kolkata, a UTC caller passes lo = '2024-01-02 18:30:00+00' (the cell's start, with its
-- offset) and hi = '2024-01-03' (offset-less). The session reads [18:30Z, 00:00Z): non-empty, admitted. The
-- grid reads hi as 2024-01-03 00:00 IST = 2024-01-02 18:30Z = lo: empty. The call reads no row and PUTs an empty
-- object at the cell's own key (k.ev_2024010218300000) instead of refusing.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(6);

create schema k;
set timezone = 'Asia/Kolkata';
create table k.ev (ts timestamptz not null, payload text not null, primary key (ts, payload));
insert into k.ev values ('2024-01-01 20:00:00+00', 'a'), ('2024-01-02 03:00:00+00', 'b'), ('2024-01-02 20:00:00+00', 'c');
call pgpm.transmute('k.ev', 'ts', interval '1 day', p_paused => true);
select pgpm.obtain('k.ev');
select 'v01-1304-' || current_database() || '/' as p \gset
select archive.configure('k.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
create function k.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function k.try(p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  r := pgpm.archive_to_s3_ndjson('k.ev', null, p_lo, p_hi);
  return r.s3_key || ' rows=' || coalesce(r.rows_archived::text, 'null');
exception when others then return 'ERR: ' || sqlerrm;
end $$;
set timezone = 'UTC';

select is((select partition_tz from pgpm.config where parent_table = 'k.ev'::regclass), 'Asia/Kolkata',
  'GUARD: the grid''s clock is Asia/Kolkata');
select ok('2024-01-03'::timestamptz > '2024-01-02 18:30:00+00'::timestamptz,
  'LIVENESS: the caller''s session (UTC) reads [lo, hi) as non-empty, so the session-side empty-range check admits it');
select is(('2024-01-03'::timestamp at time zone 'Asia/Kolkata'), '2024-01-02 18:30:00+00'::timestamptz,
  'LIVENESS: on the grid''s clock (offset-less hi read in partition_tz, as docs/reference.md says a direct call reads it) hi equals lo: the range is empty');

select k.try('2024-01-02 18:30:00+00', '2024-01-03') as result \gset
select ok(:'result'::text like 'ERR:%' or :'result'::text like '% rows=0' or :'result'::text like '% rows=1',
  format('LIVENESS: the call ran to a result (%s)', :'result'));

-- the defect: an empty range by the call's own reading is PUT rather than refused (#969)
select ok(:'result'::text not like '% rows=0',
  format('a range the call reads as empty is refused, not archived as zero rows (got %s)', :'result'));
select ok((select r.status <> 200 or coalesce(length(r.content), 0) > 0 from k.req('GET', :'p' || 'k.ev_2024010218300000.ndjson') r),
  'no empty object lands at the 2 January cell''s key (k.ev_2024010218300000)');

select (k.req('DELETE', :'p' || 'k.ev_2024010218300000.ndjson')).status as c1 \gset
select * from finish();
