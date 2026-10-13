-- The regrain lock budget's prepare-tick count (_regrain_fine_count) leaves the aged prefix out whenever retain
-- is set, but regrain_step's copy skips that prefix only when NO archive_fn is set (#278). With an archive_fn,
-- every aged sub-range is copied and attached at the swap, so a run past the line is prepared, copied whole,
-- and only then refused by the swap's measured budget: the exact "copy everything, then refuse" #1161 closed.
-- Contract (tests/315 header, _regrain_swap_budget): such a run is refused at its prepare tick, before
-- anything is copied.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(5);

select (current_setting('max_locks_per_transaction')::bigint
        * (current_setting('max_connections')::bigint + current_setting('max_prepared_transactions')::bigint)) / 4 as cap \gset
select (:cap / 2 + 1) * 100 as p_step \gset

-- tests/315 part C's fixture, plus an archive_fn: monolith [0, 4P), retain P, frontier 4P + 1 (horizon 3P)
create table public.f10a (id bigint primary key, a text);
insert into public.f10a values (0, 'first'), (4 * :p_step - 1, 'last');
call pgpm.transmute('public.f10a', 'id', (:p_step)::bigint, p_obtain => 2, p_retain => (:p_step)::bigint);
insert into public.f10a values (4 * :p_step + 1, 'frontier');
create function public.f10_strat(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; begin v.covered_hi := p_hi; v.rows_archived := 0; v.s3_key := 'k'; return v; end $$;
select pgpm.set_archive_fn('public.f10a', 'public.f10_strat(regclass,name,text,text)'::regprocedure);

select child_name as src from pgpm.part where parent_table = 'public.f10a'::regclass and attached and lo = '0' \gset
select is((select hi from pgpm.part where parent_table = 'public.f10a'::regclass and child_name = :'src'),
          (4 * :p_step)::text, 'LIVENESS: the source is [0, 4P): 2 cap + 4 sub-ranges of 100, past the line');
select isnt((select archive_fn from pgpm.config where parent_table = 'public.f10a'::regclass), null,
          'LIVENESS: an archive_fn is set, so the copy does not skip the aged prefix (#278)');
select is(pgpm._retain_boundary(c), (3 * :p_step)::text, 'LIVENESS: the retention horizon is 3P')
  from pgpm.config c where parent_table = 'public.f10a'::regclass;

-- the prepare tick: must refuse, since every one of the 2 cap + 4 sub-ranges will be copied and attached
create function pg_temp.f10_try(p_src name) returns text language plpgsql as $$
begin
  return 'returned ' || pgpm.regrain_step('public.f10a', p_src, '100');
exception when others then return 'raised: ' || sqlerrm;
end $$;
select pg_temp.f10_try(:'src') as res \gset
select ok(:'res' like 'raised: %cannot regrain%lock table%',
          'the prepare tick refuses a run whose swap attaches 2 cap + 4 children: ' || left(:'res', 120));

-- and the first copy tick shows the aged prefix is really copied (not skipped) under this config
select pg_temp.f10_try(:'src') as res2 \gset
select is((select count(*)::int from pgpm.log where parent_table = 'public.f10a'::regclass and action = 'regrain_aged'), 0,
          'LIVENESS: no sub-range was skipped as aged: with archive_fn set the aged prefix is copied, so the swap attaches it');
select * from finish();
