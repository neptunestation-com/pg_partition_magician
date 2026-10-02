-- _grid_floor's calendar branch floors to the greatest grid point at or below its input on both sides
-- of the era (issue #769, its BC bullet: pass-6 F2-03, pass-7 F2-01).
--
-- The month and year branch counts the months from the anchor to the value as a year difference times 12
-- plus a month difference, and took the years from extract(year), which numbers 1 BC as -1 and 1 AD as 1:
-- there is no year 0, while the month arithmetic that builds the floor back from the anchor has one. Across
-- the era the count was 12 months off. From the default 2000 anchor a BC value floored a whole year early
-- (a BC grid point never floored to itself, its cell [floor, next) did not contain it); from a BC anchor
-- an AD value floored ABOVE itself, which #584's one-step correction rescues for a yearly step but not
-- for a monthly one. What an operator meets, both reproduced below: an interrupted transmute of a table
-- with BC rows is refused on the documented same-step re-run ("does not lie on that grid", #574's resume
-- check floors the recorded lo and gets another value), and regrain_step of a frozen BC monolith to a
-- yearly target mints an inverted copy child [100 BC Jun, 100 BC Jan) and never progresses. The fix
-- counts years astronomically (year N BC is 1 - N).
--
-- Every BC claim is paired with an AD control through the same code (the branch works away from the era,
-- the injected failure leaves the AD table resumable and it resumes), and the regrain fixture is
-- asymmetric (two rows in the first yearly cell, one in the next) and asserted by identity.
-- bench/grid_floor_across_era.sh runs this file against the mutant grid_floor_calendar_no_year_zero (the
-- pre-fix count), so it is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
set datestyle = 'ISO, MDY';
select plan(18);

-- ============================ the function, from the default 2000 anchor ============================
select is(pgpm._grid_floor('time', '1 mon', '2000-01-01 00:00:00+00', '0100-06-15 00:00:00+00 BC', 'UTC')::timestamptz,
  timestamptz '0100-06-01 00:00:00+00 BC',
  'the monthly floor of 100 BC June 15 is 100 BC June 1');
select is(pgpm._grid_floor('time', '1 year', '2000-01-01 00:00:00+00', '0100-06-01 00:00:00+00 BC', 'UTC')::timestamptz,
  timestamptz '0100-01-01 00:00:00+00 BC',
  'the yearly floor of 100 BC June 1 is 100 BC January 1');
select is(pgpm._grid_floor('time', '1 mon', '2000-01-01 00:00:00+00', '0001-06-15 00:00:00+00 BC', 'UTC')::timestamptz,
  timestamptz '0001-06-01 00:00:00+00 BC',
  'the monthly floor of 1 BC June 15 (the year next to the era) is 1 BC June 1');
select is(pgpm._grid_floor('time', '1 year', '2000-01-01 00:00:00+00', '1990-06-01 00:00:00+00', 'UTC')::timestamptz,
  timestamptz '1990-01-01 00:00:00+00',
  'LIVENESS: the same call floors an AD value to its own year (the branch works away from the era)');

-- every month start from 3 BC to 3 AD, for three calendar steps: a grid point floors to itself, a value
-- inside its cell floors to it, and the cell's next boundary lies past the value
create temp table m233 as
  select m, s
    from generate_series(timestamptz '0003-01-01 00:00:00+00 BC', timestamptz '0003-12-01 00:00:00+00', interval '1 month') m,
         unnest(array['1 mon', '3 mons', '1 year']) s;
select is((select count(*) from m233 where s = '1 mon' and extract(year from m) < 0)::int, 36,
  'LIVENESS: the sweep holds 36 BC month starts per step (3, 2 and 1 BC)');
select is((select count(*) from m233 where s = '1 mon' and extract(year from m) > 0)::int, 36,
  'LIVENESS: and 36 AD ones (1, 2 and 3 AD)');
select is(
  (select array_agg(s || ' ' || pgpm._ts_text(m) order by s, m) from m233
    where pgpm._grid_floor('time', s, '2000-01-01 00:00:00+00', pgpm._ts_text(m), 'UTC')::timestamptz
          <> case when s = '1 mon' then m
                  when s = '3 mons' then date_trunc('quarter', m)
                  else date_trunc('year', m) end),
  null,
  'every month start from 3 BC to 3 AD floors to its month, quarter or year (no BC value floors a year early)');
select is(
  (select array_agg(s || ' ' || pgpm._ts_text(m) order by s, m) from m233,
          lateral (select pgpm._grid_floor('time', s, '2000-01-01 00:00:00+00', pgpm._ts_text(m + interval '14 days 5 hours'), 'UTC') f) x
    where not (x.f::timestamptz <= m + interval '14 days 5 hours'
               and pgpm._grid_next('time', s, x.f, 'UTC')::timestamptz > m + interval '14 days 5 hours')),
  null,
  'every mid-month value from 3 BC to 3 AD lies in the cell [floor, next floor) it floors to');

-- ============================ the other direction: a BC anchor, an AD value ============================
select is(pgpm._grid_floor('time', '1 mon', '0050-03-01 00:00:00+00 BC', '2020-05-10 00:00:00+00', 'UTC')::timestamptz,
  timestamptz '2020-05-01 00:00:00+00',
  'from a BC anchor, the monthly floor of 2020-05-10 is 2020-05-01 (never above its input)');
select is(pgpm._grid_floor('time', '1 year', '0050-03-01 00:00:00+00 BC', '2020-05-10 00:00:00+00', 'UTC')::timestamptz,
  timestamptz '2020-03-01 00:00:00+00',
  'from a BC anchor, the yearly floor of 2020-05-10 is 2020-03-01, on the anchor''s March lattice');

-- ============================ an interrupted transmute resumes on the same step ============================
-- phase 2 (VALIDATE) fails after phase 1 has committed the bound and the claim, so each table is left
-- in flight; the documented remedy is the same call again
create function public.f233_fail_validate() returns event_trigger language plpgsql as $$
begin
  if exists (select 1 from pg_constraint where conname = 'pgpm_monolith_bound' and convalidated) then
    raise exception 'f233 injected failure after VALIDATE';
  end if;
end $$;
create table public.ad233 (id bigint not null, at timestamptz not null, primary key (id, at));
insert into public.ad233 values (1, '0001-06-15 00:00:00+00'), (2, '0001-08-15 00:00:00+00'), (3, now() - interval '1 day');
create table public.bc233 (id bigint not null, at timestamptz not null, primary key (id, at));
insert into public.bc233 values (1, '0001-06-15 00:00:00+00 BC'), (2, '0001-08-15 00:00:00+00 BC'), (3, now() - interval '1 day');
create event trigger f233_fail_validate on ddl_command_end when tag in ('ALTER TABLE') execute function public.f233_fail_validate();
\set ON_ERROR_STOP 0
call pgpm.transmute('public.ad233', 'at', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.bc233', 'at', interval '1 month', p_obtain => 1);
\set ON_ERROR_STOP 1
drop event trigger f233_fail_validate;
select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.transmute_inflight
            where parent_table in ('public.ad233'::regclass, 'public.bc233'::regclass)),
  array['ad233', 'bc233'],
  'LIVENESS: both first attempts died between transactions and left their claims');
select is((select lo::timestamptz from pgpm.transmute_inflight where parent_table = 'public.bc233'::regclass),
  timestamptz '0001-06-01 00:00:00+00 BC',
  'the BC table''s recorded lo is the month its oldest row is in (1 BC June)');
\set ON_ERROR_STOP 0
call pgpm.transmute('public.ad233', 'at', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.bc233', 'at', interval '1 month', p_obtain => 1);
\set ON_ERROR_STOP 1
select is((select relkind::text from pg_class where oid = 'public.ad233'::regclass), 'p',
  'LIVENESS: the AD control resumes and converts on the same step and anchor');
select is((select relkind::text from pg_class where oid = 'public.bc233'::regclass), 'p',
  'the BC table resumes and converts on the same step and anchor (its recorded lo floors to itself)');
select is((select array_agg(id order by id) from public.bc233), array[1, 2, 3]::bigint[],
  'bc233 holds rows 1, 2 and 3 after the conversion');

-- ============================ regrain_step of a frozen BC monolith ============================
-- a one-second grid, so the monolith freezes a second after the conversion
create table public.rg233 (id bigint not null, at timestamptz not null, body text, primary key (id, at));
insert into public.rg233 values (1, '0100-06-01 00:00:00+00 BC', 'bc100-june'), (2, '0100-09-01 00:00:00+00 BC', 'bc100-sept'),
                                (3, '0099-03-01 00:00:00+00 BC', 'bc99-march'), (4, now() - interval '1 day', 'recent');
call pgpm.transmute('public.rg233', 'at', interval '1 second', p_obtain => 2);
select pg_sleep(2.5);
select is((select pgpm._grid_floor('time', '1 second', c.partition_anchor, pgpm._ts_text(now()), 'UTC')::timestamptz >= p.hi::timestamptz
             and p.lo::timestamptz = timestamptz '0100-06-01 00:00:00+00 BC'
             from pgpm.config c join pgpm.part p on p.parent_table = c.parent_table
            where c.parent_table = 'public.rg233'::regclass and p.attached and p.lo::timestamptz < '0001-01-01 00:00:00+00'),
  true,
  'LIVENESS: rg233''s monolith starts at its oldest row (100 BC June 1) and is frozen');
create function pg_temp.mono233() returns text language sql as $f$
  select child_name::text from pgpm.part where parent_table = 'public.rg233'::regclass
     and attached and lo::timestamptz < '0001-01-01 00:00:00+00'
$f$;
create function pg_temp.bodies(p_rel regclass) returns text language plpgsql as $f$
declare v text;
begin
  execute format('select array_agg(body order by body)::text from %s', p_rel) into v;
  return v;
end $f$;
create temp table steps233 (g int, st text);
insert into steps233 select 1, pgpm.regrain_step('public.rg233', pg_temp.mono233(), '1 year', null);
insert into steps233 select 2, pgpm.regrain_step('public.rg233', pg_temp.mono233(), '1 year', null);
select is((select array_agg(st order by g) from steps233), array['prepared', 'copied:2'],
  'regrain_step prepares, then copies the first yearly sub-range''s two rows');
select is((select string_agg(c.child_name || ' [' || c.lo || ', ' || c.hi || ') ' || pg_temp.bodies(c.child_oid::regclass), '; ')
             from pgpm.part c where c.parent_table = 'public.rg233'::regclass and not c.attached),
  'rg233_p0100_bc [0100-06-01 00:00:00+00 BC, 0099-01-01 00:00:00+00 BC) {bc100-june,bc100-sept}',
  'the first copy child is [100 BC June, 99 BC January), not inverted, and holds bc100-june and bc100-sept, not bc99-march');

select * from finish();
