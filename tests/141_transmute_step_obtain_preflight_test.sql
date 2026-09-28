-- transmute refuses a non-positive step, a sub-day step on a date column and a negative or null p_obtain
-- before anything is committed (issue #581).
--
-- None of the three was checked. A negative step made _grid_floor/_grid_next yield lo > hi, so phase 1
-- committed an unsatisfiable NOT VALID pgpm_monolith_bound CHECK, phase 2's VALIDATE failed, and the live
-- table rejected every INSERT until transmute_abort (a corrected re-run resumed the same recorded bound and
-- failed again). A sub-day step on a date column had its hourly bounds truncated to dates: phase 2 validated
-- a CHECK of dt < current_date and phase 3 died on an empty-range hourly cell, leaving the table rejecting
-- every row dated today. And p_obtain => -1, the value set_obtain refuses as a silent no-op, registered a
-- grid obtain never extends: the conversion completed with no forward partition, and the first write past
-- the monolith's hi failed with "no partition of relation ... found for row".
--
-- Each refusal is pinned by its message (throws_like: a committing procedure that does NOT refuse dies at
-- its first COMMIT inside pgTAP with 2D000 and rolls back, which an unpinned assertion would accept), and
-- paired with the state a refusal must leave: no bound, no claim, no registration, the table still plain
-- and still taking writes. The liveness half converts each table with the corrected argument, so the
-- fixtures are proven convertible. bench/transmute_step_preflight.sh runs this file against a mutant with
-- the three refusals removed (transmute_no_step_obtain_preflight), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(24);

set timezone = 'UTC';
create table public.ts_ev (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into public.ts_ev (ts) values (now() - interval '3 hours'), (now() - interval '1 hour');
create table public.dt_ev (id bigint generated always as identity, dt date not null, primary key (id, dt));
insert into public.dt_ev (dt) values (current_date - 3), (current_date - 1);
create table public.id_ev (id bigint primary key, body text);
insert into public.id_ev select g, 'row ' || g from generate_series(1, 15) g;   -- step 10 -> monolith [0, 20)

-- a step that is not positive, for the time and the id grid
select throws_like($$ call pgpm.transmute('public.ts_ev', 'ts', interval '-1 day', p_obtain => 4) $$,
  '%partition step must be positive (got -1 days)%', 'a negative interval step is refused');
select throws_like($$ call pgpm.transmute('public.ts_ev', 'ts', interval '0') $$,
  '%partition step must be positive (got 00:00:00)%', 'a zero interval step is refused');
select throws_like($$ call pgpm.transmute('public.ts_ev', 'ts', interval '-1 month') $$,
  '%partition step must be positive (got -1 mons)%', 'a negative calendar step is refused');
select throws_like($$ call pgpm.transmute('public.id_ev', 'id', -10::bigint) $$,
  '%partition step must be positive (got -10)%', 'a negative id step is refused');
select throws_like($$ call pgpm.transmute('public.id_ev', 'id', 0::bigint) $$,
  '%partition step must be positive (got 0)%', 'a zero id step is refused');

-- a step finer than a day, or not a whole number of days, on a date column
select throws_like($$ call pgpm.transmute('public.dt_ev', 'dt', interval '1 hour', p_obtain => 3) $$,
  '%date column dt holds whole days, so its partition step must be a whole number of days or months (got 01:00:00)%',
  'a sub-day step on a date column is refused');
select throws_like($$ call pgpm.transmute('public.dt_ev', 'dt', interval '1 day 6 hours') $$,
  '%date column dt holds whole days%(got 1 day 06:00:00)%', 'and so is a step that is not a whole number of days');

-- a lookahead obtain would never act on
select throws_like($$ call pgpm.transmute('public.id_ev', 'id', 10::bigint, p_obtain => -1) $$,
  '%p_obtain must be a non-negative integer (got -1)%', 'a negative p_obtain is refused, as set_obtain refuses it');
select throws_like($$ call pgpm.transmute('public.ts_ev', 'ts', interval '1 day', p_obtain => null) $$,
  '%p_obtain must be a non-negative integer (got <NULL>)%', 'and so is a null one');

-- what the refusals left: nothing
select is((select count(*)::int from pg_constraint where conname = 'pgpm_monolith_bound'
            and conrelid in ('public.ts_ev'::regclass, 'public.dt_ev'::regclass, 'public.id_ev'::regclass)), 0,
  'no refused call left a pgpm_monolith_bound CHECK');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table in ('public.ts_ev'::regclass, 'public.dt_ev'::regclass, 'public.id_ev'::regclass)), 0, 'nor a claim');
select is((select count(*)::int from pgpm.config where parent_table in ('public.ts_ev'::regclass, 'public.dt_ev'::regclass, 'public.id_ev'::regclass)), 0, 'nor a registration');
select is((select string_agg(relname || ' ' || relkind::text, ',' order by relname) from pg_class
            where oid in ('public.ts_ev'::regclass, 'public.dt_ev'::regclass, 'public.id_ev'::regclass)),
  'dt_ev r,id_ev r,ts_ev r', 'every table is still a plain table');
insert into public.ts_ev (ts) values (now());
insert into public.dt_ev (dt) values (current_date);
insert into public.id_ev values (16, 'sixteen');
select is((select count(*)::int from public.ts_ev where ts > now() - interval '1 minute'), 1, 'ts_ev takes a write of now()');
select is((select count(*)::int from public.dt_ev where dt = current_date), 1, 'dt_ev takes a row dated today');
select is((select body from public.id_ev where id = 16), 'sixteen', 'id_ev takes a new id');

-- LIVENESS: each table converts with the corrected argument, and its grid extends past the monolith
call pgpm.transmute('public.ts_ev', 'ts', interval '1 day', p_obtain => 2);
call pgpm.transmute('public.dt_ev', 'dt', interval '1 day', p_obtain => 2);
call pgpm.transmute('public.id_ev', 'id', 10::bigint, p_obtain => 3);
select is((select string_agg(relname || ' ' || relkind::text, ',' order by relname) from pg_class
            where relname in ('ts_ev', 'dt_ev', 'id_ev') and relnamespace = 'public'::regnamespace),
  'dt_ev p,id_ev p,ts_ev p', 'LIVENESS: all three tables convert with a positive step, whole days and p_obtain >= 0');
select is((select obtain from pgpm.config where parent_table = 'public.id_ev'::regclass), 3, 'id_ev registered obtain 3');
select is((select string_agg('[' || lo || ',' || hi || ')', ' ' order by lo::numeric) from pgpm.part
            where parent_table = 'public.id_ev'::regclass and attached),
  '[0,20) [20,30) [30,40) [40,50)', 'id_ev''s forward grid starts at the monolith''s hi');
insert into public.id_ev values (20, 'next id');
select is((select c.relname::text from public.id_ev e join pg_class c on c.oid = e.tableoid where e.id = 20),
  'id_ev_p0000000000000000020', 'id 20, just past the monolith, lands in the partition starting there');
insert into public.dt_ev (dt) values (current_date + 1);
select is((select c.relname::text from public.dt_ev e join pg_class c on c.oid = e.tableoid where e.dt = current_date + 1),
  'dt_ev_p' || to_char(current_date + 1, 'YYYY_MM_DD'), 'a row dated tomorrow lands in tomorrow''s daily partition of dt_ev');
select is((select string_agg(dt::text, ',' order by dt) from public.dt_ev),
  (select string_agg(d::text, ',' order by d) from unnest(array[current_date - 3, current_date - 1, current_date, current_date + 1]) d),
  'dt_ev holds exactly its four rows');
insert into public.ts_ev (ts) values (now() + interval '1 day');
select is((select count(*)::int from public.ts_ev), 4, 'ts_ev takes a write a day out, past its monolith');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table in ('public.ts_ev'::regclass, 'public.dt_ev'::regclass, 'public.id_ev'::regclass)), 0, 'LIVENESS: every conversion completed and released its claim');

select * from finish();
