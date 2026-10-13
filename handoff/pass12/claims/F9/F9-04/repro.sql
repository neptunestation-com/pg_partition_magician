-- F9-04: the regrain lock budget's prepare refusal (_regrain_fine_count) discounts the aged prefix even with an
-- archive_fn set, where regrain_step copies (and the swap attaches) every aged sub-range: a run far past half the
-- shared lock table is prepared and copied instead of refused before anything is copied.
\set ON_ERROR_STOP 1
create extension if not exists pgtap;
create table public.f9g (id bigint primary key, v text);
insert into public.f9g select g, 'x' from generate_series(1, 4000) g;
call pgpm.transmute('public.f9g', 'id', 100, p_obtain => 2);       -- monolith [0, 4100)
select pgpm.extend_to('public.f9g', '9000');
insert into public.f9g values (9000, 'frontier');                   -- frontier 9000: the monolith is frozen
select child_name as mono from pgpm.part where parent_table = 'public.f9g'::regclass and lo = '0' \gset

select plan(7);
select ok(current_setting('max_locks_per_transaction')::bigint
          * (current_setting('max_connections')::bigint + current_setting('max_prepared_transactions')::bigint) / 4 < 4100,
          'GUARD: the monolith''s 4100 one-step fine children are past a quarter of the lock table (two slots a child > half)');
-- the whole run (no retention): refused at its prepare tick, so the budget line is reached by 4100 children
select throws_like(format($$select pgpm.regrain_step('public.f9g', %L, '1')$$, :'mono'),
                   '%would attach at least%fine partitions%',
                   'LIVENESS: with no retention the 4100-child run is refused at its prepare tick');
-- retention puts [0, 3000) below the horizon (frontier 9000 - 6000): without an archive strategy the copy skips it
select pgpm.set_retain('public.f9g', '6000');
select is(pgpm._retain_boundary(c), '3000', 'LIVENESS: the retention horizon is 3000') from pgpm.config c
 where c.parent_table = 'public.f9g'::regclass;
-- with an archive strategy the aged sub-ranges are NOT skipped (#278): every one of the 4100 is copied and attached
select pgpm.set_archive_fn('public.f9g', 'pgpm._archive_noop(regclass, name, text, text)'::regprocedure);
create temp table f9_prep (status text, err text);
do $$
begin
  insert into f9_prep select pgpm.regrain_step('public.f9g', (select child_name from pgpm.part
                              where parent_table = 'public.f9g'::regclass and lo = '0'), '1'), null;
exception when others then
  insert into f9_prep values (null, sqlerrm);
end $$;
select ok((select coalesce(err like '%would attach at least%', false) from f9_prep),
          'the prepare tick refuses the run whose swap would attach all 4100 children (the aged ones included, since an archive_fn is set)');
-- the premise, on a small twin (500 children, inside the budget): with retention AND an archive strategy the
-- first copy is the AGED sub-range [0, 1), materialized for the archive pipeline rather than skipped
create table public.f9h (id bigint primary key, v text);
insert into public.f9h select g, 'x' from generate_series(1, 400) g;
call pgpm.transmute('public.f9h', 'id', 100, p_obtain => 2);       -- monolith [0, 500)
select pgpm.extend_to('public.f9h', '900');
insert into public.f9h values (900, 'frontier');
select pgpm.set_retain('public.f9h', '600');                        -- horizon 300: [0, 300) aged
select pgpm.set_archive_fn('public.f9h', 'pgpm._archive_noop(regclass, name, text, text)'::regprocedure);
select child_name as twin from pgpm.part where parent_table = 'public.f9h'::regclass and lo = '0' \gset
select is(pgpm.regrain_step('public.f9h', :'twin', '1'), 'prepared', 'LIVENESS: the twin''s run is prepared');
select is(pgpm.regrain_step('public.f9h', :'twin', '1'), 'copied:0',
          'LIVENESS: with an archive_fn set the next tick copies the aged sub-range [0, 1) instead of skipping it');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.f9h'::regclass and not attached and lo = '0' and hi = '1'),
          'LIVENESS: a fine child for the aged sub-range [0, 1) exists, to be attached at the swap');
select * from finish();
