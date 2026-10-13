-- F17-03: obtain leaves a forward cell whose name a stranger holds unbuilt, and docs/reference.md (obtain,
-- Partition naming, the fail_obtain_name row of pgpm.log's vocabulary) and docs/runbook.md promise it logs
-- fail_obtain_name for the cell's range, naming what holds the name. obtain's call of _log_unbuilt_cell is
-- gone (`if v_name is null then null; end if;`), so the hole is silent.
\pset tuples_only on
\pset format unaligned
create extension if not exists pgtap;
begin;
select plan(4);
create table public.t (id bigint primary key, v text not null);
insert into public.t select g, 'm' || g from generate_series(1, 50) g;
commit;
call pgpm.transmute('public.t', 'id', 100::bigint, p_obtain => 1);
begin;
create table public.t_p0000000000000000300 (x int);   -- a stranger at the name of the cell [300, 400)
select pgpm.set_obtain('public.t', 4);
select pgpm.obtain('public.t');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.t'::regclass and lo = '300'),
          'LIVENESS: obtain left the cell [300, 400) unbuilt, its name held by a stranger');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.t'::regclass and lo = '400' and attached)
          and exists (select 1 from pgpm.part where parent_table = 'public.t'::regclass and lo = '200' and attached),
          'LIVENESS: obtain built the cells on both sides of it, [200, 300) and [400, 500)');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.t'::regclass and action = 'fail_obtain_name'
                     and lo = '300' and hi = '400'),
          'obtain logged fail_obtain_name for the unbuilt cell [300, 400)');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.t'::regclass and action = 'fail_obtain_name'
                     and lo = '300' and method like '%t_p0000000000000000300%'),
          'the fail_obtain_name row names the relation that holds the name');
select * from finish();
rollback;
