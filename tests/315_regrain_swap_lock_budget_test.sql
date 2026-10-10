-- Issue #1161: regrain_step's swap attaches EVERY fine child of the run in one transaction (the swap is atomic by
-- contract: detach the source, attach the copies, drop the source), and each ATTACH holds its locks to that
-- transaction's end in the lock table every backend shares. obtain (#786) and extend_to (#591) stop or refuse
-- before one call's partitions take more than half that table, max_locks_per_transaction x (max_connections +
-- max_prepared_transactions); the swap had no such bound, so a monolith of a few years regrained to '1 day'
-- copied every sub-range and then died 53200 `out of shared memory` at an ATTACH on every swap tick, the cursor
-- at hi and every copy kept: the run could never finish and filled the shared table on each attempt.
--
-- The contract: a run whose swap would attach more children than half the table holds at two slots a child
-- (each child's own lock and the lock on the bound CHECK the swap drops, the least any child costs) is refused
-- at its prepare tick and by set_regrain, before anything is copied; a run at that line is not. The aged prefix
-- a retention policy discards is not counted, since the copy skips it and the swap attaches nothing there. And
-- the swap itself measures what its second ATTACH cost and refuses, rolling back whole, when the run's children
-- at that cost (plus a charge for re-adding each incoming foreign key against every child) would hold more than
-- half: a table whose children cost more than the floor. An ordinary swap still swaps.
--
-- Every fixture is sized from THIS server's settings. The refused swaps are sized so their children would
-- really take more than half the table (outgoing keys cost a child two slots each, an incoming key about 1.2,
-- measured on PostgreSQL 15 and 18), and less than all of it, so a build without the budget swaps them, holding
-- more than half, rather than failing for a reason of its own.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(22);

create temporary table rs_budget as
  select slots, slots / 4 as cap
    from (select current_setting('max_locks_per_transaction')::bigint
                 * (current_setting('max_connections')::bigint + current_setting('max_prepared_transactions')::bigint)
                 as slots) s;
select slots, cap from rs_budget \gset

-- a monolith [0, :span) of a plain id table, frozen by a write past it, its sub-ranges 100 wide
create or replace function pg_temp.rs_monolith(p_rel text, p_span bigint, p_extra_cols text default '')
returns void language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, a text, b int not null default 1%s)', p_rel, p_extra_cols);
  execute format('insert into public.%I (id, a) values (0, %L), (%s, %L)', p_rel, 'first', p_span - 1, 'last');
end $$;

create or replace function pg_temp.rs_source(p_rel text) returns name language sql as $$
  select child_name from pgpm.part where parent_table = ('public.' || p_rel)::regclass and attached and lo = '0'
$$;

-- what a run of p_rel has left anywhere: the cursor, its not-yet-attached copies, its prepare log rows
create or replace function pg_temp.rs_run_state(p_rel text) returns text language sql as $$
  select format('cursor=%s copies=%s prepares=%s',
                coalesce((select regrain_cursor from pgpm.config where parent_table = ('public.' || p_rel)::regclass), 'null'),
                (select count(*) from pgpm.part where parent_table = ('public.' || p_rel)::regclass and not attached),
                (select count(*) from pgpm.log where parent_table = ('public.' || p_rel)::regclass and action = 'regrain_prepare'))
$$;

-- ==================== (A) one sub-range past the line: refused before anything is copied ====================
-- partition_step is half the monolith, so the monolith is two cells wide: the coarse child auto-regrain would
-- pick, which set_regrain asks about too
\o /dev/null
select pg_temp.rs_monolith('rs315_over', (:cap + 1) * 100);
\o
call pgpm.transmute('public.rs315_over', 'id', ((:cap + 1) * 50)::bigint, p_obtain => 2);
insert into public.rs315_over (id, a) values ((:cap + 1) * 100 + 1, 'frontier');
create temporary table rs_over_src as
  select child_name, child_oid from pgpm.part where parent_table = 'public.rs315_over'::regclass and attached and lo = '0';
select is((select hi from pgpm.part where parent_table = 'public.rs315_over'::regclass and attached and lo = '0'),
          ((:cap + 1) * 100)::text,
  'A LIVENESS: the monolith is [0, (cap + 1) x 100): cap + 1 sub-ranges of 100, and two partition steps wide');

select throws_like(
  format($$ select pgpm.regrain_step('public.rs315_over', %L, '100') $$, pg_temp.rs_source('rs315_over')),
  format('%%cannot regrain %s of rs315_over at target step 100 -- its swap would attach at least %s fine partitions in one transaction%%more than half the shared lock table''s %s (max_locks_per_transaction%%',
         pg_temp.rs_source('rs315_over'), :cap + 1, :slots),
  'A: the prepare tick refuses a run whose cap + 1 fine children would need more than half the shared lock table at two slots each, naming the knob');
select is(pg_temp.rs_run_state('rs315_over'), 'cursor=null copies=0 prepares=0',
  'A: and refuses before anything: no cursor, no copy, no prepare');
select is((select child_oid from pgpm.part where parent_table = 'public.rs315_over'::regclass and attached and lo = '0'),
          (select child_oid from rs_over_src),
  'A: the source is still the attached partition at lo 0, the same relation');
select throws_like($$ select pgpm.set_regrain('public.rs315_over', '100') $$,
  format('%%its swap would attach at least %s fine partitions%%', :cap + 1),
  'A: set_regrain refuses the same target for auto-regrain, by the same count');
select is((select regrain_to from pgpm.config where parent_table = 'public.rs315_over'::regclass), null,
  'A: and stores nothing');

-- ==================== (B) exactly at the line: set and prepared ==============================================
\o /dev/null
select pg_temp.rs_monolith('rs315_at', :cap * 100);
\o
call pgpm.transmute('public.rs315_at', 'id', (:cap * 50)::bigint, p_obtain => 2);
insert into public.rs315_at (id, a) values (:cap * 100 + 1, 'frontier');

select lives_ok($$ select pgpm.set_regrain('public.rs315_at', '100') $$,
  'B LIVENESS: set_regrain accepts a target whose cap fine children fit in half the table at two slots each');
select is(pgpm.regrain_step('public.rs315_at', pg_temp.rs_source('rs315_at'), '100'), 'prepared',
  'B LIVENESS: and the prepare tick prepares it, so A''s refusal is the line and not a refusal of everything');

-- ==================== (C) the aged prefix retention discards is not counted ===================================
-- partition_step P, a monolith [0, 4P) and retain P: the frontier at 4P + 1 puts the horizon at 3P, so the copy
-- skips [0, 3P) as aged and attaches only [3P, 4P), cap / 2 + 1 sub-ranges, while the whole monolith is
-- 2 cap + 4 of them, past the line
select (:cap / 2 + 1) * 100 as p_step \gset
\o /dev/null
select pg_temp.rs_monolith('rs315_aged', 4 * :p_step);
\o
call pgpm.transmute('public.rs315_aged', 'id', (:p_step)::bigint, p_obtain => 2, p_retain => (:p_step)::bigint);
insert into public.rs315_aged (id, a) values (4 * :p_step + 1, 'frontier');

select is((select hi from pgpm.part where parent_table = 'public.rs315_aged'::regclass and attached and lo = '0'),
          (4 * :p_step)::text,
  'C LIVENESS: the monolith is [0, 4P), so the whole of it is 2 cap + 4 sub-ranges of 100');
select cmp_ok((4 * :p_step / 100)::bigint, '>', :cap::bigint,
  'C LIVENESS: which is more than the line, so counting the aged prefix would refuse this run');
select is(pgpm.regrain_step('public.rs315_aged', pg_temp.rs_source('rs315_aged'), '100'), 'prepared',
  'C: the prepare tick counts only the sub-ranges above the retention horizon, and prepares it');

-- ==================== (D) a table whose children cost more than the floor: refused at the swap, measured ====
-- thirty outgoing foreign keys: each is re-pointed at the swap's ATTACH, two slots a key, so a child costs 62
-- slots where the floor charges two. slots / 100 children fit the floor easily and at 62 each take more than half.
create table public.rs315_ref (k int primary key);
insert into public.rs315_ref values (1);
\o /dev/null
select pg_temp.rs_monolith('rs315_ofk', (:slots / 100) * 100);
\o
\o /dev/null
select format('alter table public.rs315_ofk add constraint rs315_ofk_fk%s foreign key (b) references public.rs315_ref', g)
  from generate_series(1, 30) g \gexec
\o
call pgpm.transmute('public.rs315_ofk', 'id', ((:slots / 100) * 100)::bigint, p_obtain => 2);
insert into public.rs315_ofk (id, a) values ((:slots / 100) * 100 + 1, 'frontier');
\o /dev/null
select format('select pgpm.regrain_step(%L, pg_temp.rs_source(%L), %L)', 'public.rs315_ofk', 'rs315_ofk', '100')
  from generate_series(1, :slots / 100 + 1) \gexec
\o
create temporary table rs_ofk_copies as
  select child_name, child_oid from pgpm.part where parent_table = 'public.rs315_ofk'::regclass and not attached;

select is(
  (select array_agg(p.lo::numeric order by p.lo::numeric) from pgpm.part p join rs_ofk_copies c using (child_name)
    where p.parent_table = 'public.rs315_ofk'::regclass),
  (select array_agg(g::numeric order by g) from generate_series(0, (:slots / 100 - 1) * 100, 100) g),
  'D LIVENESS: the prepare tick let the run through, and every sub-range has its copy');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rs315_ofk'::regclass),
          ((:slots / 100) * 100)::text,
  'D LIVENESS: the cursor is at hi, so the next tick is the swap');
select throws_like(
  format($$ select pgpm.regrain_step('public.rs315_ofk', %L, '100') $$, pg_temp.rs_source('rs315_ofk')),
  format('%%cannot swap the regrain of %s of rs315_ofk at target step 100 -- attaching its %s fine partitions in one transaction would hold about %%more than half the shared lock table''s %s%%',
         pg_temp.rs_source('rs315_ofk'), :slots / 100, :slots),
  'D: the swap measures what a child costs and refuses a swap whose children would hold more than half the table');
select is(
  (select array_agg(p.child_oid order by p.child_oid) from pgpm.part p
    where p.parent_table = 'public.rs315_ofk'::regclass and not p.attached),
  (select array_agg(child_oid order by child_oid) from rs_ofk_copies),
  'D: and rolls back whole: every copy is still recorded, by identity, and none is attached');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rs315_ofk'::regclass and action in ('regrain', 'regrain_attach')),
  0, 'D: no attach and no swap was logged');

-- ==================== (E) incoming foreign keys are charged for their re-add after the attaches =============
-- twenty tables reference the parent; the swap suspends their keys and re-adds them against every partition
-- after the last ATTACH, about 1.2 slots a key a child (measured), so 3 slots / 128 children of two slots each
-- plus that take more than half of the table, though the ATTACHes alone take a few percent of it
\o /dev/null
select pg_temp.rs_monolith('rs315_ifk', (:slots * 3 / 128) * 100);
\o
\o /dev/null
select format('create table public.rs315_ifk_r%s (x bigint references public.rs315_ifk (id))', g)
  from generate_series(1, 20) g \gexec
\o
call pgpm.transmute('public.rs315_ifk', 'id', ((:slots * 3 / 128) * 100)::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
insert into public.rs315_ifk (id, a) values ((:slots * 3 / 128) * 100 + 1, 'frontier');
\o /dev/null
select pgpm.restore_incoming_fks('public.rs315_ifk');
\o
\o /dev/null
select format('select pgpm.regrain_step(%L, pg_temp.rs_source(%L), %L)', 'public.rs315_ifk', 'rs315_ifk', '100')
  from generate_series(1, :slots * 3 / 128 + 1) \gexec
\o

select is(
  (select count(*)::int from pgpm.dropped_fk where parent_table = 'public.rs315_ifk'::regclass and restored_at is not null),
  20, 'E LIVENESS: all twenty incoming keys are live, so the swap suspends and re-adds them');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rs315_ifk'::regclass),
          ((:slots * 3 / 128) * 100)::text,
  'E LIVENESS: every copy is made and the cursor is at hi, so the next tick is the swap');
select throws_like(
  format($$ select pgpm.regrain_step('public.rs315_ifk', %L, '100') $$, pg_temp.rs_source('rs315_ifk')),
  format('%%cannot swap the regrain of %s of rs315_ifk%%with what re-adding the incoming foreign keys costs%%', pg_temp.rs_source('rs315_ifk')),
  'E: the swap charges the re-add of each incoming key against every child, and refuses');
select is(
  (select count(*)::int from pgpm.dropped_fk where parent_table = 'public.rs315_ifk'::regclass and restored_at is not null)
  || '/' || (select count(*) from pgpm.part where parent_table = 'public.rs315_ifk'::regclass and not attached),
  '20/' || (:slots * 3 / 128),
  'E: and rolls back whole: all twenty keys are live again and every copy is still waiting to be attached');

-- ==================== (F) an ordinary swap still swaps ======================================================
\o /dev/null
select pg_temp.rs_monolith('rs315_small', 500);
\o
call pgpm.transmute('public.rs315_small', 'id', 500::bigint, p_obtain => 2);
insert into public.rs315_small (id, a) values (501, 'frontier');
\o /dev/null
select format('select pgpm.regrain_step(%L, pg_temp.rs_source(%L), %L)', 'public.rs315_small', 'rs315_small', '100')
  from generate_series(1, 6) \gexec
\o
select is(pgpm.regrain_step('public.rs315_small', pg_temp.rs_source('rs315_small'), '100'), 'swapped:5',
  'F: a five-child swap goes through the measured budget and swaps');
select is(
  (select array_agg(lo::numeric order by lo::numeric) from pgpm.part
    where parent_table = 'public.rs315_small'::regclass and attached and lo::numeric < 500),
  array[0, 100, 200, 300, 400]::numeric[],
  'F: and its five fine partitions are the attached ones below 500, by lower bound');

select * from finish();
