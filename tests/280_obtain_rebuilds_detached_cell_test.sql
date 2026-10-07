-- obtain and extend_to rebuild a forward cell DETACHed by hand, and leave the detached table alone (#956).
--
-- THE BUG. #908 made obtain rebuild a forward cell whose partition was DROPPED by hand, judging a cell
-- built when the relation its pgpm.part row anchors still exists. A cell DETACHED by hand keeps its
-- relation, so it stayed "built": never rebuilt, nothing logged, every write into its range refused for
-- good, while status() went on counting it.
--
-- THE CONTRACT. A cell is built when its relation is a partition of the table (pg_inherits), or when a
-- retirement of pgpm's own is in flight on it (retiring_at set: retire()'s concurrent detach leaves the
-- relation detached until retire drops it).
--   PART A  obtain: two forward cells detached by hand, [30, 40) holding a row the operator keeps and
--           [50, 60) empty, a live cell between them. status() stops counting them. obtain forgets exactly
--           those two rows (forget_detached_partition, naming each), builds a fresh partition over each
--           range (under its explicit-range name, as the detached table keeps the plain one), leaves the
--           live cell alone and the operator's tables exactly as they were (same oid, same name, their
--           row), and writes into both ranges land in the new partitions. A second obtain does nothing.
--   PART B  extend_to: a detached cell inside its walk is rebuilt along with the new cells past the grid.
--   PART C  retire()'s in-flight state: a forward cell detached with retiring_at set is NOT forgotten or
--           rebuilt; its row keeps anchoring the same relation.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(27);

-- ==================== (A) obtain rebuilds two hand-detached cells ====================
create table public.dt280 (id bigint primary key, payload text);
insert into public.dt280 values (1, 'a'), (2, 'b');
call pgpm.transmute('public.dt280', 'id', 10::bigint, p_obtain => 6);
insert into public.dt280 values (35, 'kept by the operator');

create temporary table cells280 as
  select p.lo, p.hi, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.dt280'::regclass and p.attached and p.lo in ('30', '40', '50');

select is((select count(*)::int from cells280 c
            where exists (select 1 from pg_inherits i where i.inhparent = 'public.dt280'::regclass and i.inhrelid = c.child_oid)),
  3, 'LIVENESS: transmute built [30, 40), [40, 50) and [50, 60) as partitions of the table');
select is((select tableoid::oid from public.dt280 where id = 35), (select child_oid from cells280 where lo = '30'),
  'LIVENESS: the row 35 lives in [30, 40)');

-- the operator detaches two forward cells by hand
select format('alter table public.dt280 detach partition public.%I', child_name) from cells280 where lo in ('30', '50') \gexec

select ok(not exists (select 1 from pg_inherits i join cells280 x on x.child_oid = i.inhrelid where x.lo in ('30', '50'))
          and (select count(*) from pg_class c join cells280 x on x.child_oid = c.oid where x.lo in ('30', '50')) = 2,
  'LIVENESS: both cells are detached, their tables kept');
select is((select array_agg(lo order by lo::numeric) from pgpm.part
            where parent_table = 'public.dt280'::regclass and attached and retiring_at is null and lo in ('30', '50')),
  array['30', '50'], 'LIVENESS: their rows are still attached with no retiring_at (the state the bug trusted)');
select throws_ok($$ insert into public.dt280 values (36, 'x') $$, '23514', NULL,
  'LIVENESS: before obtain, a write into [30, 40) is refused');

select is((select n_partitions from pgpm.status() where parent = 'public.dt280'::regclass),
  (select count(*) from pg_inherits where inhparent = 'public.dt280'::regclass),
  'status().n_partitions counts the partitions the catalogue holds, not the detached cells');

create temporary table mark280 as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.obtain('public.dt280'), 2, 'obtain reports two partitions built');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.dt280'::regclass and action = 'obtain' and id > (select id from mark280)),
  array['30-40', '50-60'], 'obtain built exactly the two detached cells');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.dt280'::regclass and action = 'forget_detached_partition'
              and id > (select id from mark280)),
  array['30-40', '50-60'], 'obtain logged forget_detached_partition for exactly the two detached rows');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.dt280'::regclass
                       and action in ('forget_dropped_partition', 'fail_obtain_name') and id > (select id from mark280)),
  'and logged neither as dropped nor as left unbuilt');
select ok((select bool_and(l.method like '%' || x.child_name || '%') from pgpm.log l
             join cells280 x on x.lo = l.lo
            where l.parent_table = 'public.dt280'::regclass and l.action = 'forget_detached_partition'
              and l.id > (select id from mark280)),
  'each forget_detached_partition row names the detached table');
select is((select array_agg(p.lo order by p.lo::numeric) from pgpm.part p
             join pg_inherits i on i.inhrelid = p.child_oid and i.inhparent = 'public.dt280'::regclass
             join pg_class c on c.oid = p.child_oid
            where p.parent_table = 'public.dt280'::regclass and p.attached and p.lo in ('30', '50')
              and p.child_oid not in (select child_oid from cells280)
              and pg_get_expr(c.relpartbound, c.oid) = format('FOR VALUES FROM (%L) TO (%L)', p.lo, p.hi)),
  array['30', '50'], 'both rows now anchor NEW partitions that hold their bounds');
select is((select p.child_oid from pgpm.part p where p.parent_table = 'public.dt280'::regclass and p.lo = '40'),
  (select child_oid from cells280 where lo = '40'), 'the live cell [40, 50) between them was left alone, by identity');
select is((select array_agg(c.relname::text order by x.lo::numeric) from pg_class c join cells280 x on x.child_oid = c.oid
            where x.lo in ('30', '50') and not c.relispartition),
  (select array_agg(child_name::text order by lo::numeric) from cells280 where lo in ('30', '50')),
  'the operator''s detached tables keep their oids and names, and stay detached');
select format('create temporary table kept280 as select id, payload from public.%I', child_name) from cells280 where lo = '30' \gexec
select is((select array_agg(id::text || ':' || payload) from kept280), array['35:kept by the operator'],
  'and the detached [30, 40) still holds the operator''s row');
select ok(not exists (select 1 from pgpm.part p join cells280 x on x.child_oid = p.child_oid where x.lo in ('30', '50')),
  'pgpm no longer records the detached tables');

create temporary table mark280b as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.obtain('public.dt280'), 0, 'a second obtain builds nothing');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.dt280'::regclass
                       and action in ('forget_detached_partition', 'forget_dropped_partition', 'obtain', 'fail_obtain_name')
                       and id > (select id from mark280b)),
  'and forgets nothing: the rebuilt rows are live');

select lives_ok($$ insert into public.dt280 values (36, 'into the first rebuilt cell'), (55, 'into the second') $$,
  'writes into both ranges are accepted');
select is((select array_agg(t.tableoid::oid = p.child_oid order by t.id) from public.dt280 t
             join pgpm.part p on p.parent_table = 'public.dt280'::regclass and p.lo = (t.id / 10 * 10)::text
            where t.id in (36, 55)),
  array[true, true], 'writes into both ranges land in the rebuilt partitions');

-- ==================== (B) extend_to rebuilds a detached cell inside its walk ====================
create table public.ex280 (id bigint primary key, payload text);
insert into public.ex280 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.ex280', 'id', 10::bigint, p_obtain => 2);
create temporary table cellx280 as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.ex280'::regclass and p.attached and p.lo = '20';
select format('alter table public.ex280 detach partition public.%I', child_name) from cellx280 \gexec
select ok(not exists (select 1 from pg_inherits i join cellx280 x on x.child_oid = i.inhrelid)
          and exists (select 1 from pgpm.part where parent_table = 'public.ex280'::regclass and lo = '20' and attached),
  'LIVENESS: [20, 30) was detached by hand and its pgpm.part row is still attached');

create temporary table markx280 as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.extend_to('public.ex280', '45'), 3, 'extend_to reports three partitions built');
select is((select array_agg(lo || '-' || hi || ':' || action order by lo::numeric, action) from pgpm.log
            where parent_table = 'public.ex280'::regclass and action in ('obtain', 'forget_detached_partition')
              and id > (select id from markx280)),
  array['20-30:forget_detached_partition', '20-30:obtain', '30-40:obtain', '40-50:obtain'],
  'extend_to forgot the detached [20, 30), rebuilt it and built the two new cells past the grid');

-- ==================== (C) a retirement in flight is not a hand detach ====================
create table public.rt280 (id bigint primary key, payload text);
insert into public.rt280 values (1, 'a'), (2, 'b');
call pgpm.transmute('public.rt280', 'id', 10::bigint, p_obtain => 4);
create temporary table cellr280 as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.rt280'::regclass and p.attached and p.lo = '20';
-- the state retire()'s concurrent detach leaves until retire drops the partition
update pgpm.part set retiring_at = now(), retiring_oid = child_oid
 where parent_table = 'public.rt280'::regclass and lo = '20';
select format('alter table public.rt280 detach partition public.%I', child_name) from cellr280 \gexec
select ok(not exists (select 1 from pg_inherits i join cellr280 x on x.child_oid = i.inhrelid)
          and exists (select 1 from pgpm.part p join cellr280 x on x.child_oid = p.child_oid
                       where p.attached and p.retiring_at is not null),
  'LIVENESS: [20, 30) is detached with a retirement of pgpm''s own in flight on it');

create temporary table markr280 as select coalesce(max(id), 0) as id from pgpm.log;
-- obtain in a statement of its own: a check in the same statement reads the snapshot taken before it ran
create temporary table mader280 as select pgpm.obtain('public.rt280') as n;
select is((select n from mader280), 0, 'obtain builds nothing over the retiring cell');
select ok(exists (select 1 from pgpm.part p where p.parent_table = 'public.rt280'::regclass and p.lo = '20'
                   and p.attached and p.child_oid = (select child_oid from cellr280)),
  'obtain leaves the retiring cell''s row anchoring the retiring relation');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.rt280'::regclass
                       and action in ('forget_detached_partition', 'forget_dropped_partition', 'obtain')
                       and lo = '20' and id > (select id from markr280)),
  'and neither forgets nor rebuilds it');

select * from finish();
