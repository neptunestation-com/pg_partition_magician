-- P1-01: pgpm._over_retired_chunks keys every bound through pgpm._native_bound_key, but hands it the CALLER's
-- TimeZone (v_tz := current_setting('TimeZone')) rather than the grid's config.partition_tz, so an offset-less
-- retired bound (a pre-#977 strategy's covered_hi stored verbatim) is still read on the session's clock and the
-- held set differs by session, against the PR body, CHANGELOG, docs/reference.md and tests/317's contract.
-- Fixture: a grid registered in Asia/Tokyo; two retired chunks whose hi carries no offset:
--   gone_a [p0.lo-6h, p0.lo-3h) on Tokyo's clock ends below p0: must NOT be held; read in UTC it reaches 6h into p0;
--   gone_b [p0.lo-4h, p0.lo+3h) on Tokyo's clock reaches into p0: MUST be held; read in Pacific/Kiritimati (+14)
--                                it ends 2h before p0.
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
  select coalesce(string_agg(format('%s: %s', o.child_name, o.chunks), E'\n' order by o.child_name), '')
    from pgpm._over_retired_chunks('p101.t') o;
$$;

insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid) values
  ('p101.t', '2025-12-31 18:00:00+09', '2025-12-31 21:00:00', 'gone_a', 'obj/a', now(), 4290000201),
  ('p101.t', '2025-12-31 20:00:00+09', '2026-01-01 03:00:00', 'gone_b', 'obj/b', now(), 4290000202);

\set expected 't_p2026_01_to_2026_11: [2025-12-31 20:00:00+09, 2026-01-01 03:00:00) recorded for gone_b, whose relation no longer exists, at obj/b'

select is((select partition_tz from pgpm.config where parent_table = 'p101.t'::regclass), 'Asia/Tokyo',
          'GUARD: the grid is registered in Asia/Tokyo');
select is((select lo from pgpm.part where parent_table = 'p101.t'::regclass and child_name = 't_p2026_01_to_2026_11'),
          '2026-01-01 00:00:00+09', 'GUARD: the first attached partition starts at 2026-01-01 00:00 Tokyo');
select ok(pgpm._native_order_key('2025-12-31 21:00:00') is null and pgpm._native_order_key('2026-01-01 03:00:00') is null,
          'LIVENESS: both retired chunks'' hi carry no offset (no order key), the shape an older ledger row has');
select is(p101.held(), :'expected',
          'LIVENESS: from a session on the grid''s own zone, p0 is held over gone_b alone');

-- pg_cron's zone
set timezone = 'UTC';
select ok('2025-12-31 21:00:00'::timestamptz > '2026-01-01 00:00:00+09'::timestamptz,
          'LIVENESS: read in UTC, gone_a''s hi reaches into p0 (the session''s own parse would hold it)');
select is(p101.held(), :'expected',
          'from UTC the call holds p0 over gone_b alone (gone_a is read on the grid''s clock, not the session''s)');

-- a zone east of the grid
set timezone = 'Pacific/Kiritimati';
select ok('2026-01-01 03:00:00'::timestamptz < '2026-01-01 00:00:00+09'::timestamptz,
          'LIVENESS: read in Pacific/Kiritimati, gone_b''s hi ends before p0 (the session''s own parse would drop it)');
select is(p101.held(), :'expected',
          'from Pacific/Kiritimati the call still holds p0 over gone_b (read on the grid''s clock, not the session''s)');
set timezone = 'UTC';

select * from finish();
