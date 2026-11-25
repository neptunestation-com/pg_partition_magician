-- extend_to's p_max counts the partitions the call would build, not the grid steps to the target (issue #1242).
--
-- THE BUG. p_max is documented as how many NEW partitions one call may create, checked before any is. The dry
-- count was the grid steps from the frontier's floor to the target's: on an id grid the frontier is max(id),
-- on a time grid now(), and the cells obtain's lookahead had already built above it counted as new. A call
-- needing two partitions behind a lookahead of three was refused under p_max => 3, "would need more than 3
-- new partitions". The count now walks the walk's own cells over the walk's one read of the attached rows
-- and counts the ones that read does not show built.
--
-- THE CONTRACT.
--   PART A  id grid, rows to 88, step 100, lookahead 3 (built to 400): reaching 550 takes [400,500) and
--           [500,600). p_max => 1 is refused in p_max's words and creates nothing; p_max => 2 creates exactly
--           those two; a repeat creates nothing and is not refused under p_max => 1.
--   PART B  time grid, step one day, lookahead 5: a value one day and an hour past the forward edge takes
--           exactly two partitions, and p_max => 2 creates exactly those.
--   PART C  the lock budget's projection (#591) counts the partitions left to build, not the cells left to
--           walk: behind a 20-cell lookahead, a call needing budget + 1 partitions is refused by the budget,
--           and the slots it projects are at least its per-partition cost times the partitions it had left.
--           A projection over cells (the step count's own shape) comes up short by the lookahead.
--
-- bench/extend_to_counts_new.sh runs this file against the mutations extend_to_counts_grid_steps (every
-- walked cell counted, built or not: parts A and B) and extend_to_projects_walked_cells (the budget projected
-- over the cells left in the walk: part C), so it is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(16);

-- extend_to's return as text, or the message it raised: a refusal where a build is due fails one assertion by
-- name instead of ending the file
create function pg_temp.ext403(p_parent regclass, p_value text, p_max int) returns text language plpgsql as $f$
begin
  return pgpm.extend_to(p_parent, p_value, p_max)::text;
exception when others then
  return sqlerrm;
end $f$;

-- ==================== (A) an id grid behind its lookahead ====================
create table public.ex403 (id bigint primary key, payload text);
insert into public.ex403 values (7, 'a'), (42, 'b'), (88, 'c');
call pgpm.transmute('public.ex403', 'id', 100, p_obtain => 3, p_paused => true);
create temporary table pre403 as
  select array_agg(lo order by lo::numeric) as los from pgpm.part where parent_table = 'public.ex403'::regclass;

select is((select los from pre403), array['0', '100', '200', '300'],
  'LIVENESS: the lookahead built the grid to 400, three cells past the frontier''s');
select is(pgpm._frontier_native('public.ex403'), '88', 'LIVENESS: the frontier is max(id), 88');

select throws_like($$ select pgpm.extend_to('public.ex403', '550', 1) $$,
  '%extend_to(ex403, 550) would need more than 1 new partitions to reach it%',
  'reaching 550 needs two new partitions, so p_max => 1 is refused in p_max''s words');
select is((select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = 'public.ex403'::regclass),
          (select los from pre403),
  'and the refused call created nothing');

select is(pg_temp.ext403('public.ex403', '550', 2), '2',
  'p_max => 2 is enough: the cells the lookahead built are not counted as new');
select is((select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = 'public.ex403'::regclass),
          array['0', '100', '200', '300', '400', '500'],
  'and the two it built are [400,500) and [500,600)');
select is(pg_temp.ext403('public.ex403', '550', 1), '0',
  'a repeat call creates nothing and is not refused under p_max => 1');

-- ==================== (B) a time grid behind its lookahead ====================
create table public.tx403 (id bigint, at timestamptz, primary key (id, at));
insert into public.tx403 values (1, now() - interval '1 hour');
call pgpm.transmute('public.tx403', 'at', '1 day'::interval, p_obtain => 5, p_paused => true);
create temporary table tpre403 as
  select array_agg(lo::timestamptz order by lo::timestamptz) as los, max(hi::timestamptz) as edge
    from pgpm.part where parent_table = 'public.tx403'::regclass;

select ok((select edge from tpre403) >= now() + interval '5 days',
  'LIVENESS: the lookahead built the grid at least five days past now()');
select is(pg_temp.ext403('public.tx403', ((select edge from tpre403) + interval '1 day 1 hour')::text, 2), '2',
  'one day and an hour past the forward edge, p_max => 2 is enough: two new partitions');
select is((select array_agg(lo::timestamptz order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.tx403'::regclass and lo::timestamptz >= (select edge from tpre403)),
          array[(select edge from tpre403), (select edge from tpre403) + interval '1 day'],
  'and they are the two cells from the forward edge');

-- ==================== (C) the lock budget projects the partitions left, not the cells ====================
create temporary table lb403 as
  select (current_setting('max_locks_per_transaction')::int
          * (current_setting('max_connections')::int + current_setting('max_prepared_transactions')::int)) / 2
         as slots;
create table public.lx403 (id bigint primary key, payload text);
insert into public.lx403 values (1, 'a'), (5, 'b');
call pgpm.transmute('public.lx403', 'id', 10, p_obtain => 20, p_paused => true);
create temporary table lpre403 as
  select array_agg(lo order by lo::numeric) as los, max(hi::numeric) as edge, count(*)::int as n
    from pgpm.part where parent_table = 'public.lx403'::regclass;
-- the partitions the call needs: budget + 1, which cannot fit at a slot apiece
create temporary table lneed403 as select (select slots from lb403) + 1 as n;

select ok((select edge from lpre403) >= 200,
  'LIVENESS: the lookahead built at least twenty cells past the frontier''s, all walked before the first new one');
select cmp_ok((select n from lneed403), '<', 10000,
  'LIVENESS: the partitions needed are fewer than the default p_max, so only the lock budget can refuse');

create temporary table lout403 (state text, msg text);
do $$
begin
  perform pgpm.extend_to('public.lx403',
    ((select edge from lpre403) + ((select n from lneed403) - 1) * 10 + 5)::text);
  insert into lout403 values ('returned', null);
exception when others then
  insert into lout403 values (sqlstate, sqlerrm);
end $$;

select alike((select msg from lout403),
  'pg_partition_magician: extend_to(lx403, %) would hold about % lock-table slots in its one transaction (about % per partition)%',
  'the far call is refused by the lock budget, in its own words');
select is((select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = 'public.lx403'::regclass),
          (select los from lpre403),
  'and created nothing');
select ok((select (m[1]::bigint) > 0 and (m[2]::bigint) > 0
             from lout403, regexp_match(msg, 'about (\d+) lock-table slots .* \(about (\d+) per partition\)') m),
  'LIVENESS: the refusal states its projection and its per-partition cost');
select cmp_ok(
  (select m[1]::bigint from lout403, regexp_match(msg, 'about (\d+) lock-table slots') m),
  '>=',
  (select m[1]::bigint * ((select n from lneed403) - 2)
     from lout403, regexp_match(msg, '\(about (\d+) per partition\)') m),
  'the projection holds every partition left to build at the per-partition cost, however many built cells it walked first');

select * from finish();
