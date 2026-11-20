-- obtain, extend_to and maintain_obtain's back-off walk build around a partition attached by hand over a forward
-- cell (issue #1119).
--
-- THE GAP. Whether a cell is built was judged from pgpm.part alone (_cell_attached and obtain's walk), and pgpm.part
-- holds pgpm's partitions and nobody else's. A table the operator attached by hand over a forward cell's range was
-- invisible, so obtain's CREATE ... PARTITION OF for that cell raised "would overlap", which unwound the whole call
-- on every tick (skip_obtain): no other missing cell was built, and the forward grid stopped growing until writes
-- were refused. The reference promises obtain skips a candidate range that overlaps an existing attached partition
-- and builds the cells around it.
--
-- THE CONTRACT.
--   PART A  (the issue's reproduction) obtain: the operator replaced pgpm's [1000, 2000) with a table of their own,
--           attached over the same range, and pgpm's empty [2000, 3000) and [4000, 5000) were dropped by hand.
--           obtain leaves the operator's table alone (still a partition over its range, holding its own two rows,
--           recorded by no row), forgets the dead row it stood beside, and builds exactly [2000, 3000), the cell
--           ADJACENT to it, [4000, 5000) and [5000, 6000). Writes into the built cells land in pgpm's partitions,
--           and one into the operator's range lands in the operator's table.
--   PART B  extend_to walks the same table from the operator's cell (the frontier's) and builds the two cells past
--           the grid; its dry count does not charge the operator's cell, so p_max => 6 (six steps) is enough.
--   PART C  a table attached FROM (3500) TO (MAXVALUE), covering cells only in part and up to no bound: obtain
--           builds nothing over it, fails nothing, and forgets the two dead rows under it.
--   PART D  maintain_obtain's back-off walk counts the operator's cell as coverage: with the back-off armed, the
--           tick honours it, where a twin whose cell is a plain hole bypasses it and builds the hole.
--   PART E  a time grid read under a session zone that is not the grid's: the operator's day is left alone and the
--           two cells around it are built.
--
-- ASYMMETRIC FIXTURES. The operator's tables hold different rows (1500 and 1700 in A, 3600 in C, 1200 in D), and A
-- builds three cells around one foreign one, so a wrong cell built or a row lost cannot stand in for the answer.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(36);

-- ==================== (A) obtain builds around the operator's cell ====================
create table public.ha368 (id bigint primary key, payload text);
insert into public.ha368 select g, 'x' from generate_series(1, 500) g;
call pgpm.transmute('public.ha368', 'id', 1000::bigint, p_obtain => 4);

create temporary table cells368 as
  select p.lo, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.ha368'::regclass and p.attached;
select is((select array_agg(lo order by lo::numeric) from cells368), array['0', '1000', '2000', '3000', '4000'],
  'LIVENESS: transmute built [0, 1000) to [4000, 5000)');

-- the operator drops pgpm's [1000, 2000), [2000, 3000) and [4000, 5000) and attaches a table of their own over the first
select format('drop table public.%I', child_name) from cells368 where lo in ('1000', '2000', '4000') \gexec
create table public.ha368_mine (like public.ha368 including all);
insert into public.ha368_mine values (1500, 'mine-a'), (1700, 'mine-b');
alter table public.ha368 attach partition public.ha368_mine for values from (1000) to (2000);

select ok(exists (select 1 from pg_inherits where inhparent = 'public.ha368'::regclass and inhrelid = 'public.ha368_mine'::regclass)
          and not exists (select 1 from pgpm.part where child_oid = 'public.ha368_mine'::regclass::oid),
  'LIVENESS: the operator''s table is a partition of the table that no pgpm.part row records');
select is((select array_agg(lo order by lo::numeric) from pgpm.part
            where parent_table = 'public.ha368'::regclass and attached and lo in ('1000', '2000', '4000')),
  array['1000', '2000', '4000'], 'LIVENESS: the three dropped cells'' rows are still attached');
select is(pgpm._frontier_native('public.ha368'), '1700',
  'LIVENESS: the frontier is the operator''s row, so obtain''s walk starts at the operator''s cell');
select throws_ok($$insert into public.ha368 values (4500, 'top')$$, '23514', NULL,
  'LIVENESS: [4000, 5000) is a hole before obtain');

create temporary table mark368 as select coalesce(max(id), 0) as id from pgpm.log;
create temporary table made368 (n int);
select lives_ok($$insert into made368 select pgpm.obtain('public.ha368') as n$$,
  'obtain does not fail over the operator''s partition');
select is((select n from made368), 3, 'obtain reports three partitions built');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.ha368'::regclass and action = 'obtain' and id > (select id from mark368)),
  array['2000-3000', '4000-5000', '5000-6000'],
  'obtain built exactly the cell beside the operator''s, the dropped top cell and the next one');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.ha368'::regclass and action = 'forget_dropped_partition'
              and id > (select id from mark368)),
  array['1000-2000', '2000-3000', '4000-5000'], 'obtain forgot exactly the three dead rows');
select is((select array_agg(p.lo order by p.lo::numeric) from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
            where p.parent_table = 'public.ha368'::regclass and p.attached and i.inhparent = 'public.ha368'::regclass),
  array['0', '2000', '3000', '4000', '5000'], 'every pgpm.part row of the table anchors a partition of it, and none is at 1000');
select ok(not exists (select 1 from pgpm.part where child_oid = 'public.ha368_mine'::regclass::oid),
  'the operator''s table is still recorded by no row');
select is((select pg_get_expr(c.relpartbound, c.oid) from pg_class c join pg_inherits i on i.inhrelid = c.oid
            where c.oid = 'public.ha368_mine'::regclass and i.inhparent = 'public.ha368'::regclass),
  'FOR VALUES FROM (''1000'') TO (''2000'')', 'the operator''s table is still a partition over its own range');
select is((select array_agg(id || ':' || payload order by id) from public.ha368_mine),
  array['1500:mine-a', '1700:mine-b'], 'the operator''s table holds exactly its own rows');
select lives_ok($$insert into public.ha368 values (2500, 'beside'), (4500, 'top'), (5500, 'next'), (1800, 'theirs')$$,
  'writes into the three built cells and into the operator''s range land');
select is((select array_agg(t.id || ':' || p.lo order by t.id) from public.ha368 t
             join pgpm.part p on p.child_oid = t.tableoid and p.parent_table = 'public.ha368'::regclass
            where t.id in (2500, 4500, 5500)),
  array['2500:2000', '4500:4000', '5500:5000'], 'writes into the three built cells land in pgpm''s partitions');
select is((select tableoid::regclass::text from public.ha368 where id = 1800), 'ha368_mine',
  'a write into the operator''s range lands in the operator''s table');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.ha368'::regclass and action like '%obtain%'
                         and action <> 'obtain' and id > (select id from mark368)),
  'nothing but obtain rows was logged for the build');

-- ==================== (B) extend_to walks from the operator's cell ====================
select is(pgpm._frontier_native('public.ha368'), '5500', 'LIVENESS: the frontier is now 5500');
delete from public.ha368 where id in (2500, 4500, 5500);
select is(pgpm._frontier_native('public.ha368'), '1800',
  'LIVENESS: back at the operator''s cell, so extend_to''s walk and its dry count start there');
create temporary table ext368 (n int);
select lives_ok($$insert into ext368 select pgpm.extend_to('public.ha368', '7500', p_max => 6) as n$$,
  'extend_to over the operator''s cell is not refused (its dry count does not charge that cell)');
select is((select n from ext368), 2, 'extend_to built two partitions');
select is((select array_agg(p.lo order by p.lo::numeric) from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
            where p.parent_table = 'public.ha368'::regclass and p.attached and i.inhparent = 'public.ha368'::regclass),
  array['0', '2000', '3000', '4000', '5000', '6000', '7000'], 'extend_to built exactly [6000, 7000) and [7000, 8000)');

-- ==================== (C) a partial cover up to MAXVALUE ====================
create table public.hc368 (id bigint primary key, payload text);
insert into public.hc368 select g, 'x' from generate_series(1, 500) g;
call pgpm.transmute('public.hc368', 'id', 1000::bigint, p_obtain => 4);
select format('drop table public.%I', child_name) from pgpm.part
 where parent_table = 'public.hc368'::regclass and lo in ('3000', '4000') \gexec
create table public.hc368_mine (like public.hc368 including all);
insert into public.hc368_mine values (3600, 'mine');
alter table public.hc368 attach partition public.hc368_mine for values from (3500) to (maxvalue);
select is(pgpm._frontier_native('public.hc368'), '3600', 'LIVENESS: the walk starts at [3000, 4000), which the table covers in part');

create temporary table markc368 as select coalesce(max(id), 0) as id from pgpm.log;
create temporary table madec368 (n int);
select lives_ok($$insert into madec368 select pgpm.obtain('public.hc368') as n$$,
  'obtain does not fail over a partition reaching MAXVALUE');
select is((select n from madec368), 0, 'obtain builds nothing over it');
select is((select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = 'public.hc368'::regclass and attached),
  array['0', '1000', '2000'], 'only the cells below the operator''s table stay recorded');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.log
            where parent_table = 'public.hc368'::regclass and action = 'forget_dropped_partition'
              and id > (select id from markc368)),
  array['3000-4000', '4000-5000'], 'the two dead rows under it are forgotten');
select is((select array_agg(id || ':' || payload) from public.hc368_mine), array['3600:mine'],
  'the operator''s table holds exactly its own row');

-- ==================== (D) maintain_obtain's back-off walk ====================
-- hd368: the operator's table at [1000, 2000), the frontier's cell (its row 1200 is the frontier), then pgpm's
-- [2000, 3000) and [3000, 4000): ceil(4 / 2) = 2 steps of coverage. hh368, the twin: [1000, 2000) a plain hole one
-- step past the frontier's cell, which a write cannot reach to move the frontier into. Both have the back-off armed
-- an hour out.
create table public.hd368 (id bigint primary key, payload text);
insert into public.hd368 select g, 'x' from generate_series(1, 500) g;
call pgpm.transmute('public.hd368', 'id', 1000::bigint, p_obtain => 4, p_paused => false);
create table public.hh368 (id bigint primary key, payload text);
insert into public.hh368 select g, 'x' from generate_series(1, 500) g;
call pgpm.transmute('public.hh368', 'id', 1000::bigint, p_obtain => 4, p_paused => false);
select format('drop table public.%I', child_name) from pgpm.part
 where parent_table in ('public.hd368'::regclass, 'public.hh368'::regclass) and lo = '1000' \gexec
create table public.hd368_mine (like public.hd368 including all);
insert into public.hd368_mine values (1200, 'mine');
alter table public.hd368 attach partition public.hd368_mine for values from (1000) to (2000);
select is(pgpm._frontier_native('public.hd368'), '1200', 'LIVENESS: the walk starts at the operator''s cell');
update pgpm.config set obtain_retry_after = clock_timestamp() + interval '1 hour'
 where parent_table in ('public.hd368'::regclass, 'public.hh368'::regclass);
call pgpm.maintain_obtain('public.hh368', null) \gset h368_
select ok(exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                   where p.parent_table = 'public.hh368'::regclass and p.lo = '1000' and i.inhparent = 'public.hh368'::regclass),
  'LIVENESS: on the twin whose cell is a hole the armed back-off is bypassed and the hole is built');
call pgpm.maintain_obtain('public.hd368', null) \gset d368_
select is(:'d368_p_status'::text, 'obtained=0 obtain_backoff',
  'the operator''s cell counts as coverage, so the armed back-off is honoured');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.hd368'::regclass and action = 'skip_obtain'),
  'and nothing was deferred');

-- ==================== (E) a time grid under another session zone ====================
set timezone = 'America/New_York';
create table public.ht368 (ts timestamptz primary key, payload text);
insert into public.ht368 values (now() - interval '1 hour', 'x');
call pgpm.transmute('public.ht368', 'ts', interval '1 day', p_obtain => 4);
create temporary table cellt368 as
  select p.lo, p.hi, p.child_name, row_number() over (order by p.lo::timestamptz) as k from pgpm.part p
   where p.parent_table = 'public.ht368'::regclass and p.attached
     and p.lo::timestamptz > now();
select ok((select count(*) from cellt368) >= 3, 'LIVENESS: at least three forward day cells');
select format('drop table public.%I', child_name) from cellt368 where k in (1, 2, 3) \gexec
create table public.ht368_mine (like public.ht368 including all);
select format('alter table public.ht368 attach partition public.ht368_mine for values from (%L) to (%L)', lo, hi)
  from cellt368 where k = 2 \gexec
create temporary table markt368 as select coalesce(max(id), 0) as id from pgpm.log;
create temporary table madet368 (n int);
select lives_ok($$insert into madet368 select pgpm.obtain('public.ht368') as n$$,
  'obtain does not fail over the operator''s day');
select is((select array_agg(l.lo order by l.lo::timestamptz) from pgpm.log l
            where l.parent_table = 'public.ht368'::regclass and l.action = 'obtain' and l.id > (select id from markt368)),
  (select array_agg(lo order by k) from cellt368 where k in (1, 3)),
  'obtain built exactly the two days around the operator''s');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.ht368'::regclass and inhrelid = 'public.ht368_mine'::regclass)
          and not exists (select 1 from pgpm.part where child_oid = 'public.ht368_mine'::regclass::oid),
  'the operator''s day is still a partition of the table, recorded by no row');
reset timezone;

select * from finish();
