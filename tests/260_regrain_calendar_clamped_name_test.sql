-- A clamped calendar regrain sub-range is named by its own start, never by its lattice neighbour's (issue #904).
--
-- _regrain_sub_name labelled a sub-range clamped to a child's off-lattice lo at a finer granularity than the
-- step's own when the step was fixed (#783), and left every CALENDAR step (month, year) to _part_name, on the
-- premise that a child edge of a calendar grid sits on the target's lattice. It sits on a calendar edge, not
-- on the target's: a '1 year' lattice starts in whatever month the anchor reads in partition_tz. The default
-- anchor (2000-01-01 00:00Z) reads 31 December west of UTC, so in America/New_York the year cells start on
-- 1 December, and a monthly monolith starting 2023-03-01 clamped [2023-03-01, 2023-12-01) under 2023, the
-- label of the lattice cell after it, [2023-12-01, 2024-12-01). regrain_history(.., '1 year'), the runbook's
-- hierarchical split, refused its own first copy as 'a relation ... this regrain did not create'. A
-- non-January p_anchor does the same in UTC.
--
-- The contract: a clamped calendar sub-range is labelled at the coarsest granularity, no coarser than the
-- step's own, at which both its bounds read exactly (the year and the month on partition_tz's wall clock, a
-- fixed granularity in UTC, as _part_name labels each), so no cell of the parent that does not overlap it can
-- render its name; a lattice cell's name is unchanged, and so is a clamped cell's whose bounds already read
-- exactly at the step's granularity.
--
-- Fixtures, asymmetric on purpose:
--   (A) the issue's: a ULID table transmuted in America/New_York with the default anchor, regrained to a
--       year. Two edge rows in the clamped cell's last hour, one in the lattice cell's first, plus a row a day.
--   (B) a ULID table in UTC with p_anchor in April, regrained to a year: one edge row in the clamped
--       [2023-02-01, 2023-04-01), two in the lattice cell after it.
--   (C) the naming function itself: a January lattice, where the clamp moves too; the cases whose names must
--       not move (a clamp reading whole years on a '2 years' step, a quarter clamp reading whole months, a
--       lattice cell); and a clamp that reads exactly only to the day.
-- bench/regrain_calendar_clamped_name.sh runs this file against the mutant that leaves calendar steps to
-- _part_name again (regrain_calendar_name_by_lattice), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(20);

create function pg_temp.tt(p_ts timestamptz, p_tail text) returns text language sql immutable as $$
  select pgpm._ts_to_text_time(p_ts, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') || p_tail $$;
-- the attached partition of p_parent over exactly [p_lo, p_hi): its name and the edge rows (body <> 'day') it
-- holds, found by its bounds and recorded oid, so a cell minted under the wrong name still answers
create function pg_temp.cell(p_parent regclass, p_lo timestamptz, p_hi timestamptz) returns text
language plpgsql as $$
declare v_oid oid; v_name name; v text[];
begin
  select child_oid, child_name into v_oid, v_name from pgpm.part
   where parent_table = p_parent and attached and lo::timestamptz = p_lo and hi::timestamptz = p_hi;
  if v_oid is null then return null; end if;
  execute format('select array_agg(body order by body) from %s where body <> %L', v_oid::regclass, 'day') into v;
  return v_name || ' ' || coalesce(v::text, '{}');
end $$;

-- ==================== (A) America/New_York, default anchor: year cells start on 1 December ====================
set timezone = 'America/New_York';
create table public.ny (id text collate "C" primary key, body text);
insert into public.ny
  select pg_temp.tt(d, substr(upper(md5(d::text)), 1, 16)), 'day'
    from generate_series('2023-03-15 12:00-04'::timestamptz, '2025-06-30 12:00-04'::timestamptz, interval '1 day') d;
insert into public.ny values
  (pg_temp.tt('2023-11-30 23:10-05', 'E'), 'nov-tail-1'),
  (pg_temp.tt('2023-11-30 23:59:59-05', 'E'), 'nov-tail-2'),
  (pg_temp.tt('2023-12-01 00:00-05', 'E'), 'dec-head');
call pgpm.transmute('public.ny', 'id', interval '1 month', p_obtain => 4, p_paused => false,
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
select pgpm.obtain('public.ny');
insert into public.ny values (pg_temp.tt(date_trunc('month', now()) + interval '3 months 1 day', 'F'), 'frontier');   -- freezes the monolith
create temp table ny_before as select id from public.ny;

select is((select partition_tz || ' ' || partition_step::interval::text || ' '
                  || (partition_anchor::timestamptz at time zone 'America/New_York')::text
             from pgpm.config where parent_table = 'public.ny'::regclass),
  'America/New_York 1 mon 1999-12-31 19:00:00',
  'A LIVENESS: a monthly New York grid whose default anchor reads December there, so year cells start on 1 December');
select is((select (lo::timestamptz at time zone 'America/New_York')::text from pgpm.part
            where parent_table = 'public.ny'::regclass and attached order by lo::timestamptz limit 1),
  '2023-03-01 00:00:00', 'A LIVENESS: the monolith starts 2023-03-01, off the year lattice');
select is(array[pgpm._regrain_sub_name('ny', c, '1 year', pgpm._ts_text('2023-03-01 00:00-05'), pgpm._ts_text('2023-12-01 00:00-05')),
                pgpm._regrain_sub_name('ny', c, '1 year', pgpm._ts_text('2023-12-01 00:00-05'), pgpm._ts_text('2024-12-01 00:00-05'))],
          array['ny_p2023_03', 'ny_p2023']::name[],
  'A: the clamped first year cell is labelled by its own month, the lattice cell after it keeps its year')
  from pgpm.config c where c.parent_table = 'public.ny'::regclass;
select lives_ok($$ select pgpm.regrain_history('public.ny', '1 year') $$,
  'A: regrain_history(.., ''1 year'') splits the monolith into years');
select is(pg_temp.cell('public.ny', '2023-03-01 00:00-05', '2023-12-01 00:00-05'),
  'ny_p2023_03 {nov-tail-1,nov-tail-2}',
  'A: the clamped cell [2023-03-01, 2023-12-01) is attached as ny_p2023_03 and holds the two November tail rows');
select is(pg_temp.cell('public.ny', '2023-12-01 00:00-05', '2024-12-01 00:00-05'),
  'ny_p2023 {dec-head}',
  'A: the lattice cell [2023-12-01, 2024-12-01) is attached as ny_p2023 and holds the December head row');
select is(pg_temp.cell('public.ny', '2024-12-01 00:00-05', '2025-12-01 00:00-05'),
  'ny_p2024 {}',
  'A: the next lattice cell keeps its year name');
select ok(not exists ((select id from ny_before except select id from public.ny)
                      union all (select id from public.ny except select id from ny_before)),
  'A: the table holds exactly the rows it held before the regrain');
select is((select count(*)::int from public.ny), (select count(*)::int from ny_before),
  'A LIVENESS: and those are every row the fixture wrote, so the comparison above was over something');

-- ==================== (B) UTC, p_anchor in April: year cells start on 1 April ====================
set timezone = 'UTC';
create table public.ap (id text collate "C" primary key, body text);
insert into public.ap
  select pg_temp.tt(d, 'D'), 'day' from generate_series('2023-02-10 12:00+00'::timestamptz, '2024-06-30 12:00+00'::timestamptz, interval '1 day') d;
insert into public.ap values
  (pg_temp.tt('2023-03-31 23:59:59+00', 'E'), 'mar-tail'),
  (pg_temp.tt('2023-04-01 00:00+00', 'E'), 'apr-head-1'),
  (pg_temp.tt('2023-04-01 00:00:01+00', 'E'), 'apr-head-2');
call pgpm.transmute('public.ap', 'id', interval '1 month', p_obtain => 4, p_paused => false,
                    p_anchor => '2000-04-01 00:00+00',
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
select pgpm.obtain('public.ap');
insert into public.ap values (pg_temp.tt(date_trunc('month', now()) + interval '3 months 1 day', 'F'), 'frontier');   -- freezes the monolith
create temp table ap_before as select id from public.ap;
select is((select (lo::timestamptz at time zone 'UTC')::text from pgpm.part
            where parent_table = 'public.ap'::regclass and attached order by lo::timestamptz limit 1),
  '2023-02-01 00:00:00', 'B LIVENESS: the monolith starts 2023-02-01, off the April year lattice');
select is(pgpm._grid_floor('text_time', '1 year', (select partition_anchor from pgpm.config where parent_table = 'public.ap'::regclass),
                           '2023-02-01 00:00+00', 'UTC')::timestamptz,
  '2022-04-01 00:00+00'::timestamptz, 'B LIVENESS: the year lattice cell around it starts in April');
select lives_ok($$ select pgpm.regrain_history('public.ap', '1 year') $$,
  'B: regrain_history(.., ''1 year'') splits the monolith into years');
select is(pg_temp.cell('public.ap', '2023-02-01 00:00+00', '2023-04-01 00:00+00'),
  'ap_p2023_02 {mar-tail}',
  'B: the clamped cell [2023-02-01, 2023-04-01) is attached as ap_p2023_02 and holds the one March tail row');
select is(pg_temp.cell('public.ap', '2023-04-01 00:00+00', '2024-04-01 00:00+00'),
  'ap_p2023 {apr-head-1,apr-head-2}',
  'B: the lattice cell [2023-04-01, 2024-04-01) is attached as ap_p2023 and holds the two April head rows');
select ok(not exists ((select id from ap_before except select id from public.ap)
                      union all (select id from public.ap except select id from ap_before)),
  'B: the table holds exactly the rows it held before the regrain');
select is((select count(*)::int from public.ap), (select count(*)::int from ap_before),
  'B LIVENESS: and those are every row the fixture wrote');

-- ==================== (C) the naming rule itself ====================
-- a January lattice (UTC, the default anchor): a child's last cell [2023-01-01, 2023-03-01) is a lattice
-- cell, and the next child's clamped first cell [2023-03-01, 2024-01-01) must not render the same year
select is(array[pgpm._regrain_sub_name('x', u, '1 year', pgpm._ts_text('2023-01-01 00:00+00'), pgpm._ts_text('2023-03-01 00:00+00')),
                pgpm._regrain_sub_name('x', u, '1 year', pgpm._ts_text('2023-03-01 00:00+00'), pgpm._ts_text('2024-01-01 00:00+00'))],
          array['x_p2023', 'x_p2023_03']::name[],
  'C: on a January lattice a clamped year cell is labelled by its month, apart from the lattice cell before it')
  from (select jsonb_populate_record(c, '{"partition_tz": "UTC"}') u from pgpm.config c
         where c.parent_table = 'public.ny'::regclass) s;
select is(array[pgpm._regrain_sub_name('x', u, '2 years', pgpm._ts_text('2023-01-01 00:00+00'), pgpm._ts_text('2024-01-01 00:00+00')),
                pgpm._regrain_sub_name('x', u, '3 months', pgpm._ts_text('2023-02-01 00:00+00'), pgpm._ts_text('2023-04-01 00:00+00')),
                pgpm._regrain_sub_name('x', u, '1 year', pgpm._ts_text('2024-01-01 00:00+00'), pgpm._ts_text('2024-06-01 00:00+00'))],
          array[pgpm._part_name('x', 'text_time', '2 years', pgpm._ts_text('2023-01-01 00:00+00'), pgpm._ts_text('2024-01-01 00:00+00'), 'UTC'),
                pgpm._part_name('x', 'text_time', '3 months', pgpm._ts_text('2023-02-01 00:00+00'), pgpm._ts_text('2023-04-01 00:00+00'), 'UTC'),
                pgpm._part_name('x', 'text_time', '1 year', pgpm._ts_text('2024-01-01 00:00+00'), pgpm._ts_text('2024-06-01 00:00+00'), 'UTC')],
  'C: a clamp reading whole years, a quarter clamp reading whole months, and a lattice cell keep _part_name''s names')
  from (select jsonb_populate_record(c, '{"partition_tz": "UTC"}') u from pgpm.config c
         where c.parent_table = 'public.ny'::regclass) s;
select is(array[pgpm._part_name('x', 'text_time', '2 years', pgpm._ts_text('2023-01-01 00:00+00'), pgpm._ts_text('2024-01-01 00:00+00'), 'UTC'),
                pgpm._part_name('x', 'text_time', '3 months', pgpm._ts_text('2023-02-01 00:00+00'), pgpm._ts_text('2023-04-01 00:00+00'), 'UTC')],
          array['x_p2023', 'x_p2023_02']::name[],
  'C LIVENESS: those _part_name names are the plain year and month labels, so the comparison above pinned something');
select is(pgpm._regrain_sub_name('x', c, '1 year', pgpm._ts_text('2023-03-01 00:00+00'), pgpm._ts_text('2023-12-01 00:00+00')),
          'x_p2023_03_01'::name,
  'C: a New York year clamp whose bounds are UTC midnights reads exactly only to the day, and is labelled to it')
  from pgpm.config c where c.parent_table = 'public.ny'::regclass;

select * from finish();
