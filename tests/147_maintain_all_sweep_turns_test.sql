-- Issue #579: maintain_all's parents share one statement_timeout clock, so the sweep must not visit them
-- in a fixed order that lets the front of the list spend that clock on every tick.
--
-- THE DEFECT. The scheduled tick is ONE top-level statement, `call pgpm.maintain_all()`, and
-- statement_timeout runs from the start of the top-level statement, not from each COMMIT inside it, so
-- every parent in a sweep runs on the same clock. The query_canceled that ends a sweep escapes
-- maintain()'s `when others` handlers (PostgreSQL does not let `others` catch it). The sweep visited the
-- parents `order by parent_table` every tick, so a parent with a backlog near the front of the list, each
-- of whose ticks is sized the way docs/reference.md says (one maintain() within the maintaining session's
-- statement_timeout), used up the clock tick after tick and every parent behind it was cancelled on every
-- tick: never archived, never retired, although its own maintain() fits the timeout comfortably.
--
-- THE FIX orders the sweep by config.sweep_turn_at, oldest first: a parent's turn is stamped when its
-- maintain() returns, so a parent cut short keeps its old stamp and leads the next sweep; and the first
-- parent of a sweep is stamped before it starts, so that a parent whose own tick overruns the timeout
-- (it had the whole clock and still did not finish) cannot lead, and be cancelled in, every sweep.
--
-- Two scenarios, one per half of the rule, each asserted tick by tick so the order is shown by WHICH
-- parent did its work in which tick rather than by a total:
--   1. A backlog ahead of a tail. A (lower oid) has a backlog of three archive chunks; B (higher oid)
--      needs one chunk, then retires its aged partition.
--   2. A parent that overruns on its own. P (lower oid) has an archive chunk that never fits the
--      timeout; Q (higher oid) needs nothing but a drop.
--
-- WHERE THE CLOCK CUTS IS SET BY ORDER, NOT BY SPEED. The archive function returns at once for the
-- first parent to enter it in a tick and sleeps far past the statement_timeout for every later one (and
-- for P always), so the timeout lands inside the second parent to enter it, whatever the runner's load.
-- Which parent that is depends only on the sweep's order, the thing under test. This used to be
-- one-second chunks against a 1.9 s timeout, so that one chunk fitted and two did not, which left the
-- sweep's own work a margin (0.5 s, then 0.9 s) to reach the second parent before the clock ran out; a
-- loaded runner spent both, the clock cut A short in tick 1 before B was entered, and tick 2 then led
-- with A and failed assertions that are about B (PR #1225's PG18/dbdev job). The clock now only has to
-- cover one ordinary maintain() and the paused parents ahead of it, a tenth of a second here, against 4 s.
-- Each archive function counts its calls in a SEQUENCE, which a cancellation does not roll back, so
-- "cut short" is proven (the function was entered, no chunk was recorded) rather than inferred from
-- nothing having happened. A count is read with is_called: a sequence never called reports last_value 1,
-- the same as one called once, which let "tick 1 entered B's archive function" pass in the run above
-- although B was never entered.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(20);

create schema s147;
create sequence s147.calls_a;
create sequence s147.calls_b;
create sequence s147.calls_p;
-- The oid of the first parent to enter the archive function in the current tick, reset before each tick.
-- A sequence, like the counters, so that neither a commit nor a cancellation moves it.
create sequence s147.first_in_tick minvalue 0;
-- How many times a counter's archive function was entered: 0 for a sequence never called.
create function s147.calls(p_seq regclass) returns int language plpgsql as $$
declare v int;
begin
  execute format('select case when is_called then last_value::int else 0 end from %s', p_seq) into v;
  return v;
end $$;
create function s147.chunk(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_first bigint;
begin
  case p_parent
    when 'public.sw_a'::regclass then perform nextval('s147.calls_a');
    when 'public.sw_b'::regclass then perform nextval('s147.calls_b');
    when 'public.sw_p'::regclass then perform nextval('s147.calls_p');
  end case;
  select case when is_called then last_value end into v_first from s147.first_in_tick;
  if v_first is null then
    v_first := p_parent::oid::bigint;
    perform setval('s147.first_in_tick', v_first, true);
  end if;
  -- the tick's first parent in returns at once; a later one, and P always, is still here when the clock runs out
  if p_parent = 'public.sw_p'::regclass or v_first <> p_parent::oid::bigint then
    perform pg_sleep(60);
  end if;
  v.covered_hi := p_hi; v.rows_archived := 0;
  return v;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- Scenario 1: A's backlog ahead of B
-- ---------------------------------------------------------------------------------------------------
create table public.sw_a (id bigint generated by default as identity primary key, payload text);
create table public.sw_b (id bigint generated by default as identity primary key, payload text);
create table public.sw_p (id bigint generated by default as identity primary key, payload text);
create table public.sw_q (id bigint generated by default as identity primary key, payload text);
-- all four exist before the archive function (which names them) is first called; P and Q are
-- transmuted only when scenario 2 begins, so that they are new to the sweep then

insert into public.sw_a (payload) select 'a' from generate_series(1, 3);
call pgpm.transmute('public.sw_a', 'id', 1000, p_retain => 19000, p_paused => false);
insert into public.sw_a (id, payload) values (20000, 'frontier');
select pgpm.set_archive_fn('public.sw_a', 's147.chunk(regclass,name,text,text)'::regprocedure);
-- one row per chunk, so A's three rows are a backlog of three chunks, one per tick
update pgpm.config set archive_byte_budget = 1 where parent_table = 'public.sw_a'::regclass;

insert into public.sw_b (payload) select 'b' from generate_series(1, 2);
call pgpm.transmute('public.sw_b', 'id', 1000, p_retain => 19000, p_paused => false);
insert into public.sw_b (id, payload) values (20000, 'frontier');
select pgpm.set_archive_fn('public.sw_b', 's147.chunk(regclass,name,text,text)'::regprocedure);
select child_name as bmono from pgpm.part where parent_table = 'public.sw_b'::regclass and lo = '0' \gset
select child_name as blive from pgpm.part
 where parent_table = 'public.sw_b'::regclass and attached and lo::bigint <= 20000 and hi::bigint > 20000 \gset

select ok('public.sw_a'::regclass::oid < 'public.sw_b'::regclass::oid,
  'LIVENESS: A precedes B in the fixed order the sweep used to follow');

select setval('s147.first_in_tick', 0, false);
set statement_timeout = '4s';
\set ON_ERROR_STOP 0
call pgpm.maintain_all();
\set ON_ERROR_STOP 1
reset statement_timeout;

select is((select count(*)::int from pgpm.archive_ledger where parent_table = 'public.sw_a'::regclass), 1,
  'tick 1: A archived one chunk');
select is(s147.calls('s147.calls_b'), 1,
  'LIVENESS: tick 1 entered B''s archive function');
select ok(not exists (select 1 from pgpm.archive_ledger where parent_table = 'public.sw_b'::regclass),
  'LIVENESS: and the shared clock cut B short there (the starving the fix is about happened)');

select setval('s147.first_in_tick', 0, false);
set statement_timeout = '4s';
\set ON_ERROR_STOP 0
call pgpm.maintain_all();
\set ON_ERROR_STOP 1
reset statement_timeout;

select is((select string_agg(child_name, ',') from pgpm.archive_ledger where parent_table = 'public.sw_b'::regclass),
  :'bmono',
  'tick 2: B, cut short last tick, went first and archived its aged partition');
select is((select string_agg(lo, ',' order by id) from pgpm.log
            where parent_table = 'public.sw_b'::regclass and action = 'retain_drop'),
  '0',
  'and retired it');
select is((select string_agg(t.id || '->' || c.relname, ' ' order by t.id)
             from public.sw_b t join pg_class c on c.oid = t.tableoid),
  '20000->' || :'blive',
  'and only it: B''s live partition keeps its frontier row');
select is(s147.calls('s147.calls_a'), 2,
  'LIVENESS: tick 2 still reached A');
select is((select count(*)::int from pgpm.archive_ledger where parent_table = 'public.sw_a'::regclass), 1,
  'and it was A that the clock cut short this time');

select setval('s147.first_in_tick', 0, false);
set statement_timeout = '4s';
\set ON_ERROR_STOP 0
call pgpm.maintain_all();
\set ON_ERROR_STOP 1
reset statement_timeout;

select is((select count(*)::int from pgpm.archive_ledger where parent_table = 'public.sw_a'::regclass), 2,
  'tick 3: A, cut short last tick, went first and archived its next chunk');
select is(s147.calls('s147.calls_a'), 3,
  'LIVENESS: A''s archive function was entered once more, for that chunk');

-- ---------------------------------------------------------------------------------------------------
-- Scenario 2: P overruns the timeout on its own, ahead of Q
-- ---------------------------------------------------------------------------------------------------
select pgpm.pause('public.sw_a');
select pgpm.pause('public.sw_b');

insert into public.sw_p (payload) select 'p' from generate_series(1, 3);
call pgpm.transmute('public.sw_p', 'id', 1000, p_retain => 19000, p_paused => false);
insert into public.sw_p (id, payload) values (20000, 'frontier');
select pgpm.set_archive_fn('public.sw_p', 's147.chunk(regclass,name,text,text)'::regprocedure);

-- Q archives nothing (no archive_fn), so its aged partition drops as soon as it is write-blocked
insert into public.sw_q (payload) select 'q' from generate_series(1, 4);
call pgpm.transmute('public.sw_q', 'id', 1000, p_retain => 19000, p_paused => false);
insert into public.sw_q (id, payload) values (20000, 'frontier');
select child_name as qold from pgpm.part where parent_table = 'public.sw_q'::regclass and lo = '0' \gset
select child_name as qlive from pgpm.part
 where parent_table = 'public.sw_q'::regclass and attached and lo::bigint <= 20000 and hi::bigint > 20000 \gset

select ok('public.sw_p'::regclass::oid < 'public.sw_q'::regclass::oid,
  'LIVENESS: P precedes Q in the fixed order');
select is((select string_agg(parent_table::text, ',' order by parent_table) from pgpm.config
            where parent_table in ('public.sw_p'::regclass, 'public.sw_q'::regclass) and sweep_turn_at is null),
  'sw_p,sw_q',
  'LIVENESS: P and Q are new to the sweep, so neither has had a turn');

select setval('s147.first_in_tick', 0, false);
set statement_timeout = '4s';
\set ON_ERROR_STOP 0
call pgpm.maintain_all();
\set ON_ERROR_STOP 1
reset statement_timeout;

select is(s147.calls('s147.calls_p'), 1,
  'LIVENESS: tick 1 entered P''s archive function');
select ok(not exists (select 1 from pgpm.archive_ledger where parent_table = 'public.sw_p'::regclass),
  'LIVENESS: and P''s own tick overran the timeout');
select ok(to_regclass('public.' || quote_ident(:'qold')) is not null,
  'LIVENESS: tick 1 never reached Q, so its aged partition is still there');

select setval('s147.first_in_tick', 0, false);
set statement_timeout = '4s';
\set ON_ERROR_STOP 0
call pgpm.maintain_all();
\set ON_ERROR_STOP 1
reset statement_timeout;

select is((select string_agg(lo, ',' order by id) from pgpm.log
            where parent_table = 'public.sw_q'::regclass and action = 'retain_drop'),
  '0',
  'tick 2: P, which had its turn as tick 1''s first parent, did not lead again; Q did, and retired [0,1000)');
select ok(to_regclass('public.' || quote_ident(:'qold')) is null, 'Q''s aged partition is gone');
select is((select string_agg(t.id || '->' || c.relname, ' ' order by t.id)
             from public.sw_q t join pg_class c on c.oid = t.tableoid),
  '20000->' || :'qlive',
  'and only it: Q''s live partition keeps its frontier row');
select is(s147.calls('s147.calls_p'), 2,
  'LIVENESS: P was not dropped from the sweep; tick 2 still gave it a turn');

select * from finish();
