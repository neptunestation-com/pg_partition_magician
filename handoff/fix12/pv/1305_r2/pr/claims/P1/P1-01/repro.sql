-- P1-01: pgpm._over_retired_chunks hands pgpm._native_bound_key the CALLER's TimeZone (current_setting('TimeZone'))
-- as p_tz, not config.partition_tz, so an offset-less retired bound is still wall time in the session's zone and the
-- same call answers differently per session. The grid is registered in Asia/Tokyo (+09). Two retired chunks, both
-- with an offset-less hi, placed so the two wrong sessions err in opposite directions (nothing can cancel):
--   gone_a [p0.lo - 6h, p0.lo - 3h) on Tokyo's clock: NOT over p0 on the grid's clock; read in UTC it ends 6h INTO p0
--   gone_b [p0.lo - 4h, p0.lo + 3h) on Tokyo's clock: over p0 on the grid's clock; read in Pacific/Kiritimati (+14)
--                                   it ends 2h BEFORE p0
-- Expected from every session: p0 held over gone_b alone.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'Asia/Tokyo';
select plan(8);

create schema p101;
create table p101.t (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into p101.t (ts) select timestamptz '2026-01-05 00:00:00+00' + g * interval '1 hour' from generate_series(1, 90) g;
call pgpm.transmute('p101.t', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select pgpm.set_archive_fn('p101.t', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);

create function p101.held() returns text language sql as $$
  select coalesce(string_agg(format('%s: %s', o.child_name, o.chunks), E'\n' order by o.child_name), '<nothing held>')
    from pgpm._over_retired_chunks('p101.t') o;
$$;

select is((select partition_tz from pgpm.config where parent_table = 'p101.t'::regclass), 'Asia/Tokyo',
          'GUARD: the grid is registered in Asia/Tokyo');
select is((select lo from pgpm.part where parent_table = 'p101.t'::regclass and attached order by lo::timestamptz limit 1),
          '2026-01-01 00:00:00+09', 'GUARD: the first attached partition p0 starts at midnight 1 January on Tokyo''s clock');

insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid) values
  ('p101.t', '2025-12-31 18:00:00+09', '2025-12-31 21:00:00', 'gone_a', 'obj/a', now(), 4290000201),
  ('p101.t', '2025-12-31 20:00:00+09', '2026-01-01 03:00:00', 'gone_b', 'obj/b', now(), 4290000202);

select ok(pgpm._native_order_key('2025-12-31 21:00:00') is null and pgpm._native_order_key('2026-01-01 03:00:00') is null,
          'LIVENESS: both retired chunks'' hi carry no offset (no order key), the shape an older ledger row has');

\set expected 't_p2026_01_to_2026_11: [2025-12-31 20:00:00+09, 2026-01-01 03:00:00) recorded for gone_b, whose relation no longer exists, at obj/b'
select is(p101.held(), :'expected',
          'LIVENESS: from a session on the grid''s own zone, p0 is held over gone_b alone (the grid-clock answer)');

set timezone = 'UTC';
select ok('2025-12-31 21:00:00'::timestamptz > '2026-01-01 00:00:00+09'::timestamptz,
          'LIVENESS: read in UTC, gone_a''s hi ends inside p0');
select is(p101.held(), :'expected',
          'from a UTC session (pg_cron''s) p0 is held over gone_b alone, not over gone_a as well');

set timezone = 'Pacific/Kiritimati';
select ok('2026-01-01 03:00:00'::timestamptz < '2026-01-01 00:00:00+09'::timestamptz,
          'LIVENESS: read in Pacific/Kiritimati, gone_b''s hi ends before p0');
select is(p101.held(), :'expected',
          'from a Pacific/Kiritimati session p0 is still held over gone_b');
set timezone = 'UTC';

select * from finish();
