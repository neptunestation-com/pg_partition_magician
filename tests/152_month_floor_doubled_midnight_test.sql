-- A month floor never exceeds its input, even where a fall-back makes midnight on the 1st happen twice
-- (issue #584).
--
-- _grid_floor's month branch turns "00:00 on the 1st in partition_tz" into an instant with `at time zone`.
-- Where the zone's clocks went back from 01:00 to 00:00 on the 1st (America/Havana on 2020-11-01, and
-- again on 2026-11-01), that wall time happens twice, and PostgreSQL resolves it to the LATER occurrence,
-- 00:00 CST (05:00Z). _grid_next converts the same way, so that is where the grid's November edge is, in
-- every grid ever built in such a zone. A value in the FIRST occurrence of the hour (04:00Z to 05:00Z)
-- reads November on the wall clock but lies before that edge, and _grid_floor returned the edge for it:
-- the floor of 04:30Z was 05:00Z, above its input. transmute takes the floor of the oldest value as the
-- monolith's lo, so a table whose oldest row fell in that hour got a bound CHECK that excluded the row,
-- VALIDATE failed, and every re-run failed the same way: the conversion could never complete.
--
-- The fix keeps the lattice where it is and makes the floor what a floor is: the greatest grid point at
-- or below the value. A value before its wall month's edge floors to the edge before it (October 1), so
-- the doubled hour's first occurrence belongs to the October cell, where every existing Havana grid
-- already routes it. Every value below is hand-derived (CDT is -04, CST -05), each with a witness that
-- the doubled hour really exists, and the end-to-end conversion is the issue's own.
-- bench/month_floor_doubled_midnight.sh runs this file against a mutant without the step back to the
-- previous edge (grid_floor_month_later_midnight), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(19);

-- ==================== (a) the doubled hour really exists ====================
select is((timestamptz '2020-11-01 04:30:00+00' at time zone 'America/Havana'), '2020-11-01 00:30:00'::timestamp,
  'LIVENESS: 04:30Z on 2020-11-01 reads 00:30 on November 1 in Havana');
select is((timestamptz '2020-11-01 05:30:00+00' at time zone 'America/Havana'), '2020-11-01 00:30:00'::timestamp,
  'LIVENESS: 05:30Z reads 00:30 too: the hour after midnight on the 1st happens twice');
select is(('2020-11-01 00:00'::timestamp at time zone 'America/Havana'), timestamptz '2020-11-01 05:00:00+00',
  'LIVENESS: PostgreSQL resolves the doubled 00:00 to the later occurrence, 05:00Z');
select is((timestamptz '2026-11-01 04:30:00+00' at time zone 'America/Havana'), '2026-11-01 00:30:00'::timestamp,
  'LIVENESS: it happens again on 2026-11-01: 04:30Z reads 00:30');

-- ==================== (b) the adapter, under a UTC session and a Havana session ====================
set timezone = 'UTC';
select is(pgpm._grid_next('time', '1 month',
    pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2020-10-15 12:00:00+00', 'America/Havana'), 'America/Havana')::timestamptz,
  timestamptz '2020-11-01 05:00:00+00',
  'LIVENESS: the grid''s November edge is the later midnight, 05:00Z: _grid_next of the October floor lands there');
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2020-11-01 04:30:00+00', 'America/Havana')::timestamptz,
  timestamptz '2020-10-01 04:00:00+00',
  'the floor of 04:30Z is the October edge, the greatest grid point at or below it (it was 05:00Z, above its input)');
select cmp_ok(pgpm._grid_next('time', '1 month',
    pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2020-11-01 04:30:00+00', 'America/Havana'), 'America/Havana')::timestamptz,
  '>', timestamptz '2020-11-01 04:30:00+00',
  'and the value lies inside that floor''s cell: the next edge is above it');
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2020-11-01 04:59:59.999999+00', 'America/Havana')::timestamptz,
  timestamptz '2020-10-01 04:00:00+00',
  'the last microsecond before the November edge floors to October too');
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2020-11-01 05:00:00+00', 'America/Havana')::timestamptz,
  timestamptz '2020-11-01 05:00:00+00',
  'the November edge floors to itself');
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2020-11-01 05:30:00+00', 'America/Havana')::timestamptz,
  timestamptz '2020-11-01 05:00:00+00',
  'the second occurrence of the hour floors to the November edge, as before');
select is(pgpm._grid_floor('time', '3 months', '2000-02-01 05:00:00+00', '2020-11-01 04:30:00+00', 'America/Havana')::timestamptz,
  timestamptz '2020-08-01 04:00:00+00',
  'a quarter step (an anchor at Havana midnight puts the phase on Feb/May/Aug/Nov) floors 04:30Z to the August edge, a whole step back');
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2026-11-01 04:30:00+00', 'America/Havana')::timestamptz,
  timestamptz '2026-10-01 04:00:00+00',
  'on 2026-11-01 the floor of 04:30Z is the October 2026 edge');
set timezone = 'America/Havana';
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2020-11-01 04:30:00+00', 'America/Havana')::timestamptz,
  timestamptz '2020-10-01 04:00:00+00',
  'and the same floor under a Havana session');
-- the gap case (#505) is untouched: midnight that does not exist still floors to the instant after the gap
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2023-10-15 12:00:00+00', 'America/Asuncion')::timestamptz,
  timestamptz '2023-10-01 04:00:00+00',
  'a month whose midnight fell in a gap still floors to its first instant');

-- ==================== (c) end to end: the issue's conversion ====================
create table public.hv (id bigint generated always as identity, ts timestamptz not null, tag text, primary key (id, ts));
insert into public.hv (ts, tag) values ('2020-11-01 04:30:00+00', 'first-hour'), ('2021-06-01 12:00:00+00', 'mid'),
                                       (now() - interval '1 day', 'recent');
select is((select string_agg(tag, ',' order by ts) from public.hv), 'first-hour,mid,recent',
  'LIVENESS: the fixture holds the three rows, the oldest in the first occurrence of the doubled hour');
-- a committing procedure, at top level: a VALIDATE failure here stops the file short of its plan
call pgpm.transmute('public.hv', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.hv'::regclass), 'p',
  'transmute completed: hv is now partitioned');
select is((select lo::timestamptz from pgpm.part where parent_table = 'public.hv'::regclass and attached order by lo::timestamptz limit 1),
  timestamptz '2020-10-01 04:00:00+00',
  'the monolith starts at the October 2020 edge, below the oldest row');
select is((select string_agg(tag, ',' order by ts) from public.hv), 'first-hour,mid,recent',
  'every row survives the conversion, by identity');
select is((select string_agg(h.tag, ',' order by h.ts) from public.hv h join pg_class c on c.oid = h.tableoid
            where c.relname = (select child_name from pgpm.part where parent_table = 'public.hv'::regclass and attached
                                order by lo::timestamptz limit 1)),
  'first-hour,mid,recent',
  'the monolith holds all three rows, the first-hour one included (it runs from that row''s floor to the first boundary after now())');

select * from finish();
