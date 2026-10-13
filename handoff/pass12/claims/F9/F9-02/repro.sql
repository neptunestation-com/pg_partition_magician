-- F9-02: obtain leaves a cell unbuilt (its name held by a stranger) and logs nothing: _log_unbuilt_cell is never called
\set ON_ERROR_STOP 1
create extension if not exists pgtap;
create table public.f9o (id bigint primary key, v text);
insert into public.f9o select g, 'x' from generate_series(1, 50) g;
call pgpm.transmute('public.f9o', 'id', 100, p_obtain => 1);
-- a stranger takes the plain name of the cell [200, 300), which the next obtain (lookahead 3) must build
create table public.f9o_p0000000000000000200 (z int);
select pgpm.set_obtain('public.f9o', 3);
select pgpm.obtain('public.f9o') as made \gset

select plan(4);
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.f9o'::regclass and lo = '200'),
          'LIVENESS: the cell [200, 300) was left unbuilt (no pgpm.part row)');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.f9o'::regclass and lo = '300'),
          'LIVENESS: obtain did walk past it and build [300, 400)');
select throws_like($$insert into public.f9o values (250, 'hole')$$, '%no partition%',
          'LIVENESS: a write into [200, 300) is refused (a hole in the grid)');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.f9o'::regclass
                    and action = 'fail_obtain_name' and lo = '200' and hi = '300'),
          'obtain logged fail_obtain_name for the unbuilt cell [200, 300)');
select * from finish();
