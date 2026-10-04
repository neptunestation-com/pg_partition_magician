-- obtain and extend_to rebuild a forward cell whose partition was dropped by hand (issue #908).
--
-- THE BUG. DROP TABLE on one of obtain's empty forward cells is something PostgreSQL permits and pgpm
-- neither refuses nor sees: the partition goes, its pgpm.part row stays attached. obtain and extend_to
-- decided "already built" from that row alone (an attached row overlapping the cell), so the cell was never
-- rebuilt and nothing was logged: every write into its range was refused with "no partition of relation
-- found for row", for good, while status() still counted the partition and reported its hi as the ceiling.
--
-- THE CONTRACT.
--   PART A  obtain: two cells of the lookahead dropped by hand ([30, 40) inside it, [60, 70) its top).
--           Before obtain runs, status() counts what the catalogue holds and reports the ceiling the
--           surviving grid gives. obtain forgets exactly the two dead rows (logged forget_dropped_partition,
--           naming each), rebuilds exactly those two cells, records the NEW relations' identities, leaves
--           the live cell between them alone, and writes into both ranges land. A second obtain finds
--           nothing to forget or build.
--   PART B  extend_to: a dropped cell inside the walk is rebuilt along with the new cells past the grid,
--           with the new relation's identity recorded.
-- The fixtures are asymmetric on purpose: two holes in A against one in B, and a live cell between A's
-- holes, so a fix that forgot every row, or none, or rebuilt without re-anchoring, cannot pass by luck.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(24);

-- ==================== (A) obtain rebuilds two hand-dropped cells ====================
create table public.ob264 (id bigint primary key, payload text);
insert into public.ob264 values (1, 'a'), (2, 'b');
call pgpm.transmute('public.ob264', 'id', 10::bigint, p_obtain => 6);

-- the cells as transmute's obtain built them, by identity
create temporary table cells264 as
  select p.lo, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.ob264'::regclass and p.attached and p.lo in ('30', '40', '60');

select is((select count(*)::int from cells264 c
            where exists (select 1 from pg_inherits i where i.inhparent = 'public.ob264'::regclass and i.inhrelid = c.child_oid)),
  3, 'LIVENESS: transmute built [30, 40), [40, 50) and [60, 70) as partitions of the table');
select is((select max(hi::numeric) from pgpm.part where parent_table = 'public.ob264'::regclass and attached),
  70::numeric, 'LIVENESS: [60, 70) is the top of the forward grid');

-- the operator drops two empty forward cells by hand
select format('drop table public.%I', child_name) from cells264 where lo in ('30', '60') \gexec

select ok(not exists (select 1 from pg_class c join cells264 x on x.child_oid = c.oid where x.lo in ('30', '60')),
  'LIVENESS: the hand DROPs removed both partitions');
select is((select array_agg(lo order by lo::numeric) from pgpm.part
            where parent_table = 'public.ob264'::regclass and attached and lo in ('30', '40', '60')),
  array['30', '40', '60'], 'LIVENESS: their pgpm.part rows are still attached (the state the bug trusted)');

-- status() reads the catalogue: the dead rows are neither counted nor the ceiling
select is((select n_partitions from pgpm.status() where parent = 'public.ob264'::regclass),
  (select count(*) from pg_inherits where inhparent = 'public.ob264'::regclass),
  'status().n_partitions counts the partitions the catalogue holds, not the dead rows');
select is((select count(*) from pgpm.part where parent_table = 'public.ob264'::regclass and attached)
          - (select count(*) from pg_inherits where inhparent = 'public.ob264'::regclass),
  2::bigint, 'LIVENESS: pgpm.part carries exactly two attached rows more than the catalogue');
select is((select newest_bound from pgpm.status() where parent = 'public.ob264'::regclass),
  '60', 'status().newest_bound is the top of the surviving grid, not the dropped cell''s hi');

create temporary table mark264 as select coalesce(max(id), 0) as id from pgpm.log;
create temporary table made264 as select pgpm.obtain('public.ob264') as n;

select is((select n from made264), 2, 'obtain reports two partitions built');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.ob264'::regclass and action = 'obtain' and id > (select id from mark264)),
  array['30-40', '60-70'], 'obtain built exactly the two dropped cells');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.ob264'::regclass and action = 'forget_dropped_partition'
              and id > (select id from mark264)),
  array['30-40', '60-70'], 'obtain logged forget_dropped_partition for exactly the two dead rows');
select ok((select bool_and(l.method like '%' || x.child_name || '%') from pgpm.log l
             join cells264 x on x.lo = l.lo
            where l.parent_table = 'public.ob264'::regclass and l.action = 'forget_dropped_partition'
              and l.id > (select id from mark264)),
  'each forget_dropped_partition row names the partition that was dropped');

-- identity: the rows now anchor the relations that hold the bounds, not the dropped ones
select ok(exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                   join pg_class c on c.oid = p.child_oid
                  where p.parent_table = 'public.ob264'::regclass and p.lo = '30' and p.attached
                    and i.inhparent = 'public.ob264'::regclass
                    and pg_get_expr(c.relpartbound, c.oid) = 'FOR VALUES FROM (''30'') TO (''40'')'),
  'the [30, 40) row anchors the rebuilt partition that holds those bounds');
select ok(exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                   join pg_class c on c.oid = p.child_oid
                  where p.parent_table = 'public.ob264'::regclass and p.lo = '60' and p.attached
                    and i.inhparent = 'public.ob264'::regclass
                    and pg_get_expr(c.relpartbound, c.oid) = 'FOR VALUES FROM (''60'') TO (''70'')'),
  'the [60, 70) row anchors the rebuilt partition that holds those bounds');
select is((select p.child_oid from pgpm.part p where p.parent_table = 'public.ob264'::regclass and p.lo = '40'),
  (select child_oid from cells264 where lo = '40'), 'the live cell [40, 50) between them was left alone, by identity');

-- before the writes below, which move the frontier and so the lookahead
create temporary table mark264b as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.obtain('public.ob264'), 0, 'a second obtain builds nothing');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.ob264'::regclass
                       and action in ('forget_dropped_partition', 'obtain', 'fail_obtain_name')
                       and id > (select id from mark264b)),
  'and forgets nothing: the rebuilt rows are live');

insert into public.ob264 values (35, 'in the first hole'), (65, 'in the second hole');
select is((select array_agg(id order by id) from public.ob264 where id in (35, 65)),
  array[35, 65]::bigint[], 'writes into both rebuilt ranges land');

select is((select n_partitions from pgpm.status() where parent = 'public.ob264'::regclass),
  (select count(*) from pg_inherits where inhparent = 'public.ob264'::regclass),
  'status().n_partitions matches the catalogue after the rebuild');
select is((select newest_bound from pgpm.status() where parent = 'public.ob264'::regclass),
  '70', 'status().newest_bound is the rebuilt top cell''s hi');

-- ==================== (B) extend_to rebuilds a dropped cell inside its walk ====================
create table public.ex264 (id bigint primary key, payload text);
insert into public.ex264 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.ex264', 'id', 10::bigint, p_obtain => 2);
create temporary table cellx264 as
  select p.lo, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.ex264'::regclass and p.attached and p.lo = '20';
select format('drop table public.%I', child_name) from cellx264 \gexec

select ok(not exists (select 1 from pg_class c join cellx264 x on x.child_oid = c.oid)
          and exists (select 1 from pgpm.part where parent_table = 'public.ex264'::regclass and lo = '20' and attached),
  'LIVENESS: [20, 30) was dropped by hand and its pgpm.part row is still attached');

create temporary table markx264 as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.extend_to('public.ex264', '45'), 3, 'extend_to reports three partitions built');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.ex264'::regclass and action = 'obtain' and id > (select id from markx264)),
  array['20-30', '30-40', '40-50'], 'extend_to rebuilt the dropped [20, 30) and built the two new cells past the grid');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.ex264'::regclass and action = 'forget_dropped_partition'
              and id > (select id from markx264)),
  array['20-30'], 'extend_to logged forget_dropped_partition for the one dead row');
select ok(exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                   join pg_class c on c.oid = p.child_oid
                  where p.parent_table = 'public.ex264'::regclass and p.lo = '20' and p.attached
                    and i.inhparent = 'public.ex264'::regclass
                    and pg_get_expr(c.relpartbound, c.oid) = 'FOR VALUES FROM (''20'') TO (''30'')'),
  'the [20, 30) row anchors the rebuilt partition that holds those bounds');

select * from finish();
