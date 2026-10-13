-- F15-02: pgpm._over_retired_chunks reads an offset-less retired ledger bound in the CALLER's TimeZone, so the
-- same call holds a partition from a UTC session (pg_cron's maintain) and not from an Asia/Kolkata one (a hand
-- _archive_step / retain()), or the reverse. Its own header (tests/317) promises the same answer "from any
-- session's TimeZone and DateStyle". Fixture: the grid is registered in UTC; one retired chunk, recorded
-- without an offset (a pre-#500 ledger row, or a strategy's offset-less covered_hi kept by an older install),
-- ends 3 hours past the first attached partition's lo on the UTC wall clock: 2.5 hours BEFORE it in Kolkata.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(5);

create schema f15b;
create table f15b.t (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into f15b.t (ts) select timestamptz '2026-01-05 00:00:00+00' + g * interval '1 hour' from generate_series(1, 90) g;
call pgpm.transmute('f15b.t', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select pgpm.set_archive_fn('f15b.t', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);

select child_name as p0, lo as p0_lo from pgpm.part where parent_table = 'f15b.t'::regclass and attached
 order by lo::timestamptz limit 1 \gset
-- the chunk: [lo - 4h, lo + 3h) as UTC wall-clock text, no offset
select to_char((:'p0_lo'::timestamptz at time zone 'UTC') - interval '4 hours', 'YYYY-MM-DD HH24:MI:SS') as c_lo,
       to_char((:'p0_lo'::timestamptz at time zone 'UTC') + interval '3 hours', 'YYYY-MM-DD HH24:MI:SS') as c_hi \gset
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid)
values ('f15b.t', :'c_lo', :'c_hi', 'gone_f15', 'obj/f15', now(), 4290000099);

select is((select partition_tz from pgpm.config where parent_table = 'f15b.t'::regclass), 'UTC',
  'LIVENESS: the grid is registered in UTC');
select ok(:'c_hi' !~ '[+-][0-9]{2}(:[0-9]{2})?$' and pgpm._native_order_key(:'c_hi') is null,
  'LIVENESS: the retired chunk''s bounds carry no offset (no order key), the shape an older ledger row has');
select is((select string_agg(child_name::text, ',') from pgpm._over_retired_chunks('f15b.t')), :'p0',
  'LIVENESS: from a UTC session the first attached partition is held over the retired chunk');

set timezone = 'Asia/Kolkata';
select ok(:'c_hi'::timestamptz < :'p0_lo'::timestamptz,
  'LIVENESS: read in Asia/Kolkata the same chunk text ends before that partition''s lo');
select is((select string_agg(child_name::text, ',') from pgpm._over_retired_chunks('f15b.t')), :'p0',
  'from an Asia/Kolkata session the same call holds the same partition (it does not: the offset-less bound is read in the session zone, not the grid''s)');
set timezone = 'UTC';

select * from finish();
