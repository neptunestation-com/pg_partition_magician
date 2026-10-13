-- F3-01: the prepare tick's lock budget (#1161) leaves the aged prefix out of its count even when archive_fn
-- is set, although with archive_fn set regrain_step materializes every aged sub-range and the swap attaches it.
-- docs/reference.md (regrain_step): "With archive_fn unset it counts only the sub-ranges above the retention
-- horizon, since the aged ones are discarded with the source rather than attached." _regrain_fine_count never
-- reads cfg.archive_fn, so a table that archives is admitted at its prepare tick and copies every row before
-- its swap tick refuses (or exhausts the lock table): the exact outcome the prepare refusal exists to prevent.
--
-- Fixture: four id tables, each a monolith [0, 2500) regrained toward step 1 (2500 fine children; the stock
-- lock table, 64 x (100 + 0) = 6400 slots, admits 1600). A frontier row at 50000 with retain 10000 puts the
-- retention horizon at 40000, so the whole monolith is below it.
create extension if not exists pgtap;
select plan(9);

create or replace function pg_temp.mk(p_name text)
returns void language plpgsql as $$ begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_name);
  execute format('insert into public.%I select g, ''x'' from generate_series(1, 2400) g', p_name);
end $$;

select pg_temp.mk('f301a');
select pg_temp.mk('f301b');
select pg_temp.mk('f301c');
select pg_temp.mk('f301d');
call pgpm.transmute('public.f301a', 'id', 2500);
call pgpm.transmute('public.f301b', 'id', 2500, p_retain => 10000);
call pgpm.transmute('public.f301c', 'id', 2500, p_retain => 10000);
call pgpm.transmute('public.f301d', 'id', 2500, p_retain => 10000);
select pgpm.obtain('public.f301a');
select pgpm.obtain('public.f301b');
select pgpm.obtain('public.f301c');
select pgpm.obtain('public.f301d');
insert into public.f301a values (50000, 'frontier');
insert into public.f301b values (50000, 'frontier');
insert into public.f301c values (50000, 'frontier');
insert into public.f301d values (50000, 'frontier');
select pgpm.set_archive_fn('public.f301c', 'pgpm._archive_noop(regclass, name, text, text)'::regprocedure);
select pgpm.set_archive_fn('public.f301d', 'pgpm._archive_noop(regclass, name, text, text)'::regprocedure);

select child_name as mono from pgpm.part where parent_table = 'public.f301c'::regclass and attached
 order by lo::numeric limit 1 \gset

select is((select lo || '..' || hi from pgpm.part where parent_table = 'public.f301c'::regclass and child_name = :'mono'),
  '0..2500', 'GUARD: the monolith is [0, 2500), 2500 sub-ranges of step 1');
select is((select pgpm._retain_boundary(c) from pgpm.config c where c.parent_table = 'public.f301c'::regclass),
  '40000', 'GUARD: the retention horizon is 40000, so every sub-range of the monolith is below it');

-- LIVENESS (A): 2500 fine children are over the budget: with no retention the prepare tick refuses the run.
select throws_like(
  format($$ select pgpm.regrain_step('public.f301a', %L, '1') $$,
         (select child_name from pgpm.part where parent_table = 'public.f301a'::regclass and attached order by lo::numeric limit 1)),
  '%cannot regrain%its swap would attach at least%',
  'LIVENESS: (A) a 2500-child run of this monolith is refused by the prepare tick when nothing is aged');

-- LIVENESS (B): with archive_fn unset the aged prefix is rightly left out (it is skipped, never attached)
select is(pgpm.regrain_step('public.f301b',
            (select child_name from pgpm.part where parent_table = 'public.f301b'::regclass and attached order by lo::numeric limit 1), '1'),
  'prepared', 'LIVENESS: (B) with archive_fn unset the same run over an aged monolith is admitted');

-- LIVENESS (C): with archive_fn set an aged sub-range is MATERIALIZED, not skipped (#278), so the swap attaches
-- every one of the 2500. Shown on f301d at a step the budget admits (25 children of 100): the first tick after
-- prepare copies [0, 100), which lies wholly below the horizon, and logs no regrain_aged.
select is(pgpm.regrain_step('public.f301d',
            (select child_name from pgpm.part where parent_table = 'public.f301d'::regclass and attached order by lo::numeric limit 1), '100'),
  'prepared', 'LIVENESS: (C) f301d prepares toward 100');
select is(pgpm.regrain_step('public.f301d',
            (select child_name from pgpm.part where parent_table = 'public.f301d'::regclass and attached order by lo::numeric limit 1), '100'),
  'copied:99', 'LIVENESS: (C) its next tick copies the aged sub-range [0, 100) (ids 1..99) rather than skipping it');
select is((select array_agg(action || ' ' || lo || '..' || hi) from pgpm.log
            where parent_table = 'public.f301d'::regclass and action in ('regrain_copy', 'regrain_aged')),
  array['regrain_copy 0..100'], 'LIVENESS: (C) logged as regrain_copy of [0, 100), with no regrain_aged');

-- THE DEFECT: f301c archives, so its swap would attach all 2500 children; the prepare tick must refuse it as it
-- refuses f301a. It admits it instead.
select throws_like(
  format($$ select pgpm.regrain_step('public.f301c', %L, '1') $$, :'mono'),
  '%cannot regrain%its swap would attach at least%',
  'the prepare tick refuses a 2500-child run of a table with archive_fn set, whose aged sub-ranges are all attached');
select is((select count(*)::int from pgpm.log where parent_table = 'public.f301c'::regclass and action = 'regrain_prepare'),
  0, 'no regrain_prepare was logged for that over-budget run');

select * from finish();
