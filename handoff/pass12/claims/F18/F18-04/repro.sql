-- F18-04: obtain leaves a forward cell unbuilt when a relation of the operator's holds its name, and logs
-- nothing: _log_unbuilt_cell (install.sql ~2129) has no call site; obtain's branch under "a hole in the
-- grid, so it is logged (#710)" is `null;`. docs/reference.md (fail_obtain_name) promises a row per tick.
create extension if not exists pgtap;
select plan(6);
create table public.f18h (id bigint primary key, v int);
insert into public.f18h select i, i from generate_series(1, 50) i;
call pgpm.transmute('public.f18h', 'id', 1000::bigint, p_obtain => 2);
-- the next cell past the grid obtain built, and a sequence of the operator's at its name
select max(hi::numeric)::text as nlo, (max(hi::numeric) + 1000)::text as nhi
  from pgpm.part where parent_table = 'public.f18h'::regclass and attached \gset
select pgpm._part_name('f18h', 'id', '1000', :'nlo', :'nhi', 'UTC') as held \gset
select format('create sequence public.%I', :'held') \gexec
select is((select relkind::text from pg_class where oid = to_regclass(format('public.%I', :'held'))), 'S',
          'LIVENESS: a sequence holds the next forward cell''s name ' || :'held');
select pgpm.set_obtain('public.f18h', 3);
select is(pgpm.obtain('public.f18h'), 0, 'LIVENESS: obtain built nothing for the held cell');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.f18h'::regclass and lo = :'nlo'),
          'LIVENESS: the cell [' || :'nlo' || ', ' || :'nhi' || ') is unbuilt: a hole in the grid');
select is((select relkind::text from pg_class where oid = to_regclass(format('public.%I', :'held'))), 'S',
          'LIVENESS: the sequence still holds the name');
-- the defect: the hole must be logged, naming what holds the name
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.f18h'::regclass and action = 'fail_obtain_name' and lo = :'nlo'),
          1, 'obtain logged fail_obtain_name for the unbuilt cell');
select ok(exists (select 1 from pgpm.log
            where parent_table = 'public.f18h'::regclass and action = 'fail_obtain_name' and method like '%' || :'held' || '%'),
          'and the row names the holder');
select * from finish();
