-- F1-04: obtain (and extend_to) leave a forward cell unbuilt when a stranger holds its name, and log
-- nothing: the `if v_name is null then ... end if` that should call _log_unbuilt_cell does `null;`, and
-- _log_unbuilt_cell is called from nowhere. docs/reference.md (pgpm.log, Partition naming) promises a
-- fail_obtain_name row naming the holder, once per tick, for every such hole.
create extension if not exists pgtap;
select plan(5);
set timezone = 'UTC';

create table public.f1ob (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.f1ob select i, now() - i * interval '1 hour' from generate_series(1, 20) i;
call pgpm.transmute('public.f1ob', 'ts', interval '1 day', p_obtain => 2);

-- the cell just past the current lookahead, and a stranger's table at its name
select max(hi) as cell_lo from pgpm.part where parent_table = 'public.f1ob'::regclass \gset
select pgpm._grid_next('time', '1 day', :'cell_lo', 'UTC') as cell_hi \gset
select pgpm._part_name('f1ob', 'time', '1 day', :'cell_lo', :'cell_hi', 'UTC') as cell_name \gset
create table public.:"cell_name" (note text);   -- the operator's own table, not a partition of f1ob
select set_obtain from pgpm.set_obtain('public.f1ob', 4);
select pgpm.obtain('public.f1ob') as made \gset

select ok(:made >= 1, 'LIVENESS: obtain built the cells past the held one (it ran over the widened lookahead)');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.f1ob'::regclass
                        and lo = :'cell_lo' and attached),
          'LIVENESS: the cell at ' || :'cell_lo' || ' is left unbuilt');
select ok(to_regclass('public.' || quote_ident(:'cell_name')) is not null
          and not exists (select 1 from pg_inherits where inhrelid = to_regclass('public.' || quote_ident(:'cell_name'))),
          'LIVENESS: its name is held by a standalone table of the operator''s');
select is((select count(*)::int from pgpm.log where parent_table = 'public.f1ob'::regclass
             and action = 'fail_obtain_name' and lo = :'cell_lo' and hi = :'cell_hi'), 1,
          'obtain logs fail_obtain_name for the unbuilt cell [' || :'cell_lo' || ', ' || :'cell_hi' || ')');
select ok((select method from pgpm.log where parent_table = 'public.f1ob'::regclass
             and action = 'fail_obtain_name' and lo = :'cell_lo') like '%' || :'cell_name' || '%',
          'and the row names the relation holding the cell''s name');
select * from finish();
