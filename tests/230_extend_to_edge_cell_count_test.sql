-- extend_to's p_max counts the forward edge's own cell when the walk will build it (issue #836).
--
-- THE BUG. p_max is documented as "how many NEW partitions one call may create, checked with a dry count
-- before any DDL runs". The dry count counted grid STEPS from the frontier's floor to the target's floor,
-- but the walk starts AT the frontier's floor and builds that cell too when nothing attached overlaps it,
-- so a call allowed p_max partitions created p_max + 1. A 1-second time grid with a lookahead of 0 has no
-- cell under now() a second after its last obtain.
--
-- THE CONTRACT.
--   PART A  edge cell missing, the target one step past it: p_max => 1 is refused up front, in p_max's
--           own words, and creates nothing.
--   PART B  the same call with p_max => 2, on a second table of the same shape, creates exactly two
--           partitions: the edge's cell and the next.
--   PART C  edge cell present (an id grid, whose edge cell holds max(id)): p_max => 1 one step past it
--           still creates exactly that one partition, so the edge is counted only when it is missing.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(11);

-- ==================== (A) the edge's own cell is missing: p_max => 1 refuses ====================
create table public.ex230 (id bigint, at timestamptz, primary key (id, at));
insert into public.ex230 values (1, now());
call pgpm.transmute('public.ex230', 'at', '1 second'::interval, p_obtain => 0);
-- part B's table, the same shape, built now so one sleep serves both
create table public.eb230 (id bigint, at timestamptz, primary key (id, at));
insert into public.eb230 values (1, now());
call pgpm.transmute('public.eb230', 'at', '1 second'::interval, p_obtain => 0);
select pg_sleep(1.2);   -- now() moves into a cell nothing has built (no obtain tick runs in this file)

create temporary table pre230 as
  select array_agg(lo order by lo::timestamptz) as los from pgpm.part where parent_table = 'public.ex230'::regclass;
create temporary table preb230 as
  select array_agg(lo order by lo::timestamptz) as los from pgpm.part where parent_table = 'public.eb230'::regclass;

select ok(not exists (select 1 from pgpm.part p where p.parent_table = 'public.ex230'::regclass and p.attached
                        and p.lo::timestamptz <= now() and p.hi::timestamptz > now()),
  'LIVENESS: the frontier''s own cell (the one now() falls in) is not built');

select throws_like(
  $$ select pgpm.extend_to('public.ex230', (now() + interval '1 second')::text, 1) $$,
  '%would need more than 1 new partitions%',
  'p_max => 1 is refused up front when the walk would build the edge''s cell and the next one');
select is((select array_agg(lo order by lo::timestamptz) from pgpm.part where parent_table = 'public.ex230'::regclass),
  (select los from pre230), 'the refused call created nothing');

-- ==================== (B) p_max => 2 builds exactly the edge's cell and the next ====================
create temporary table made230 as
  select pgpm.extend_to('public.eb230', (now() + interval '1 second')::text, 2) as n,
         pgpm._ts_text(date_trunc('second', now())) as edge_lo,
         pgpm._ts_text(date_trunc('second', now()) + interval '1 second') as next_lo;

select ok(not exists (select 1 from unnest((select los from preb230)) l where l::timestamptz >= (select edge_lo from made230)::timestamptz),
  'LIVENESS: neither the edge''s cell nor the next existed before the call');
select is((select n from made230), 2, 'p_max => 2 reports two partitions created');
select is((select array_agg(p.lo order by p.lo::timestamptz) from pgpm.part p
            where p.parent_table = 'public.eb230'::regclass and not (p.lo = any ((select los from preb230)::text[]))),
  array[(select edge_lo from made230), (select next_lo from made230)],
  'exactly the edge''s cell and the next one were built');

-- ==================== (C) the edge's cell exists: only the steps past it count ====================
create table public.ei230 (id bigint primary key, body text);
insert into public.ei230 values (5, 'a'), (6, 'b');
call pgpm.transmute('public.ei230', 'id', 100::bigint, p_obtain => 1);
insert into public.ei230 values (150, 'edge');   -- the frontier, inside a built cell

create temporary table prei230 as
  select array_agg(lo order by lo::numeric) as los from pgpm.part where parent_table = 'public.ei230'::regclass;
select ok(exists (select 1 from pgpm.part p where p.parent_table = 'public.ei230'::regclass and p.attached
                   and p.lo::numeric <= 150 and p.hi::numeric > 150),
  'LIVENESS: the id grid''s edge cell (holding max(id) 150) exists');
select ok(not exists (select 1 from pgpm.part p where p.parent_table = 'public.ei230'::regclass and p.hi::numeric > 250),
  'LIVENESS: the cell holding 250 does not');

create temporary table madei230 (n int, err text);
do $$
begin
  insert into madei230 values (pgpm.extend_to('public.ei230', '250', 1), null);
exception when others then
  insert into madei230 values (null, sqlerrm);
end $$;
select is((select err from madei230), null, 'p_max => 1 one step past a built edge is not refused');
select is((select n from madei230), 1, 'and it reports the one partition it created');
select is((select array_agg(p.lo order by p.lo::numeric) from pgpm.part p
            where p.parent_table = 'public.ei230'::regclass and not (p.lo = any ((select los from prei230)::text[]))),
  array['200'], 'and that partition is exactly [200, 300)');

select * from finish();
