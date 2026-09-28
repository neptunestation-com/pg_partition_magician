-- Issue #585: a parent renamed mid-regrain must not wedge the regrain.
--
-- regrain_step found the fine child of the sub-range it was copying by re-rendering its NAME from the
-- parent's CURRENT relname (to_regclass(_part_name(v_rel, ...))). Renaming the parent is documented as
-- harmless mid-regrain (#496 anchored the capture relations against exactly that), but after an ALTER
-- TABLE ... RENAME the rendered name no longer matched the child the copy had already started, so the
-- next tick found "nothing", created a SECOND not-attached child for the same [lo, hi) and recorded it in
-- pgpm.part beside the first. The swap then attached both and failed "would overlap" on every tick,
-- until someone ran regrain_cancel. The fix asks pgpm.part, the swap's own authority, for a not-attached
-- child with exactly the sub-range's bounds first, and renders a name only to CREATE one.
--
-- Fixture: an id grid of step 1000000 whose monolith [0, 2000000) is regrained toward 100000. One
-- sub-range is copied part-way (4 of its 10 rows) when the parent is renamed. After the rename, DML
-- lands in that sub-range (1 update, 1 delete of a copied row, 2 inserts: asymmetric so no pair of
-- errors can cancel) and the regrain is finished with pgpm.regrain(). Identity, not cardinality: the
-- child that ends up attached for [100000, 200000) is the very relation (oid) created before the rename,
-- and the sub-range's rows are named one by one with their payloads.
create extension if not exists pgtap;
select plan(14);

create table public.rn (id bigint primary key, payload text);
insert into public.rn select g, 'orig' from generate_series(100001, 100010) g;   -- sub-range [100000, 200000)
insert into public.rn values (1999999, 'widen');
call pgpm.transmute('public.rn', 'id', 1000000);
select pgpm.obtain('public.rn');
insert into public.rn values (3500000, 'frontier');

-- prepare, finish [0, 100000) (empty), and copy ONE batch of 4 of the 10 rows of [100000, 200000)
select is(pgpm.regrain_step('public.rn', 'rn_p0000000000000000000_to_0000000000002000000', '100000', 4),
          'prepared', 'fixture: prepare tick');
select is(pgpm.regrain_step('public.rn', 'rn_p0000000000000000000_to_0000000000002000000', '100000', 4),
          'copied:0', 'fixture: the empty first sub-range completes');
select is(pgpm.regrain_step('public.rn', 'rn_p0000000000000000000_to_0000000000002000000', '100000', 4),
          'copied:4', 'fixture: one partial batch of the second sub-range');

create temp table mid as
  select p.child_oid from pgpm.part p
   where p.parent_table = 'public.rn'::regclass and not p.attached and p.lo = '100000' and p.hi = '200000';
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.rn'::regclass) = '100000'
          and (select array_agg(id order by id) from public.rn_p0000000000000100000) = array[100001, 100002, 100003, 100004]::bigint[]
          and (select child_oid from mid) = 'public.rn_p0000000000000100000'::regclass::oid,
  'LIVENESS: the rename below lands mid-copy: cursor at 100000, its fine child holds exactly 100001..100004 of its 10 rows');

alter table public.rn rename to rn2;

select isnt(pgpm._part_name('rn2', 'id', '100000', '100000', '200000', 'UTC'), 'rn_p0000000000000100000',
  'LIVENESS: after the rename the sub-range''s name rendered from the parent''s relname is not its child''s name');

update public.rn2 set payload = 'after_rename' where id = 100002;
delete from public.rn2 where id = 100003;
insert into public.rn2 values (100011, 'new_a'), (100012, 'new_b');

-- one tick after the rename: it must resume the copy into the child that already holds 100001..100004
select is(pgpm.regrain_step('public.rn2', 'rn_p0000000000000000000_to_0000000000002000000', '100000', 4),
          'copied:4', 'the first tick after the rename copies the next batch of the in-progress sub-range');
select is((select array_agg(id order by id) from public.rn_p0000000000000100000),
          array[100001, 100002, 100003, 100004, 100005, 100006, 100007, 100008]::bigint[],
  'that batch landed in the child the copy had already started (100005..100008 after 100001..100004)');
select is(to_regclass('public.rn2_p0000000000000100000'), null,
  'and no second child was minted for the in-progress sub-range under the new relname');

create function pg_temp.finish_regrain() returns text language plpgsql as $f$
begin
  return 'swapped:' || pgpm.regrain('public.rn2', 'rn_p0000000000000000000_to_0000000000002000000', '100000');
exception when others then return 'error: ' || sqlerrm;
end $f$;
select is(pg_temp.finish_regrain(), 'swapped:20',
  'the regrain finishes after the parent is renamed mid-copy: 20 fine partitions attached');

select is((select p.child_oid from pgpm.part p
            where p.parent_table = 'public.rn2'::regclass and p.attached and p.lo = '100000' and p.hi = '200000'),
          (select child_oid from mid),
  'the partition attached for [100000, 200000) is the child whose copy started before the rename (same oid)');
select is((select c.oid from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.rn2'::regclass and c.relname = 'rn_p0000000000000100000'),
          (select child_oid from mid),
  'and PostgreSQL agrees: that relation, under its pre-rename name, is the attached partition');
select isnt(to_regclass('public.rn2_p0000000000000200000'), null,
  'LIVENESS: sub-ranges begun after the rename were named from the new relname, so the rename was seen');
select is((select array_agg(format('%s=%s', id, payload) order by id) from public.rn2 where id between 100000 and 199999),
          array['100001=orig', '100002=after_rename', '100004=orig', '100005=orig', '100006=orig', '100007=orig',
                '100008=orig', '100009=orig', '100010=orig', '100011=new_a', '100012=new_b'],
  'every row of the split sub-range, with its current payload: the update kept, the delete kept, both inserts kept');
select is((select count(*)::int from pgpm.part where parent_table = 'public.rn2'::regclass and not attached), 0,
  'nothing is left not-attached after the swap');

select * from finish();
