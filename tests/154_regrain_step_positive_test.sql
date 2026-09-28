-- Issue #588: a zero or negative regrain target step is refused, at call time and by every entry point.
--
-- set_regrain refused only a target COARSER than partition_step (#341) and one whose names are too long
-- (#510). A zero or negative step is "finer" than any partition_step, so it was accepted, and it arms
-- auto-regrain with a step no tick can use: '0' divides by zero in _grid_floor (skip_regrain on every
-- tick, forever), and '-100' makes regrain_step's 'nosubdiv' test (hi > lo + step) trivially true, mint
-- a fine child with inverted bounds and walk the cursor BELOW lo, so the janitor reads the capture as
-- orphaned and every tick churns prepare / orphan / restart with the capture trigger left on the source.
-- pgpm.regrain() with a negative step spun toward its 10,000,000-iteration limit in one transaction.
-- The reference promises "enabling it is always safe" and that a target which would wedge every tick is
-- refused at call time. The fix refuses a step that does not move the grid forward (grid_next(step,
-- anchor) must be past anchor), in set_regrain and in regrain_step, which regrain(), regrain_history()
-- and maintain all go through.
--
-- Every refusal is pinned to its message (throws_like), paired with a LIVENESS witness that the same
-- entry point accepts a valid finer step on the same table, and the state a refused call must leave is
-- an asymmetric one (a VALID target already set, not null) so "nothing happened" cannot pass for it.
create extension if not exists pgtap;
select plan(15);

create table public.zk (id bigint primary key, payload text);
insert into public.zk select g, 'x' from generate_series(1, 2000) g;            -- monolith [0, 3000)
call pgpm.transmute('public.zk', 'id', 1000, p_paused => false);
insert into public.zk values (20000, 'frontier');                                -- freezes the monolith
select is((select child_name from pgpm.part where parent_table = 'public.zk'::regclass and attached
            and lo = '0' and hi = '3000'),
          'zk_p0000000000000000000_to_0000000000000003000',
  'LIVENESS: the monolith [0, 3000) is attached and frozen behind the frontier');

-- set_regrain on an id grid
select lives_ok($$ select pgpm.set_regrain('public.zk', '100') $$,
  'LIVENESS: set_regrain accepts a valid finer id step (100)');
select throws_like($$ select pgpm.set_regrain('public.zk', '0') $$,
  'pg_partition_magician: regrain target step 0 for zk is not positive%',
  'set_regrain refuses a zero id step');
select throws_like($$ select pgpm.set_regrain('public.zk', '-100') $$,
  'pg_partition_magician: regrain target step -100 for zk is not positive%',
  'set_regrain refuses a negative id step');
select is((select regrain_to from pgpm.config where parent_table = 'public.zk'::regclass), '100',
  'the refused calls left the valid target in place');
select lives_ok($$ select pgpm.set_regrain('public.zk', null) $$, 'fixture: auto-regrain off again');

-- the operator-driven entry points
select throws_like($$ select pgpm.regrain_step('public.zk', 'zk_p0000000000000000000_to_0000000000000003000', '0') $$,
  'pg_partition_magician: regrain target step 0 for zk is not positive%',
  'regrain_step refuses a zero step (it used to divide by zero)');
create function pg_temp.try_regrain(p_step text) returns text language plpgsql as $f$
begin
  perform pgpm.regrain('public.zk', 'zk_p0000000000000000000_to_0000000000000003000', p_step);
  return 'accepted';
exception
  when query_canceled then return 'spun until statement_timeout';
  when others then return 'refused: ' || sqlerrm;
end $f$;
set statement_timeout = '5s';
select alike(pg_temp.try_regrain('-100'), 'refused: pg_partition_magician: regrain target step -100 for zk is not positive%',
  'regrain() refuses a negative step instead of spinning toward its iteration limit');
select alike(pg_temp.try_regrain('0'), 'refused: pg_partition_magician: regrain target step 0 for zk is not positive%',
  'regrain() refuses a zero step');
reset statement_timeout;
select is((select string_agg(child_name || ' [' || lo || ',' || hi || ')', ', ') from pgpm.part
            where parent_table = 'public.zk'::regclass and not attached), null,
  'the refusals minted no fine child');
select is(pgpm.regrain('public.zk', 'zk_p0000000000000000000_to_0000000000000003000', '500'), 6,
  'LIVENESS: the same child regrains at a positive step, into six fine partitions');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.zk'::regclass and attached and lo::numeric < 3000),
          array['0-500', '500-1000', '1000-1500', '1500-2000', '2000-2500', '2500-3000'],
  'LIVENESS: and those are exactly the six 500-wide cells of [0, 3000)');

-- set_regrain on a time grid: a zero interval and a negative calendar step
create table public.tk (ts timestamptz primary key, payload text);
insert into public.tk values ('2020-01-15', 'a'), ('2020-03-15', 'b');
call pgpm.transmute('public.tk', 'ts', interval '1 month');
select lives_ok($$ select pgpm.set_regrain('public.tk', '1 day') $$,
  'LIVENESS: set_regrain accepts a valid finer time step (1 day)');
select throws_like($$ select pgpm.set_regrain('public.tk', '0 days') $$,
  'pg_partition_magician: regrain target step 0 days for tk is not positive%',
  'set_regrain refuses a zero interval');
select throws_like($$ select pgpm.set_regrain('public.tk', '-1 month') $$,
  'pg_partition_magician: regrain target step -1 month for tk is not positive%',
  'set_regrain refuses a negative calendar step');

select * from finish();
