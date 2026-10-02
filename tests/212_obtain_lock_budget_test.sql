-- Issue #786: obtain() builds its whole lookahead in ONE transaction (it is a function), and each
-- CREATE TABLE ... PARTITION OF holds its locks to that transaction's end. extend_to was given a lock
-- budget for exactly this in #591; obtain was not, and set_obtain bounds only the sign, so a lookahead
-- whose missing cells overflow the shared lock table made every tick die with 53200 `out of shared
-- memory`, roll back every cell it had built, log skip_obtain, and leave the grid exactly where it was.
--
-- The contract: obtain's lookahead is opportunistic (unlike extend_to's named target), so it STOPS rather
-- than refuses. One call builds the cells that fit in half the shared lock table, max_locks_per_transaction
-- x (max_connections + max_prepared_transactions), measured from what its first two partitions cost, and
-- leaves the rest to the next tick, which carries on from where this one stopped.
--
-- The fixture is sized from THIS server's settings rather than assumed stock: the lookahead asked for is
-- one cell per slot of the WHOLE table, which cannot fit in one transaction at even one slot a cell, so the
-- budget is certain to bite whatever a partition really costs. Each call builds only about half the table's
-- worth of partitions, which is a few hundred on stock settings and a couple of seconds a call.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(12);

create temporary table ob_budget as
  select (current_setting('max_locks_per_transaction')::int
          * (current_setting('max_connections')::int + current_setting('max_prepared_transactions')::int))
         as slots;

-- a primary key and a TOASTable column, so a partition costs several slots (the table, its TOAST table and
-- index, its key index), as an ordinary table's does
create table public.ob212 (id bigint primary key, payload text);
insert into public.ob212 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.ob212', 'id', 10::bigint, p_paused => false);

create temporary table ob_top0 as
  select max(hi::numeric) as hi from pgpm.part where parent_table = 'public.ob212'::regclass and attached;

-- ==================== (A) set_obtain accepts the lookahead; the ceiling is per tick, not per value ====
select lives_ok(
  format($$ select pgpm.set_obtain('public.ob212', %s) $$, (select slots from ob_budget)),
  'set_obtain accepts a lookahead larger than one transaction can build: later ticks build the rest');

-- ==================== (B) the obtain job's tick builds what fits and logs no failure ===============
create temporary table ob_tick1 (s text);
do $$ declare s text; begin call pgpm.maintain_obtain('public.ob212', s); insert into ob_tick1 values (s); end $$;
create temporary table ob_n1 as
  select substring(s from '^obtained=([0-9]+)')::int as n from ob_tick1;

select ok((select s from ob_tick1) ~ '^obtained=[0-9]+$',
  'LIVENESS: the obtain tick ran, and was neither paused nor backed off nor deferred');
select cmp_ok((select n from ob_n1), '>=', 2,
  'the tick advanced the grid: it built partitions, enough to have measured what one costs');
select cmp_ok((select n from ob_n1), '<', (select slots from ob_budget),
  'LIVENESS: and it stopped short of its lookahead, so the budget, not the lookahead, ended the tick');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.ob212'::regclass and action = 'skip_obtain'),
  0, 'the tick did not die exhausting the shared lock table: no skip_obtain was logged');
select is(
  (select array_agg(lo::numeric order by lo::numeric) from pgpm.part
    where parent_table = 'public.ob212'::regclass and attached and lo::numeric >= (select hi from ob_top0)),
  (select array_agg(g order by g)
     from generate_series((select hi from ob_top0), (select hi from ob_top0) + 10 * ((select n from ob_n1) - 1), 10) g),
  'what it built is the contiguous run of cells from the old forward edge, by lower bound, and nothing else');

-- ==================== (C) the next call carries on, holding no more than half the lock table =======
-- One transaction (a DO block is one), so the locks the call takes are still held when they are counted.
-- The count starts after a call that builds NOTHING (lookahead 0: the frontier's own cell exists) has run
-- in the same transaction, so what that call holds is held already: the frontier read's locks on every
-- partition that exists, which are not the creation loop's (#632 is their subject), and the call's own
-- fixed reads. What is left to count is what building the cells costs. Fast-path locks are excluded:
-- they live in the backend's own PGPROC, not in the shared table.
create temporary table ob_tick2 (idle int, made int, slots_taken int);
do $$
declare v_before int; v_idle int; v_made int;
begin
  perform pgpm.set_obtain('public.ob212', 0);
  v_idle := pgpm.obtain('public.ob212');
  perform pgpm.set_obtain('public.ob212', (select slots from ob_budget));
  select count(*) into v_before from pg_locks where pid = pg_backend_pid() and not fastpath;
  v_made := pgpm.obtain('public.ob212');
  insert into ob_tick2
    select v_idle, v_made, count(*)::int - v_before from pg_locks where pid = pg_backend_pid() and not fastpath;
end $$;

select is((select idle from ob_tick2), 0,
  'LIVENESS: the warm-up call built nothing, so the count below starts after it with no cell charged');
select cmp_ok((select made from ob_tick2), '>=', 2,
  'LIVENESS: the next call had cells left to build, and built them');
select cmp_ok((select slots_taken from ob_tick2), '>=', (select made from ob_tick2),
  'LIVENESS: every partition it created holds at least one shared lock-table slot to transaction end');
select cmp_ok((select slots_taken from ob_tick2), '<=', (select slots / 2 from ob_budget),
  'the call held no more than half of the shared lock table');
select cmp_ok((select (slots_taken + 3 * ceil(slots_taken::numeric / made))::int from ob_tick2), '>', (select slots / 2 from ob_budget),
  'LIVENESS: and it used that half, building what fits rather than a token few cells');
select is(
  (select array_agg(lo::numeric order by lo::numeric) from pgpm.part
    where parent_table = 'public.ob212'::regclass and attached and lo::numeric >= (select hi from ob_top0)),
  (select array_agg(g order by g)
     from generate_series((select hi from ob_top0),
                          (select hi from ob_top0) + 10 * ((select n from ob_n1) + (select made from ob_tick2) - 1), 10) g),
  'it carried on from where the tick stopped: one contiguous run from the old edge, with no gap and no overlap');

select * from finish();
