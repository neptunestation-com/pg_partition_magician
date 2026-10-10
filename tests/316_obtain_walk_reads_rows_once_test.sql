-- obtain's lookahead walk and extend_to's walk read the parent's attached rows once, not once per cell
-- (issue #1162).
--
-- THE BUG. Both walks asked pgpm._cell_attached of every grid cell, and each ask scanned every attached
-- pgpm.part row of the parent through plpgsql _native_gt (the bounds are native text, and pgpm.part's only
-- index is (parent_table, child_name)). A tick that built nothing did lookahead x partitions comparisons:
-- 81,204 _native_gt calls at lookahead 200 against 1,284,804 at 800, about 3 s at 1440, on every run of the
-- every-minute obtain job.
--
-- THE CONTRACT. A walk reads the rows once (pgpm._cell_walk_rows) and judges each cell against that read
-- (pgpm._cell_walk_step); only a cell the read does not show built, or one a row that is not built
-- overlaps, is asked of _cell_attached, so the hole-rebuild path (#908, #956) and its log rows are what
-- they were.
--   PART A  the issue's contract: a no-op obtain at 4x the lookahead (and so 4x the partitions) does under
--           8x the _native_gt comparisons (linear is about 4x, the per-cell scan about 16x). Counted from
--           pg_stat_xact_user_functions inside one transaction (track_functions is instrumentation only).
--   PART B  obtain still forgets and rebuilds what the one read shows is not built: two cells dropped by
--           hand ([30, 40) and [70, 80)), one DETACHed by hand ([50, 60)), and a dead row ([40, 50), a
--           relation that no longer exists) recorded over a cell whose own partition IS built. obtain
--           rebuilds exactly the three holes, forgets exactly the four dead rows with their exact actions,
--           and leaves the built cells it walked past, the doubly-recorded [40, 50) included, as they were.
--   PART C  the same contract for extend_to's walk over a built range (it builds nothing and returns 0).
--   PART D  extend_to's walk forgets and rebuilds too: [60, 70) dropped by hand and a dead row over the
--           built [20, 30); extend_to past the grid rebuilds the one hole and builds the two new cells.
-- The fixtures are asymmetric on purpose: three holes and four dead rows in B against one hole and two
-- dead rows in D, and in each a dead row over a BUILT cell, so a walk that trusted the read's "built" over
-- a dead row (skipping the forget) or never trusted it (a rebuild of a live cell) cannot pass.
create extension if not exists pgtap;
set client_min_messages = warning;
set track_functions = 'pl';

select plan(32);

-- ==================== (A) a no-op obtain is linear in the lookahead ====================
create table public.wa316 (id bigint primary key);
create table public.wb316 (id bigint primary key);
insert into public.wa316 values (3);
insert into public.wb316 values (7);
call pgpm.transmute('public.wa316', 'id', 10::bigint, p_obtain => 100);
call pgpm.transmute('public.wb316', 'id', 10::bigint, p_obtain => 400);

select is((select max(hi::numeric) from (select hi from pgpm.part where parent_table = 'public.wa316'::regclass and attached) x),
  1010::numeric, 'LIVENESS: the small grid is built to its lookahead, [1000, 1010) its top');
select is((select max(hi::numeric) from (select hi from pgpm.part where parent_table = 'public.wb316'::regclass and attached) x),
  4010::numeric, 'LIVENESS: the large grid is built to its lookahead, [4000, 4010) its top');

create temporary table calls316 (step text, tab text, made int, calls bigint);
do $$
declare c0 bigint; m int;
  counted constant text := $q$select coalesce(sum(calls), 0) from pg_stat_xact_user_functions
                              where schemaname = 'pgpm' and funcname = '_native_gt'$q$;
begin
  execute counted into c0;
  m := pgpm.obtain('public.wa316');
  insert into calls316 select 'obtain', 'a', m, (select coalesce(sum(calls), 0) from pg_stat_xact_user_functions
                                                   where schemaname = 'pgpm' and funcname = '_native_gt') - c0;
  execute counted into c0;
  m := pgpm.obtain('public.wb316');
  insert into calls316 select 'obtain', 'b', m, (select coalesce(sum(calls), 0) from pg_stat_xact_user_functions
                                                   where schemaname = 'pgpm' and funcname = '_native_gt') - c0;
  -- (C) extend_to over the whole built grid, its top cell named
  execute counted into c0;
  m := pgpm.extend_to('public.wa316', '1005');
  insert into calls316 select 'extend_to', 'a', m, (select coalesce(sum(calls), 0) from pg_stat_xact_user_functions
                                                      where schemaname = 'pgpm' and funcname = '_native_gt') - c0;
  execute counted into c0;
  m := pgpm.extend_to('public.wb316', '4005');
  insert into calls316 select 'extend_to', 'b', m, (select coalesce(sum(calls), 0) from pg_stat_xact_user_functions
                                                      where schemaname = 'pgpm' and funcname = '_native_gt') - c0;
end $$;

select is((select array_agg(made order by tab) from calls316 where step = 'obtain'), array[0, 0],
  'LIVENESS: both counted obtains were no-op ticks (the grids were already built)');
select ok((select calls from calls316 where step = 'obtain' and tab = 'a') >= 101,
  'LIVENESS: the counter sees obtain''s comparisons (at least one per cell of the small grid''s walk)');
select cmp_ok((select calls from calls316 where step = 'obtain' and tab = 'b')::numeric
              / (select calls from calls316 where step = 'obtain' and tab = 'a'), '<', 8::numeric,
  'A: a no-op obtain at 4x the lookahead does under 8x the comparisons (linear is about 4x, per-cell scans about 16x)');

-- ==================== (C) extend_to's walk over a built range is linear too ====================
select is((select array_agg(made order by tab) from calls316 where step = 'extend_to'), array[0, 0],
  'LIVENESS: both counted extend_to calls walked a built range and built nothing');
select ok((select calls from calls316 where step = 'extend_to' and tab = 'a') >= 101,
  'LIVENESS: the counter sees extend_to''s comparisons (at least one per cell of the small walk)');
select cmp_ok((select calls from calls316 where step = 'extend_to' and tab = 'b')::numeric
              / (select calls from calls316 where step = 'extend_to' and tab = 'a'), '<', 8::numeric,
  'C: extend_to over 4x the built cells does under 8x the comparisons');
select diag(format('no-op _native_gt calls: obtain %s / %s, extend_to %s / %s (lookahead 100 / 400)',
  (select calls from calls316 where step = 'obtain' and tab = 'a'), (select calls from calls316 where step = 'obtain' and tab = 'b'),
  (select calls from calls316 where step = 'extend_to' and tab = 'a'), (select calls from calls316 where step = 'extend_to' and tab = 'b')));

-- ==================== (B) obtain forgets and rebuilds what the one read shows is not built ====================
create table public.hb316 (id bigint primary key, payload text);
insert into public.hb316 values (1, 'a'), (2, 'b');
call pgpm.transmute('public.hb316', 'id', 10::bigint, p_obtain => 8);

create temporary table cells316 as
  select p.lo, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.hb316'::regclass and p.attached;
select is((select array_agg(c.lo order by c.lo::numeric) from cells316 c
            where exists (select 1 from pg_inherits i where i.inhparent = 'public.hb316'::regclass and i.inhrelid = c.child_oid)),
  array['0', '10', '20', '30', '40', '50', '60', '70', '80'],
  'LIVENESS: transmute built the cells [0, 10) to [80, 90) as partitions of the table');

-- two cells dropped by hand, one detached by hand
select format('drop table public.%I', child_name) from cells316 where lo in ('30', '70') \gexec
select format('alter table public.hb316 detach partition public.%I', child_name) from cells316 where lo = '50' \gexec
-- a dead row over the BUILT [40, 50): its relation is gone, the cell's own partition is not
create table public.ghost316b ();
select 'public.ghost316b'::regclass::oid as ghost_b \gset
drop table public.ghost316b;
insert into pgpm.part (parent_table, child_name, lo, hi, attached, child_oid)
values ('public.hb316'::regclass, 'ghost316b', '40', '50', true, :'ghost_b'::oid);

select is((select array_agg(lo order by lo::numeric, child_name) from pgpm.part
            where parent_table = 'public.hb316'::regclass and attached and lo in ('30', '40', '50', '70')),
  array['30', '40', '40', '50', '70'],
  'LIVENESS: every dead row is still recorded attached, two over [40, 50) (the state the walk must see through)');
select ok(not exists (select 1 from pg_class c join cells316 x on x.child_oid = c.oid where x.lo in ('30', '70'))
          and not exists (select 1 from pg_inherits i join cells316 x on x.child_oid = i.inhrelid
                           where i.inhparent = 'public.hb316'::regclass and x.lo = '50')
          and exists (select 1 from pg_class c join cells316 x on x.child_oid = c.oid where x.lo = '50'),
  'LIVENESS: [30, 40) and [70, 80) are gone, [50, 60) stands outside the table');

create temporary table mark316b as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.obtain('public.hb316'), 3, 'B: obtain builds exactly three cells');

select is((select array_agg(p.lo order by p.lo::numeric) from pgpm.part p
            where p.parent_table = 'public.hb316'::regclass and p.attached
              and not exists (select 1 from cells316 c where c.child_oid = p.child_oid)),
  array['30', '50', '70'], 'B: the three new partitions are the three holes, [30, 40), [50, 60) and [70, 80)');
select ok((select bool_and(exists (select 1 from pg_inherits i where i.inhparent = 'public.hb316'::regclass and i.inhrelid = p.child_oid))
             from pgpm.part p where p.parent_table = 'public.hb316'::regclass and p.attached and p.lo in ('30', '50', '70')),
  'B: each rebuilt cell is recorded by the oid of a partition of the table');
select is((select array_agg(l.action || ' ' || l.lo order by l.lo::numeric, l.action) from pgpm.log l
            where l.id > (select id from mark316b) and l.parent_table = 'public.hb316'::regclass
              and l.action in ('forget_dropped_partition', 'forget_detached_partition')),
  array['forget_dropped_partition 30', 'forget_dropped_partition 40', 'forget_detached_partition 50',
        'forget_dropped_partition 70'],
  'B: exactly the four dead rows are forgotten, each logged by what became of its relation');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.hb316'::regclass and child_name = 'ghost316b'),
  'B: the dead row over the built [40, 50) is forgotten');
select is((select array_agg(c.lo order by c.lo::numeric) from cells316 c
            where exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                           where p.parent_table = 'public.hb316'::regclass and p.attached and p.child_oid = c.child_oid
                             and i.inhparent = 'public.hb316'::regclass)),
  array['0', '10', '20', '40', '60', '80'],
  'B: the built cells keep their partitions, [40, 50) included');
select is((select count(*)::int from pgpm.part p where p.parent_table = 'public.hb316'::regclass and p.attached and p.lo = '40'),
  1, 'B: [40, 50) is recorded once, by its own partition');
select ok((select relname from pg_class c join cells316 x on x.child_oid = c.oid where x.lo = '50') is not null
          and not exists (select 1 from pg_inherits i join cells316 x on x.child_oid = i.inhrelid where x.lo = '50'),
  'B: the hand-detached table is left standing outside the table');
select is(pgpm.obtain('public.hb316'), 0, 'B: a second obtain finds nothing to build');
select lives_ok($$insert into public.hb316 values (35, 'thirty-five'), (55, 'fifty-five'), (75, 'seventy-five')$$,
  'B: writes into all three rebuilt cells land');
-- taken back out, so the id frontier (max(id)) stays at 2 and D's walk starts from [0, 10) again
delete from public.hb316 where id > 2;

-- ==================== (D) extend_to's walk forgets and rebuilds too ====================
create temporary table cells316d as
  select p.lo, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.hb316'::regclass and p.attached;
select format('drop table public.%I', child_name) from cells316d where lo = '60' \gexec
create table public.ghost316d ();
select 'public.ghost316d'::regclass::oid as ghost_d \gset
drop table public.ghost316d;
insert into pgpm.part (parent_table, child_name, lo, hi, attached, child_oid)
values ('public.hb316'::regclass, 'ghost316d', '20', '30', true, :'ghost_d'::oid);
select ok(not exists (select 1 from pg_class c join cells316d x on x.child_oid = c.oid where x.lo = '60')
          and (select count(*) from pgpm.part where parent_table = 'public.hb316'::regclass and attached and lo = '20') = 2,
  'LIVENESS: [60, 70) is gone, and a dead row is recorded over the built [20, 30)');

create temporary table mark316d as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.extend_to('public.hb316', '105'), 3, 'D: extend_to builds exactly three cells');
select is((select array_agg(p.lo order by p.lo::numeric) from pgpm.part p
            where p.parent_table = 'public.hb316'::regclass and p.attached
              and not exists (select 1 from cells316d c where c.child_oid = p.child_oid)),
  array['60', '90', '100'], 'D: the new partitions are the hole [60, 70) and the two cells past the grid');
select is((select array_agg(l.action || ' ' || l.lo order by l.lo::numeric) from pgpm.log l
            where l.id > (select id from mark316d) and l.parent_table = 'public.hb316'::regclass
              and l.action in ('forget_dropped_partition', 'forget_detached_partition')),
  array['forget_dropped_partition 20', 'forget_dropped_partition 60'],
  'D: exactly the two dead rows are forgotten');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.hb316'::regclass and child_name = 'ghost316d'),
  'D: the dead row over the built [20, 30) is forgotten');
select is((select c.child_oid from cells316d c where c.lo = '20' and c.child_name <> 'ghost316d'),
  (select p.child_oid from pgpm.part p where p.parent_table = 'public.hb316'::regclass and p.attached and p.lo = '20'),
  'D: [20, 30) keeps its own partition');
select lives_ok($$insert into public.hb316 values (65, 'sixty-five'), (95, 'ninety-five'), (105, 'one hundred five')$$,
  'D: writes into the rebuilt cell and both new cells land');

-- ==================== (E) a time grid takes the same walk ====================
-- the read's timestamptz order and the walk's comparisons in the time kinds' native type. now() is the
-- frontier, so a day boundary passing mid-test may add a top cell; nothing here depends on it not doing so
create table public.ht316 (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.ht316 values (1, now());
call pgpm.transmute('public.ht316', 'ts', '1 day'::interval, p_obtain => 6);
create temporary table cells316e as
  select p.lo, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.ht316'::regclass and p.attached;
create temporary table hole316e as
  select c.lo, c.child_oid from cells316e c order by c.lo::timestamptz desc offset 2 limit 1;
select ok((select count(*) from cells316e) >= 7
          and exists (select 1 from hole316e h join pg_inherits i on i.inhrelid = h.child_oid
                       where i.inhparent = 'public.ht316'::regclass),
  'LIVENESS: the time grid is built, its third cell from the top a partition of the table');
select format('drop table public.%I', c.child_name) from cells316e c join hole316e h on h.child_oid = c.child_oid \gexec
select cmp_ok(pgpm.obtain('public.ht316'), '>=', 1, 'E: obtain builds on the time grid');
select ok(exists (select 1 from pgpm.part p join hole316e h on h.lo = p.lo join pg_inherits i on i.inhrelid = p.child_oid
                   where p.parent_table = 'public.ht316'::regclass and p.attached and i.inhparent = 'public.ht316'::regclass
                     and p.child_oid <> h.child_oid),
  'E: the dropped cell is rebuilt as a new partition of the table');
select is((select count(*)::int from cells316e c
            where c.child_oid <> (select child_oid from hole316e)
              and exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                           where p.parent_table = 'public.ht316'::regclass and p.attached and p.child_oid = c.child_oid
                             and i.inhparent = 'public.ht316'::regclass)),
  (select count(*)::int from cells316e) - 1, 'E: every other cell keeps its own partition');

select * from finish();
