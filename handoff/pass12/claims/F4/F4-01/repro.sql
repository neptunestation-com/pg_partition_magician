-- F4-01: obtain() and extend_to() leave a cell whose name a stranger holds unbuilt and log NOTHING.
-- docs/reference.md (pgpm.log actions table, "fail_obtain_name") and _log_unbuilt_cell's own header promise
-- that "obtain or extend_to left the cell [lo, hi) unbuilt because its name is held by ..." is logged as
-- fail_obtain_name. Both callers' "a hole in the grid, so it is logged (#710)" branch is `null;`, and
-- pgpm._log_unbuilt_cell has no caller at all.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

create table public.f4o (id bigint primary key, payload text);
insert into public.f4o values (150, 'a'), (160, 'b');
call pgpm.transmute('public.f4o', 'id', 100::bigint, p_obtain => 1, p_paused => false);

-- a stranger takes the name of the cell [300, 400), which obtain has not built yet
select pgpm._part_name('f4o', 'id', '100', '300', '400', 'UTC') as squat \gset
create table public.:"squat" (x int);
-- and of [700, 800), past obtain's lookahead (its last cell is [500, 600)), for extend_to
select pgpm._part_name('f4o', 'id', '100', '700', '800', 'UTC') as squat2 \gset
create table public.:"squat2" (x int);

select ok(not exists (select 1 from pgpm.part where parent_table = 'public.f4o'::regclass and lo = '300'),
  'LIVENESS: [300, 400) is not built yet');

select pgpm.set_obtain('public.f4o', 4);
select ok(pgpm.obtain('public.f4o') >= 1, 'LIVENESS: obtain built the cells it could name');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.f4o'::regclass and lo = '300')
          and exists (select 1 from pgpm.part where parent_table = 'public.f4o'::regclass and lo = '400'),
  'LIVENESS: obtain walked past [300, 400), left it unbuilt, and built [400, 500) above it');
select throws_like($$ insert into public.f4o values (350, 'hole') $$, '%no partition of relation%',
  'LIVENESS: a write into [300, 400) is refused: the cell is a hole');

select is(
  (select array_agg(lo || '-' || hi order by id) from pgpm.log
    where parent_table = 'public.f4o'::regclass and action = 'fail_obtain_name' and lo = '300'),
  array['300-400'],
  'obtain logged fail_obtain_name for the hole [300, 400), as docs/reference.md promises');

select pgpm.extend_to('public.f4o', '750') as made \gset
select ok(:made >= 1
          and not exists (select 1 from pgpm.part where parent_table = 'public.f4o'::regclass and lo = '700')
          and exists (select 1 from pgpm.part where parent_table = 'public.f4o'::regclass and lo = '600'),
  'LIVENESS: extend_to walked past [700, 800), left it unbuilt, and built [600, 700) below it');
select is(
  (select array_agg(lo || '-' || hi order by id) from pgpm.log
    where parent_table = 'public.f4o'::regclass and action = 'fail_obtain_name' and lo = '700'),
  array['700-800'],
  'extend_to logged fail_obtain_name for the hole [700, 800) it walked over');

select * from finish();
