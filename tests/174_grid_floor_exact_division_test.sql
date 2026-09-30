-- A floor never exceeds its input, whatever the magnitude of the quotient behind it (issue #659).
--
-- Three sites took floor() of a quotient that had already been rounded. General numeric division computes
-- a non-terminating quotient to a bounded scale (about 16 significant digits past the integer part), so a
-- quotient a hair below an integer rounds UP to it before floor() sees it; double precision division does
-- the same at 15 to 17 significant digits. The floor then lands one step ABOVE its input:
--
--   _text_time_to_ts: floor(v_wide / 2^discard_bits). A KSUID stamped 2020-12-31 23:59:59Z whose 128
--     random low bits are near all-ones decoded to 2021-01-01 00:00:00Z.
--   _grid_floor, id:  floor((x - anchor) / step). With a snowflake-scale step of 3e16, the id
--     1799999999999999999 floored to 1800000000000000000.
--   _grid_floor, fixed time step: floor(epoch(ts - anchor) / secs) in double precision. With an anchor in
--     year 1, the last microsecond before 2026-03-01 floored (daily step) to 2026-03-01 itself.
--
-- transmute takes the floor of the OLDEST value as the monolith's lo, so a table whose oldest row was such
-- a value got a bound CHECK that excluded the row, VALIDATE failed, and every re-run failed the same way.
-- All three now go through pgpm._floor_div, an exact integer floor (div() with a sign correction), which
-- _radix_encode already relied on for the same reason. Each site is checked on its own below, with a
-- witness that the rounding it was exposed to really happens on this server, and each conversion is the
-- issue's own. bench/grid_floor_exact.sh runs this file against one mutant per site
-- (text_time_decode_rounded_floor, grid_floor_id_rounded_floor, grid_floor_fixed_float_floor), so it is
-- also required to FAIL against each.
create extension if not exists pgtap;
set timezone = 'UTC';
select plan(30);

-- ==================== (a) the rounding is real on this server ====================
select is(floor(1799999999999999999::numeric / 30000000000000000::numeric), 60::numeric,
  'LIVENESS: general numeric division rounds 1799999999999999999 / 3e16 up to 60, so floor() of it is 60');
select is(div(1799999999999999999::numeric, 30000000000000000::numeric), 59::numeric,
  'LIVENESS: the exact integer quotient is 59');
select is(floor(((power(2::numeric, 128) * 209519999) + (power(2::numeric, 128) - 1)) / power(2::numeric, 128)),
  209520000::numeric,
  'LIVENESS: a 160-bit KSUID payload whose random bits are all ones rounds up to the next second under /');
select is(floor(extract(epoch from (timestamptz '2026-03-01 00:00:00+00' - interval '1 microsecond'
                                    - timestamptz '0001-01-01 00:00:00+00'))::float8 / 86400::float8)::numeric,
  div(extract(epoch from (timestamptz '2026-03-01 00:00:00+00' - timestamptz '0001-01-01 00:00:00+00')), 86400),
  'LIVENESS: in double precision, one microsecond before a day boundary 2025 years from the anchor divides to the boundary''s own day');

-- ==================== (b) the exact floor ====================
select is(pgpm._floor_div(1799999999999999999, 30000000000000000), 59::numeric,
  '_floor_div is exact where / rounds');
select is(pgpm._floor_div(-5, 10), -1::numeric, '_floor_div floors a negative quotient down, not toward zero');
select is(pgpm._floor_div(-10, 10), -1::numeric, '_floor_div of an exact negative multiple is that multiple');
select is(pgpm._floor_div(7.5, 2), 3::numeric, '_floor_div takes a fractional dividend');
select is(pgpm._floor_div(-0.5, 2), -1::numeric, '_floor_div floors a fractional negative dividend down');

-- ==================== (c) _grid_floor, id ====================
select is(pgpm._grid_floor('id', '30000000000000000', '0', '1799999999999999999', 'UTC'), '1770000000000000000',
  'the id floor of 1799999999999999999 at step 3e16 is 1770000000000000000, not above its input');
select is(pgpm._grid_floor('id', '30000000000000000', '0', '1800000000000000000', 'UTC'), '1800000000000000000',
  'the boundary itself floors to itself');
select is(pgpm._grid_floor('id', '30000000000000000', '7', '1800000000000000006', 'UTC'), '1770000000000000007',
  'with an off-zero anchor, one below a boundary floors to the boundary before it');
select is(pgpm._grid_floor('id', '10', '0', '-5', 'UTC'), '-10', 'an id below the anchor floors down, to -10');
select is(pgpm._grid_floor('id', '10', '0', '-10', 'UTC'), '-10', 'an id below the anchor on a boundary floors to itself');
select is(pgpm._grid_floor('id', '10', '3', '17', 'UTC'), '13', 'a small id floors as it always did');

-- ==================== (d) _grid_floor, fixed time step ====================
select is(pgpm._grid_floor('time', '1 day', '0001-01-01 00:00:00+00', '2026-02-28 23:59:59.999999+00', 'UTC')::timestamptz,
  timestamptz '2026-02-28 00:00:00+00',
  'with an anchor in year 1, the last microsecond of Feb 28 2026 floors to Feb 28, not Mar 1');
select is(pgpm._grid_floor('time', '1 day', '0001-01-01 00:00:00+00', '2026-03-01 00:00:00+00', 'UTC')::timestamptz,
  timestamptz '2026-03-01 00:00:00+00', 'and Mar 1 floors to itself');
select is(pgpm._grid_floor('time', '1 day', '2000-01-01 00:00:00+00', '1999-12-31 12:00:00+00', 'UTC')::timestamptz,
  timestamptz '1999-12-31 00:00:00+00', 'a value before the anchor floors down, to the day before it');
select is(pgpm._grid_floor('time', '90 minutes', '2000-01-01 00:00:00+00', '2000-01-01 02:59:59.999999+00', 'UTC')::timestamptz,
  timestamptz '2000-01-01 01:30:00+00', 'a 90-minute step floors as it always did');

-- ==================== (e) _text_time_to_ts ====================
create temp table k174 as
  select pgpm._radix_encode(
           (extract(epoch from timestamptz '2020-12-31 23:59:59+00') - 1400000000)::numeric * power(2::numeric, 128)
             + (power(2::numeric, 128) - 1),
           62, 27, '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz') as edge;
select is(pgpm._text_time_to_ts((select edge from k174), '', 27, 62, 's',
            '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00'),
  timestamptz '2020-12-31 23:59:59+00',
  'a KSUID stamped 23:59:59 with all-ones random bits decodes to 23:59:59, not the next second');

-- ==================== (f) end to end: each conversion completes, every row kept ====================
-- committing procedures, at top level: a VALIDATE failure stops the file short of its plan
create table public.t174_sf (id bigint primary key, tag text);
insert into public.t174_sf values (1799999999999999999, 'edge'), (1800000000000000005, 'next'), (1812345678901234567, 'newest');
call pgpm.transmute('public.t174_sf', 'id', 30000000000000000::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.t174_sf'::regclass), 'p',
  'id: transmute completed, t174_sf is now partitioned');
select is((select lo from pgpm.part where parent_table = 'public.t174_sf'::regclass and attached order by lo::numeric limit 1),
  '1770000000000000000', 'id: the monolith starts at the edge id''s floor, below it');
select is((select string_agg(tag, ',' order by id) from public.t174_sf), 'edge,next,newest',
  'id: every id survives the conversion, the edge one included');

create table public.t174_ks (id text collate "C" primary key, tag text);
insert into public.t174_ks
  select edge, 'edge' from k174
  union all
  select pgpm._ts_to_text_time(timestamptz '2021-03-10 12:00:00+00', '', 27, 62, 's',
           '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00'), 'march';
call pgpm.transmute('public.t174_ks', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => '', p_tt_width => 27, p_tt_radix => 62, p_tt_unit => 's',
  p_tt_alphabet => '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
  p_tt_discard_bits => 128, p_tt_epoch => timestamptz '2014-05-13 16:53:20+00');
select is((select relkind::text from pg_class where oid = 'public.t174_ks'::regclass), 'p',
  'KSUID: transmute completed, t174_ks is now partitioned');
select is((select lo::timestamptz from pgpm.part where parent_table = 'public.t174_ks'::regclass and attached
            order by lo::timestamptz limit 1),
  timestamptz '2020-12-01 00:00:00+00', 'KSUID: the monolith starts at December 2020, the edge row''s month');
select is((select string_agg(tag, ',' order by id collate "C") from public.t174_ks), 'edge,march',
  'KSUID: both rows survive the conversion, the edge one included');

create table public.t174_ts (id bigint generated always as identity, ts timestamptz not null, tag text, primary key (id, ts));
insert into public.t174_ts (ts, tag) values ('2026-02-28 23:59:59.999999+00', 'edge'), ('2026-03-05 12:00:00+00', 'march');
call pgpm.transmute('public.t174_ts', 'ts', interval '1 day', p_obtain => 2, p_anchor => '0001-01-01 00:00:00+00');
select is((select relkind::text from pg_class where oid = 'public.t174_ts'::regclass), 'p',
  'fixed step: transmute completed, t174_ts is now partitioned');
select is((select lo::timestamptz from pgpm.part where parent_table = 'public.t174_ts'::regclass and attached
            order by lo::timestamptz limit 1),
  timestamptz '2026-02-28 00:00:00+00', 'fixed step: the monolith starts at Feb 28, the edge row''s day');
select is((select string_agg(tag, ',' order by ts) from public.t174_ts), 'edge,march',
  'fixed step: both rows survive the conversion, the edge one included');
select is((select string_agg(h.tag, ',' order by h.ts) from public.t174_ts h join pg_class c on c.oid = h.tableoid
            where c.relname = (select child_name from pgpm.part where parent_table = 'public.t174_ts'::regclass and attached
                                order by lo::timestamptz limit 1)),
  'edge,march', 'fixed step: the monolith holds both rows, by identity');

select * from finish();
