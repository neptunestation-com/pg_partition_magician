-- A clamped regrain sub-range is named by its own start, never by its lattice neighbour's (issue #783).
--
-- regrain_step named every fine child with _part_name at the target step's granularity, and a fixed step
-- (a day) is labelled by the UTC date of its start. A sub-range whose lo is off the target's lattice is
-- CLAMPED to the child's own lo, and the UTC date of that lo is the floor of the instant, which it shares
-- with the lattice cell before or after it. On a monthly grid in America/New_York regrained to '1 day',
-- January's last cell [02-01 00:00Z, 05:00Z) and February's clamped first cell [02-01 05:00Z, 02-02 00:00Z)
-- both rendered rc_p2024_02_01, so once January was split every regrain of February was refused ('a
-- relation named ... already exists and this regrain did not create it'). A Los Angeles monolith anchored at
-- local midnight (lattice 08:00Z, summer month edge 07:00Z) clamped [07:00Z, 08:00Z) under the name of the
-- cell after it, and auto-regrain logged skip_regrain on every tick with the capture trigger left on.
--
-- The contract: a clamped sub-range is labelled at the coarsest granularity, no coarser than the step's
-- own, at which both its bounds read exactly, so its name is one no other cell of the parent that does not
-- overlap it can render; a lattice cell's name is unchanged, and so is a clamped cell's whose bounds
-- already read exactly at the step's granularity (no grid's names move, #582).
--
-- Fixtures, asymmetric on purpose:
--   (A) New York, two adjacent monthly children regrained to a day: three rows in January's last cell
--       [02-01 00:00Z, 05:00Z), two in February's clamped first cell [02-01 05:00Z, 02-02 00:00Z), one a day
--       elsewhere, so a row filed in its neighbour's cell cannot cancel against one filed in its own.
--   (B) Los Angeles, the monolith auto-regrained to a day: one row in the clamped [07:00Z, 08:00Z), two in
--       the lattice cell after it.
--   (C) the naming function itself: a half-hour zone (minutes), an off-second edge (microseconds), and the
--       cases whose names must not move (a lattice cell, a weekly clamp on a UTC grid, an id grid).
-- bench/regrain_clamped_subrange_names.sh runs this file against the mutant that names a clamped sub-range
-- by its floor again (regrain_clamped_name_by_floor), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(22);

-- text_time keys (a ULID-shaped Crockford base32 prefix), so a write far ahead freezes the monolith; ts is the
-- instant each key encodes, kept beside it so the assertions read as instants
create function pg_temp.tt(p_ts timestamptz, p_tail text) returns text language sql immutable as $$
  select pgpm._ts_to_text_time(p_ts, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') || p_tail $$;
-- the bodies of the rows in the partition (or not-yet-attached copy) of p_parent over exactly [p_lo, p_hi),
-- found by its bounds and recorded oid, so a cell minted under the wrong name still answers
create function pg_temp.cell_bodies(p_parent regclass, p_lo timestamptz, p_hi timestamptz) returns text[]
language plpgsql as $$
declare v_oid oid; v text[];
begin
  select child_oid into v_oid from pgpm.part
   where parent_table = p_parent and lo::timestamptz = p_lo and hi::timestamptz = p_hi;
  if v_oid is null then return null; end if;
  execute format('select array_agg(body order by body) from %s', v_oid::regclass) into v;
  return v;
end $$;

-- ==================== (A) New York: January's last cell and February's first ====================
set timezone = 'America/New_York';
create table public.rc (id text collate "C" primary key, ts timestamptz not null, body text);
insert into public.rc (id, ts, body)
  select pg_temp.tt(d, 'D'), d, 'day' from generate_series('2024-01-01 12:00+00'::timestamptz, '2024-03-31 12:00+00'::timestamptz,
                                       interval '1 day') d;
insert into public.rc (id, ts, body) values
  (pg_temp.tt('2024-02-01 01:00+00', 'E'), '2024-02-01 01:00+00', 'jan-tail-1'),
  (pg_temp.tt('2024-02-01 02:30+00', 'E'), '2024-02-01 02:30+00', 'jan-tail-2'),
  (pg_temp.tt('2024-02-01 04:59:59+00', 'E'), '2024-02-01 04:59:59+00', 'jan-tail-3'),
  (pg_temp.tt('2024-02-01 05:00+00', 'E'), '2024-02-01 05:00+00', 'feb-head-1'),
  (pg_temp.tt('2024-02-01 23:59:59+00', 'E'), '2024-02-01 23:59:59+00', 'feb-head-2');
call pgpm.transmute('public.rc', 'id', interval '1 month', p_obtain => 4, p_paused => true,
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
select pgpm.obtain('public.rc');
insert into public.rc values (pg_temp.tt(date_trunc('month', now()) + interval '3 months 1 day', 'F'),
                              date_trunc('month', now()) + interval '3 months 1 day', 'frontier');   -- the monolith freezes
select is((select partition_tz || ' ' || partition_step::interval::text from pgpm.config
            where parent_table = 'public.rc'::regclass),
  'America/New_York 1 mon', 'LIVENESS: (A) a monthly grid in America/New_York');
select pgpm.regrain_history('public.rc', '1 month');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.rc'::regclass and attached
                    and child_name = 'rc_p2024_02' and lo::timestamptz = '2024-02-01 05:00+00'),
  'LIVENESS: (A) February is an attached monthly child starting at New York midnight, 05:00Z');
select isnt(pgpm._grid_floor('text_time', '1 day', (select partition_anchor from pgpm.config where parent_table = 'public.rc'::regclass),
                             '2024-02-01 05:00+00', 'America/New_York')::timestamptz,
  '2024-02-01 05:00+00'::timestamptz,
  'LIVENESS: (A) 05:00Z is off the day lattice, so February''s first daily sub-range is clamped');
select is(pgpm.regrain('public.rc', 'rc_p2024_01', '1 day'), 32, 'LIVENESS: (A) January splits into 32 daily cells');
select is((select child_name from pgpm.part where parent_table = 'public.rc'::regclass and attached
            and lo::timestamptz = '2024-02-01 00:00+00' and hi::timestamptz = '2024-02-01 05:00+00'),
  'rc_p2024_02_01'::name,
  'LIVENESS: (A) January''s last cell [02-01 00:00Z, 05:00Z) holds the name its UTC date renders');
select lives_ok($$ select pgpm.regrain('public.rc', 'rc_p2024_02', '1 day') $$,
  'A: February regrains to a day after January did');
select is((select child_name from pgpm.part where parent_table = 'public.rc'::regclass and attached
            and lo::timestamptz = '2024-02-01 05:00+00' and hi::timestamptz = '2024-02-02 00:00+00'),
  'rc_p2024_02_01_05'::name,
  'A: February''s clamped first cell [02-01 05:00Z, 02-02 00:00Z) is labelled to the hour its start reads exactly');
select is((select array_agg(child_name order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.rc'::regclass and attached
              and lo::timestamptz in ('2024-01-31 00:00+00', '2024-02-02 00:00+00', '2024-02-29 00:00+00')),
  array['rc_p2024_01_31', 'rc_p2024_02_02', 'rc_p2024_02_29']::name[],
  'A: the lattice cells on either side keep the names they always had');
select is(pg_temp.cell_bodies('public.rc', '2024-02-01 00:00+00', '2024-02-01 05:00+00'),
  array['jan-tail-1', 'jan-tail-2', 'jan-tail-3'],
  'A: January''s three tail rows sit in January''s last cell');
select is(pg_temp.cell_bodies('public.rc', '2024-02-01 05:00+00', '2024-02-02 00:00+00'),
  array['day', 'feb-head-1', 'feb-head-2'],
  'A: February''s first day (its 12:00Z row and its two edge rows) sits in February''s clamped first cell');
select is((select count(*)::int from public.rc r
            where r.ts >= '2024-02-01 05:00+00' and r.ts < '2024-03-01 05:00+00'
              and not exists (select 1 from pgpm.part p where p.parent_table = 'public.rc'::regclass and p.attached
                                and p.child_oid = r.tableoid and p.hi::timestamptz - p.lo::timestamptz <= interval '1 day')),
  0, 'A: none of February''s rows is left outside an attached cell at most a day wide');
select is((select count(*)::int from public.rc where ts >= '2024-02-01 05:00+00' and ts < '2024-03-01 05:00+00'),
  31, 'LIVENESS: (A) and February holds its 29 daily rows and two edge rows, so the check above was over something');

-- ==================== (B) Los Angeles: the monolith's clamped first cell, auto-regrained ====================
set timezone = 'America/Los_Angeles';
create table public.la (id text collate "C" primary key, ts timestamptz not null, body text);
insert into public.la (id, ts, body)
  select pg_temp.tt(d, 'D'), d, 'day' from generate_series('2024-07-02 12:00+00'::timestamptz, '2024-08-31 12:00+00'::timestamptz,
                                       interval '1 day') d;
insert into public.la (id, ts, body) values
  (pg_temp.tt('2024-07-01 07:30+00', 'E'), '2024-07-01 07:30+00', 'clamped'),
  (pg_temp.tt('2024-07-01 08:00+00', 'E'), '2024-07-01 08:00+00', 'lattice-1'),
  (pg_temp.tt('2024-07-02 07:59:59+00', 'E'), '2024-07-02 07:59:59+00', 'lattice-2');
call pgpm.transmute('public.la', 'id', interval '1 month', p_obtain => 4, p_paused => false,
                    p_anchor => '2000-01-01 00:00 America/Los_Angeles',
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
select pgpm.obtain('public.la');
insert into public.la values (pg_temp.tt(date_trunc('month', now()) + interval '3 months 1 day', 'F'),
                              date_trunc('month', now()) + interval '3 months 1 day', 'frontier');   -- the monolith freezes
select ok(exists (select 1 from pgpm.part where parent_table = 'public.la'::regclass and attached
                    and lo::timestamptz = '2024-07-01 07:00+00'),
  'LIVENESS: (B) a monthly Los Angeles grid whose monolith starts at the PDT month edge, 07:00Z');
select pgpm.set_regrain('public.la', '1 day');
do $$ declare v text; begin for i in 1..6 loop call pgpm.maintain('public.la', v); end loop; end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.la'::regclass and action = 'regrain_prepare'),
  'LIVENESS: (B) auto-regrain prepared the monolith');
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'public.la'::regclass and action = 'skip_regrain'),
  null::text[], 'B: no auto-regrain tick is refused (skip_regrain)');
select is((select child_name from pgpm.part where parent_table = 'public.la'::regclass and not attached
            and lo::timestamptz = '2024-07-01 07:00+00' and hi::timestamptz = '2024-07-01 08:00+00'),
  'la_p2024_07_01_07'::name,
  'B: the clamped first cell [07:00Z, 08:00Z) is named by its own start hour');
select is((select child_name from pgpm.part where parent_table = 'public.la'::regclass and not attached
            and lo::timestamptz = '2024-07-01 08:00+00' and hi::timestamptz = '2024-07-02 08:00+00'),
  'la_p2024_07_01'::name,
  'B: the lattice cell after it [07-01 08:00Z, 07-02 08:00Z) is minted under its own name');
select is(pg_temp.cell_bodies('public.la', '2024-07-01 07:00+00', '2024-07-01 08:00+00'), array['clamped'],
  'B: the clamped copy holds the one row of its hour');
select is(pg_temp.cell_bodies('public.la', '2024-07-01 08:00+00', '2024-07-02 08:00+00'), array['lattice-1', 'lattice-2'],
  'B: the lattice copy holds its two rows');

-- ==================== (C) the naming rule itself ====================
select is(pgpm._regrain_sub_name('x', jsonb_populate_record(c, '{"partition_tz": "Asia/Kolkata"}'), '1 day',
                                 '2024-01-31 18:30:00+00', '2024-02-01 00:00:00+00'),
          'x_p2024_01_31_1830'::name,
  'C: a clamped day cell at a half-hour zone''s month edge is labelled to the minute')
  from pgpm.config c where c.parent_table = 'public.rc'::regclass;
select is(pgpm._regrain_sub_name('x', c, '1 day', '2024-02-01 05:00:00.25+00', '2024-02-02 00:00:00+00'),
          'x_p2024_02_01_050000_250000'::name,
  'C: an edge off the whole second is labelled to the microsecond')
  from pgpm.config c where c.parent_table = 'public.rc'::regclass;
select is(array[pgpm._regrain_sub_name('x', c, '1 day', '2024-02-01 00:00:00+00', '2024-02-01 05:00:00+00'),
                pgpm._regrain_sub_name('x', jsonb_populate_record(c, '{"partition_tz": "UTC"}'), '1 week',
                                       '2024-03-01 00:00:00+00', '2024-03-02 00:00:00+00'),
                pgpm._regrain_sub_name('x', jsonb_populate_record(c, '{"control_kind": "id", "partition_anchor": "0"}'),
                                       '7000', '20000', '21000')],
          array[pgpm._part_name('x', 'text_time', '1 day', '2024-02-01 00:00:00+00', '2024-02-01 05:00:00+00', 'America/New_York'),
                pgpm._part_name('x', 'text_time', '1 week', '2024-03-01 00:00:00+00', '2024-03-02 00:00:00+00', 'UTC'),
                pgpm._part_name('x', 'id', '7000', '20000', '21000', 'UTC')],
  'C: a lattice cell, a weekly clamp whose bounds read exactly as dates, and an id cell keep _part_name''s names')
  from pgpm.config c where c.parent_table = 'public.rc'::regclass;

select * from finish();
