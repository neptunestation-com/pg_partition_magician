-- A time-kind transmute accounts for the column's data maximum before anything is committed (issue #668).
--
-- For control_kind 'time' the monolith's hi was the grid boundary above now(), never above max(control),
-- and nothing compared the two. A table holding one future-dated row (a scheduled event, a client with a
-- wrong clock) therefore committed a write-rejecting pgpm_monolith_bound CHECK and the claim in phase 1,
-- and only phase 2's VALIDATE found the row, with a raw 23514; the table then rejected every write
-- outside [lo, hi) until an abort. The uuidv7/text_time kinds already took the newer of the maximum and
-- the clock as the frontier and refused a maximum more than one step plus one hour ahead (#457); the time
-- kind now does the same.
--
-- Fixtures, asymmetric on purpose, one per branch:
--   (A) far: a row 400 days out on a monthly grid, refused up front, nothing committed;
--   (B) near: a row in the NEXT daily cell, inside the allowance, converted with hi raised to cover it;
--   (C) near, on a naive date column (read as wall time in UTC, #504): same as B;
--   (D) forced: A's shape with p_force_frontier => true, converted with hi past the row;
--   (E) infinity: refused even with p_force_frontier, since no bound can cover it;
--   (F) control: every row in the past, converted with hi exactly the clock's boundary (the fix does not
--       raise hi where no row asks it to).
-- Each refusal is pinned by its message (throws_like): a committing procedure that does NOT refuse dies
-- at its first COMMIT inside pgTAP with 2D000, which an unpinned assertion would accept. Each is paired
-- with the state a refusal must leave (no bound, no claim, still a plain table, its rows intact) and with
-- a witness that the fixture really holds a row past the clock's boundary. bench/transmute_future_maximum.sh
-- runs this file against a mutant that puts the now()-only frontier back (transmute_time_frontier_clock_only),
-- so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(28);

set timezone = 'UTC';

-- (A) far
create table public.fa (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.fa values (1, now() - interval '3 days'), (2, now() - interval '1 day'), (3, now() + interval '400 days');
select ok((select max(ts) from public.fa) > date_trunc('month', now()) + interval '2 months',
  'A LIVENESS: fa holds a row past the monthly boundary the clock alone gives');
select throws_like($$ call pgpm.transmute('public.fa', 'ts', interval '1 month', p_obtain => 2) $$,
  '%fa cannot be partitioned on a time grid using ts: its newest value is % ahead of now()%p_force_frontier => true%',
  'A: a maximum 400 days out on a monthly grid is refused before anything is committed');
select is((select relkind::text from pg_class where oid = 'public.fa'::regclass), 'r', 'A: fa is still a plain table');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.fa'::regclass and conname = 'pgpm_monolith_bound'),
  'A: no pgpm_monolith_bound was left on fa');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.fa'::regclass),
  'A: no claim was left for fa');
select is((select array_agg(id order by id) from public.fa), array[1, 2, 3]::bigint[], 'A: fa still holds rows 1, 2 and 3');
select lives_ok($$ insert into public.fa values (4, now() + interval '500 days') $$,
  'A: fa still takes a write outside any bound it would have had');

-- (B) near, timestamptz, daily grid: a row 30 minutes into tomorrow's cell
create table public.nb (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.nb values (1, now() - interval '2 days'), (2, now() - interval '5 hours'),
                             (3, date_trunc('day', now()) + interval '1 day 30 minutes');
select oid as nb_oid from pg_class where oid = 'public.nb'::regclass \gset
select ok((select max(ts) from public.nb) >= date_trunc('day', now()) + interval '1 day',
  'B LIVENESS: nb holds a row past the daily boundary the clock alone gives');
call pgpm.transmute('public.nb', 'ts', interval '1 day', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.nb'::regclass), 'p', 'B: nb converted');
select is((select hi::timestamptz from pgpm.part where parent_table = 'public.nb'::regclass and child_oid = :nb_oid),
  date_trunc('day', now()) + interval '2 days',
  'B: the monolith''s hi is the boundary above the future row, not the one above now()');
select is((select array_agg(id order by id) from public.nb where tableoid = :nb_oid), array[1, 2, 3]::bigint[],
  'B: rows 1, 2 and 3 are in the monolith, the future one included');
select ok(not exists (select 1 from pg_constraint where conname = 'pgpm_monolith_bound'
                       and conrelid in ('public.nb'::regclass, :nb_oid::oid::regclass)),
  'B: no pgpm_monolith_bound is left on the parent or the monolith');

-- (C) near, naive date column, daily grid: a row dated tomorrow
create table public.nc (id bigint, d date not null, primary key (id, d));
insert into public.nc values (1, current_date - 4), (2, current_date + 1);
select oid as nc_oid from pg_class where oid = 'public.nc'::regclass \gset
call pgpm.transmute('public.nc', 'd', interval '1 day', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.nc'::regclass), 'p', 'C: nc converted');
select is((select hi::timestamptz from pgpm.part where parent_table = 'public.nc'::regclass and child_oid = :nc_oid),
  (current_date + 2)::timestamp at time zone 'UTC',
  'C: the date column''s monolith hi is the day after its newest date, read as a UTC wall date');
select is((select array_agg(id order by id) from public.nc where tableoid = :nc_oid), array[1, 2]::bigint[],
  'C: rows 1 and 2 are in the monolith');

-- (D) forced
create table public.fd (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.fd values (1, now() - interval '10 days'), (2, now() + interval '400 days');
select oid as fd_oid from pg_class where oid = 'public.fd'::regclass \gset
call pgpm.transmute('public.fd', 'ts', interval '1 month', p_obtain => 2, p_force_frontier => true);
select is((select relkind::text from pg_class where oid = 'public.fd'::regclass), 'p', 'D: fd converted under p_force_frontier');
select is((select hi::timestamptz from pgpm.part where parent_table = 'public.fd'::regclass and child_oid = :fd_oid),
  date_trunc('month', (select max(ts) from public.fd)) + interval '1 month',
  'D: the monolith''s hi is the month boundary above the forced maximum');
select is((select array_agg(id order by id) from public.fd where tableoid = :fd_oid), array[1, 2]::bigint[],
  'D: rows 1 and 2 are in the monolith');

-- (E) infinity
create table public.fe (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.fe values (1, now() - interval '2 days'), (2, 'infinity');
select throws_like($$ call pgpm.transmute('public.fe', 'ts', interval '1 month', p_obtain => 2) $$,
  '%fe cannot be partitioned on a time grid using ts: its newest value is infinity%',
  'E: an infinite maximum is refused');
select throws_like($$ call pgpm.transmute('public.fe', 'ts', interval '1 month', p_obtain => 2, p_force_frontier => true) $$,
  '%fe cannot be partitioned on a time grid using ts: its newest value is infinity%',
  'E: and p_force_frontier does not override that refusal');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.fe'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.fe'::regclass),
  'E: no bound and no claim were left on fe');
select is((select array_agg(id order by id) from public.fe), array[1, 2]::bigint[], 'E: fe still holds rows 1 and 2');

-- (F) control: nothing in the future
create table public.ff (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.ff values (1, now() - interval '40 days'), (2, now() - interval '1 hour');
select oid as ff_oid from pg_class where oid = 'public.ff'::regclass \gset
call pgpm.transmute('public.ff', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.ff'::regclass), 'p', 'F: ff converted');
select is((select hi::timestamptz from pgpm.part where parent_table = 'public.ff'::regclass and child_oid = :ff_oid),
  date_trunc('month', now()) + interval '1 month',
  'F: with every row in the past the monolith''s hi is the boundary above now(), as before');
select is((select lo::timestamptz from pgpm.part where parent_table = 'public.ff'::regclass and child_oid = :ff_oid),
  date_trunc('month', now() - interval '40 days'),
  'F: and its lo is the floor of the oldest row');
select is((select array_agg(id order by id) from public.ff where tableoid = :ff_oid), array[1, 2]::bigint[],
  'F: rows 1 and 2 are in the monolith');
select is((select count(*)::int from pgpm.log where parent_table in ('public.nb'::regclass, 'public.nc'::regclass,
                                                                   'public.fd'::regclass, 'public.ff'::regclass)
                                               and action = 'transmute'), 4,
  'B, C, D, F: each conversion logged its own transmute');
select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.config
            where parent_table::text in ('fa', 'nb', 'nc', 'fd', 'fe', 'ff')),
  array['fd', 'ff', 'nb', 'nc'],
  'exactly the converted four are registered, and neither refused table is');

select * from finish();
