-- regrain_history() regrains the oldest COARSE child, one the target subdivides (issue #1244).
--
-- THE GAP. regrain_history took the smallest-lo attached partition, with no "the target subdivides it" test, so
-- after one hierarchical pass (monolith -> 50-wide -> the first 50-wide child -> 10-wide) the next call picked the
-- already-fine [0, 10) and raised 'the target step does not subdivide its range' while the coarse [50, 100) was
-- still there. The guide says it regrains "the oldest coarse child" and recommends it for hierarchical splits.
-- It now asks regrain_step's own 'nosubdiv' test, as maintain's candidate scan does (#515).
--
-- THE CONTRACT.
--   PART A  with a fine child below a coarse one, regrain_history splits the coarse one.
--   PART B  with nothing coarse left, it refuses saying so, rather than naming a fine child it cannot split.
-- bench/regrain_history_coarse_child.sh runs this file against the mutant that drops the subdivision test.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(9);

create table public.t384 (id bigint primary key, body text);
insert into public.t384 select g, 'row ' || g from generate_series(1, 95) g;
call pgpm.transmute('public.t384', 'id', 10::bigint, p_obtain => 3);
insert into public.t384 values (105, 'frontier');           -- the monolith [0, 100) is frozen

-- ==================== (A) a fine child below a coarse one ====================
select is(pgpm.regrain_history('public.t384', '50'), 2, 'LIVENESS: first pass: the monolith split into two 50-wide children');
select is(pgpm.regrain_history('public.t384'), 5, 'LIVENESS: second pass: the oldest 50-wide child split into 10-wide children');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.t384'::regclass and attached and lo = '50' and hi = '100'),
  'LIVENESS: the coarse child [50, 100) is still attached');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.t384'::regclass and attached and lo = '0' and hi = '10'),
  'LIVENESS: the smallest-lo attached child [0, 10) is already at the partition step');

select lives_ok($$ select pgpm.regrain_history('public.t384') $$,
  'regrain_history at the partition step regrains the remaining coarse child, rather than refusing on a fine one');
select is((select array_agg(lo::bigint order by lo::bigint) from pgpm.part
            where parent_table = 'public.t384'::regclass and attached and lo::bigint < 100),
  array[0, 10, 20, 30, 40, 50, 60, 70, 80, 90]::bigint[],
  'the old monolith range is now exactly ten 10-wide children');
select is((select array_agg(id order by id) from public.t384 where id in (1, 49, 50, 95, 105)), array[1, 49, 50, 95, 105]::bigint[],
  'rows on both sides of the old 50-wide boundary are still there');
select is((select count(*)::int from public.t384), 96, 'and none was lost or doubled');

-- ==================== (B) nothing coarse left ====================
select throws_like($$ select pgpm.regrain_history('public.t384') $$,
  '%t384 has no partition the target step 10 subdivides%',
  'with every partition at the target grain it refuses saying nothing is coarser, naming no fine child');

select * from finish();
