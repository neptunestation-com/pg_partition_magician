-- Issue #1478: maintain()'s auto-regrain candidate scan passes over a coarse partition DROPped by hand.
--
-- The scan left out a coarse child the operator detached by hand (#705, _part_detached_by_hand), but not
-- one the operator dropped: DROP TABLE on a partition is something PostgreSQL permits and pgpm never sees,
-- so its pgpm.part row stays attached. Being the oldest frozen coarse child, it was the candidate on every
-- tick, regrain_step refused it as gone ("the partition pgpm.part records under that name no longer
-- exists"), the tick logged skip_regrain, and the coarse children behind it were never regrained. The scan
-- now reads the rows through _part_built, the predicate status() asks, which is false for both.
--
-- Fixture: an id table, step 10000, history 10..59990, transmuted to a monolith [0, 60000) and split by hand
-- into three coarse children of 20000 (the documented hierarchical use of regrain), then a frontier write at
-- 75000 that freezes all three. Auto-regrain toward 10000 is set, and the operator drops the OLDEST coarse
-- child, [0, 20000): two coarse children stand behind it, which the unfixed code never reaches. Asymmetric:
-- one dropped, two to regrain, so a regrain of the wrong child cannot pass as a regrain of the right one.
--
-- Identity, not cardinality: the regrains are named by their bounds, the cells by their lo, the rows by id.
-- Every negative (no skip_regrain, no run started on the dropped child) is paired with a LIVENESS witness that
-- the dropped child's row really stood attached, with its relation gone, through every tick.
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(14);

create table public.rg394 (id bigint primary key, body text);
insert into public.rg394 select g, 'h' || g from generate_series(10, 59990, 10) g;
call pgpm.transmute('public.rg394', 'id', 10000, p_obtain => 4, p_paused => false);
insert into public.rg394 values (75000, 'frontier');

-- the documented hierarchical split: the monolith into three coarse children of 20000
select pgpm.regrain_history('public.rg394', '20000');

select is(
  (select string_agg(lo || '..' || hi, ' ' order by lo::bigint) from pgpm.part
    where parent_table = 'public.rg394'::regclass and attached and lo::bigint < 60000),
  '0..20000 20000..40000 40000..60000',
  'LIVENESS: the hierarchical split left three coarse children, [0, 20000), [20000, 40000) and [40000, 60000)');
select is(
  (select pgpm._grid_floor(control_kind, partition_step, partition_anchor, pgpm._frontier_native('public.rg394'), partition_tz)
     from pgpm.config where parent_table = 'public.rg394'::regclass),
  '70000',
  'LIVENESS: the frontier write puts the grid floor at 70000, so all three coarse children are frozen');

create temp table rg394_names as
  select lo, hi, child_name, child_oid from pgpm.part where parent_table = 'public.rg394'::regclass and attached;
select child_name as dropped, child_oid as dropped_oid from rg394_names where lo = '0' \gset
create temp table rg394_before as select id from public.rg394 where id >= 20000;

select lives_ok($$ select pgpm.set_regrain('public.rg394', '10000') $$,
  'LIVENESS: auto-regrain toward 10000 is on');

-- the operator drops the oldest coarse child by hand
select format('drop table public.%I', :'dropped') \gexec

select ok(not exists (select 1 from pg_class where oid = :'dropped_oid'::oid)
          and exists (select 1 from pgpm.part where parent_table = 'public.rg394'::regclass
                        and child_oid = :'dropped_oid'::oid and attached),
  'LIVENESS: [0, 20000)''s relation is gone, and its pgpm.part row still stands attached');
select is((select coarse_partitions from pgpm.status() where parent = 'public.rg394'::regclass), 2::bigint,
  'LIVENESS: status() counts the two coarse children behind it, not the dropped one');

-- Tick. Each coarse child takes a prepare, a copy and a swap; 16 ticks is twice what both need. Every
-- status is kept, so a wedge would show as the same deferral on every tick.
create temp table rg394_ticks (n int, status text);
do $$
declare s text;
begin
  for i in 1..16 loop
    call pgpm.maintain('public.rg394', s);
    insert into rg394_ticks values (i, s);
  end loop;
end $$;

select ok(not exists (select 1 from pg_class where oid = :'dropped_oid'::oid)
          and exists (select 1 from pgpm.part where parent_table = 'public.rg394'::regclass
                        and child_oid = :'dropped_oid'::oid and attached),
  'LIVENESS: the dropped child''s row still stood attached, its relation gone, after every tick');

select is(
  (select string_agg(lo || '..' || hi, ' ' order by lo::bigint) from pgpm.log
    where parent_table = 'public.rg394'::regclass and action = 'regrain' and method = 'copy_swap_drop'
      and hi::bigint <= 60000 and not (lo = '0' and hi = '60000')),
  '20000..40000 40000..60000',
  'auto-regrain swapped exactly the two coarse children behind the dropped one, [20000, 40000) then [40000, 60000)');

select is(
  (select string_agg(lo || '..' || hi, ' ' order by lo::bigint) from pgpm.part
    where parent_table = 'public.rg394'::regclass and attached and lo::bigint >= 20000 and hi::bigint <= 60000),
  '20000..30000 30000..40000 40000..50000 50000..60000',
  '[20000, 60000) is exactly its four 10000-wide cells');

select is(
  (select count(*) from pgpm.log where parent_table = 'public.rg394'::regclass and action = 'skip_regrain'),
  0::bigint,
  'no tick logged skip_regrain: the dropped child was never the candidate');
select is(
  (select count(*) from rg394_ticks where status like '%regrain=deferred%'),
  0::bigint,
  'no tick answered regrain=deferred');
select is(
  (select count(*) from pgpm.log where parent_table = 'public.rg394'::regclass
     and action in ('regrain_prepare', 'regrain_rename', 'regrain') and lo = '0' and hi = '20000'),
  0::bigint,
  'no regrain was started, renamed or swapped on the dropped [0, 20000)');
select is((select coarse_partitions from pgpm.status() where parent = 'public.rg394'::regclass), 0::bigint,
  'status() counts no coarse child left');

-- Row identity across both regrains: the same ids from 20000 up, no more, no fewer.
select is_empty(
  $$ select id from rg394_before except select id from public.rg394 where id >= 20000 $$,
  'every row from 20000 up is still in the parent');
select is_empty(
  $$ select id from public.rg394 where id >= 20000 except select id from rg394_before $$,
  'and nothing that was not in the fixture appeared');

select * from finish();
