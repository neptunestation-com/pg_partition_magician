-- Issue #723: _regrain_reconcile wrote a completed sub-range's captured changes into whatever relation bore
-- the fine child's recorded NAME.
--
-- #631 made regrain_step's copy branch check that a sub-range's name still resolves to the oid pgpm.part
-- recorded for its copy (child_oid, #421). The reconcile, which applies captured DML to sub-ranges the copy
-- has already FINISHED, kept writing `%I.%I` of the recorded name. So once a completed copy was renamed
-- aside and an unrelated table took its old name, a captured key's delete-and-reinsert landed in the
-- stranger: its row 10 was deleted and replaced by the managed table's row 10 (F3-02, pass 5). The fix
-- resolves the fine child through _regrain_copy_rel, which refuses when the name no longer resolves to the
-- recorded oid, so the tick fails loudly (maintain logs skip_regrain) and the delta keeps every key.
--
-- Fixture, asymmetric: the copy holds 10, 20, 30; the stranger holds 10 and 40; three changes are captured
-- in the completed sub-range (an UPDATE of 10, a DELETE of 30, an INSERT of 60). Every row is named, so a
-- lost change and a stray write cannot cancel. Once the stranger is gone and the copy has its name back the
-- same run reconciles and swaps, so the refusal was the only obstacle.
-- bench/regrain_reconcile_identity.sh runs this file against a mutant whose reconcile writes by name again
-- (regrain_reconcile_into_named_relation), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(14);

create function pg_temp.rows_of(p_rel text) returns text[] language plpgsql as $f$
declare v text[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg(id || '':'' || payload order by id) from %s', to_regclass(p_rel)) into v;
  return v;
end $f$;

create table public.rci (id bigint primary key, payload text);
insert into public.rci values (10, 'a'), (20, 'b'), (30, 'c'), (150000, 'd'), (1999999, 'widen');
call pgpm.transmute('public.rci', 'id', 1000000);
select pgpm.obtain('public.rci');
insert into public.rci values (3500000, 'frontier');
select child_name as rci_src from pgpm.part
 where parent_table = 'public.rci'::regclass and attached order by lo::numeric limit 1 \gset

select is(pgpm.regrain_step('public.rci', :'rci_src', '100000', 1000), 'prepared', 'fixture: the prepare tick');
select is(pgpm.regrain_step('public.rci', :'rci_src', '100000', 1000), 'copied:3',
  'fixture: sub-range [0, 100000) is copied whole in one short batch');
create temp table rci_copy as
  select child_oid from pgpm.part
   where parent_table = 'public.rci'::regclass and not attached and child_name = 'rci_p0000000000000000000';

-- the completed copy is renamed aside, and an unrelated table takes its name
alter table public.rci_p0000000000000000000 rename to rci_copy_aside;
create table public.rci_p0000000000000000000 (id bigint primary key, payload text);
insert into public.rci_p0000000000000000000 values (10, 'stranger-10'), (40, 'stranger-40');

-- three committed writes into the source's completed sub-range are captured
update public.rci set payload = 'z' where id = 10;
delete from public.rci where id = 30;
insert into public.rci values (60, 'n');
select pgpm._regrain_delta_count('public.rci', '0', '100000') as rci_pending \gset

select ok((select regrain_cursor from pgpm.config where parent_table = 'public.rci'::regclass) = '100000'
          and (select child_oid from rci_copy) = 'public.rci_copy_aside'::regclass::oid,
  'LIVENESS: [0, 100000) is complete (cursor 100000) and its recorded copy, by oid, is the renamed table');
select is(pg_temp.rows_of('public.rci_copy_aside'), array['10:a', '20:b', '30:c'],
  'LIVENESS: the recorded copy holds exactly the three rows copied');
select is(pg_temp.rows_of('public.rci_p0000000000000000000'), array['10:stranger-10', '40:stranger-40'],
  'LIVENESS: an unrelated table bears the copy''s name, holding exactly its own two rows');
select ok(:rci_pending > 0,
  'LIVENESS: the three writes are captured in the delta, eligible (below the cursor)');

select throws_like(
  format($$select pgpm.regrain_step('public.rci', %L, '100000', 1000)$$, :'rci_src'),
  'pg_partition_magician: cannot reconcile captured changes into the regrain copy public.rci_p0000000000000000000 of public.rci for [0, 100000) -- that name resolves to oid %, and no longer names the copy this regrain created (oid ' || (select child_oid from rci_copy) || ', now public.rci_copy_aside)%',
  'the reconcile refuses: the name no longer resolves to the copy pgpm.part recorded');

select is(pg_temp.rows_of('public.rci_p0000000000000000000'), array['10:stranger-10', '40:stranger-40'],
  'the unrelated table is untouched: its row 10 is neither deleted nor replaced, and no row 60 arrived');
select is(pg_temp.rows_of('public.rci_copy_aside'), array['10:a', '20:b', '30:c'],
  'the recorded copy is untouched by the refused tick');
select is(pgpm._regrain_delta_count('public.rci', '0', '100000'), :rci_pending::bigint,
  'the delta keeps every captured change: nothing was consumed by the refused tick');
select is((select array_agg(id || ':' || payload order by id) from public.rci where id < 100000),
  array['10:z', '20:b', '60:n'], 'the managed table reads the three writes through the source');

-- the copy gets its name back: the same run reconciles into it and swaps
drop table public.rci_p0000000000000000000;
alter table public.rci_copy_aside rename to rci_p0000000000000000000;
select alike(pgpm.regrain_step('public.rci', :'rci_src', '100000', 1000), 'reconciled:%',
  'LIVENESS: with the copy back under its name the next tick reconciles');
select is(pg_temp.rows_of('public.rci_p0000000000000000000'), array['10:z', '20:b', '60:n'],
  'the reconcile applied every captured change to the recorded copy');
select pgpm.regrain('public.rci', :'rci_src', '100000');
select is((select array_agg(id || ':' || payload order by id) from public.rci where id < 200000),
  array['10:z', '20:b', '60:n', '150000:d'], 'after the swap the managed table holds exactly the reconciled rows');

select * from finish();
