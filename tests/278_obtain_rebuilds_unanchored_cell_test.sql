-- obtain rebuilds a forward cell whose pgpm.part row an upgrade could not anchor (issue #981).
--
-- THE BUG. pgpm.part.child_oid (#421) is backfilled on upgrade through pg_inherits, by name. A forward cell
-- dropped by hand BEFORE the upgrade has no partition to resolve, so its row stays attached with a null
-- child_oid. The predicate that judges a row built (#908) read a null child_oid as present, so obtain and
-- extend_to never rebuilt the cell and nothing was logged, and forget_missing (which the code named as the
-- remedy) only clears rows whose PARENT is gone: every write into the range was refused, for good.
--
-- THE CONTRACT.
--   PART A  An unanchored row is built only if some partition of the table is unaccounted for: with every
--           partition anchored by another row, its relation cannot exist. Two such rows ([20, 30) and
--           [50, 60), their partitions dropped), a live anchored cell between them. Before obtain, status()
--           counts neither. obtain forgets exactly those two rows (forget_dropped_partition, naming each),
--           rebuilds exactly those cells, anchors the rebuilt rows by oid, leaves the live cell alone by
--           identity, and writes into both ranges land. A second obtain finds nothing to do.
--   PART B  The other half, which keeps the rule from wedging obtain: a forward cell RENAMED by hand before
--           the upgrade leaves the same null child_oid while its partition still holds the range. Read as
--           gone, obtain would forget the row and die on the overlap at every tick. It is left as it is,
--           obtain succeeds, and a write into the range lands in the renamed partition.
-- The state the upgrade leaves is made directly here (child_oid set null on a current install), which is
-- exactly what the backfill writes for a name it cannot resolve; bench/upgrade_unanchored_cell.sh runs the
-- same contract across a real upgrade from v0.5.0, the newest release without the column.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(19);

-- ==================== (A) two unanchored rows whose partitions are gone ====================
create table public.ub278 (id bigint primary key, payload text);
insert into public.ub278 values (1, 'a'), (2, 'b');
call pgpm.transmute('public.ub278', 'id', 10::bigint, p_obtain => 6);

create temporary table cells278 as
  select p.lo, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.ub278'::regclass and p.attached and p.lo in ('20', '30', '50');

select is((select count(*)::int from cells278 c
            where exists (select 1 from pg_inherits i where i.inhparent = 'public.ub278'::regclass and i.inhrelid = c.child_oid)),
  3, 'LIVENESS: transmute built [20, 30), [30, 40) and [50, 60) as partitions of the table');

-- what the backfill leaves for a cell dropped before the upgrade: the row attached, its oid unknown
update pgpm.part set child_oid = null
 where parent_table = 'public.ub278'::regclass and lo in ('20', '50');
select format('drop table public.%I', child_name) from cells278 where lo in ('20', '50') \gexec

select is((select array_agg(lo order by lo::numeric) from pgpm.part
            where parent_table = 'public.ub278'::regclass and attached and child_oid is null),
  array['20', '50'], 'LIVENESS: exactly the two rows are attached and unanchored');
select ok(not exists (select 1 from pg_class c join cells278 x on x.child_oid = c.oid where x.lo in ('20', '50')),
  'LIVENESS: both of their partitions are gone from the catalogue');

select is((select n_partitions from pgpm.status() where parent = 'public.ub278'::regclass),
  (select count(*) from pg_inherits where inhparent = 'public.ub278'::regclass),
  'status().n_partitions counts the partitions the catalogue holds, not the unanchored rows');

create temporary table mark278 as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.obtain('public.ub278'), 2, 'obtain reports two partitions built');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.ub278'::regclass and action = 'obtain' and id > (select id from mark278)),
  array['20-30', '50-60'], 'obtain built exactly the two cells the unanchored rows stood for');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.ub278'::regclass and action = 'forget_dropped_partition'
              and id > (select id from mark278)),
  array['20-30', '50-60'], 'obtain logged forget_dropped_partition for exactly the two unanchored rows');
select ok((select bool_and(l.method like '%' || x.child_name || '%') from pgpm.log l
             join cells278 x on x.lo = l.lo
            where l.parent_table = 'public.ub278'::regclass and l.action = 'forget_dropped_partition'
              and l.id > (select id from mark278)),
  'each forget_dropped_partition row names the partition that was recorded');
select is((select array_agg(p.lo order by p.lo::numeric) from pgpm.part p
             join pg_inherits i on i.inhrelid = p.child_oid and i.inhparent = 'public.ub278'::regclass
             join pg_class c on c.oid = p.child_oid
            where p.parent_table = 'public.ub278'::regclass and p.attached and p.lo in ('20', '50')
              and pg_get_expr(c.relpartbound, c.oid)
                  = format('FOR VALUES FROM (%L) TO (%L)', p.lo, p.hi)),
  array['20', '50'], 'both rebuilt rows anchor, by oid, the partition that holds their bounds');
select is((select p.child_oid from pgpm.part p where p.parent_table = 'public.ub278'::regclass and p.lo = '30'),
  (select child_oid from cells278 where lo = '30'), 'the live cell [30, 40) between them was left alone, by identity');

create temporary table mark278b as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.obtain('public.ub278'), 0, 'a second obtain builds nothing');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.ub278'::regclass
                       and action in ('forget_dropped_partition', 'obtain', 'fail_obtain_name')
                       and id > (select id from mark278b)),
  'and forgets nothing: the rebuilt rows are anchored and live');

select lives_ok($$ insert into public.ub278 values (25, 'in the first hole'), (55, 'in the second hole') $$,
  'writes into both rebuilt ranges are accepted');
select is((select array_agg(id order by id) from public.ub278 where id in (25, 55)),
  array[25, 55]::bigint[], 'and land');

-- ==================== (B) an unanchored row whose partition was renamed, not dropped ====================
create table public.rn278 (id bigint primary key, payload text);
insert into public.rn278 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.rn278', 'id', 10::bigint, p_obtain => 4);

create temporary table cellr278 as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.rn278'::regclass and p.attached and p.lo = '20';
select format('alter table public.%I rename to rn278_kept', child_name) from cellr278 \gexec
update pgpm.part set child_oid = null where parent_table = 'public.rn278'::regclass and lo = '20';

select ok(exists (select 1 from pg_inherits i join cellr278 x on x.child_oid = i.inhrelid
                   where i.inhparent = 'public.rn278'::regclass)
          and (select child_oid is null and attached from pgpm.part
                where parent_table = 'public.rn278'::regclass and lo = '20'),
  'LIVENESS: the renamed partition still holds [20, 30) and its row is attached and unanchored');

create temporary table markr278 as select coalesce(max(id), 0) as id from pgpm.log;
select lives_ok($$ select pgpm.obtain('public.rn278') $$,
  'obtain does not die on the renamed partition''s range');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.rn278'::regclass
                       and action in ('forget_dropped_partition', 'forget_detached_partition')
                       and id > (select id from markr278))
          and exists (select 1 from pgpm.part where parent_table = 'public.rn278'::regclass and lo = '20' and attached),
  'the row of the renamed cell is not forgotten');

select lives_ok($$ insert into public.rn278 values (24, 'into the renamed partition') $$,
  'a write into [20, 30) is accepted');
select is((select tableoid::oid from public.rn278 where id = 24), (select child_oid from cellr278),
  'a write into [20, 30) lands in the renamed partition');

select * from finish();
