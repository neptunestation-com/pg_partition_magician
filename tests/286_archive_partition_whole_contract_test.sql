-- scripts/archive_partition_whole.sql holds its strategy's return to the archive contract (issue #1030,
-- bullet 3).
--
-- THE BUG. The operator utility pgpm_archive_next_partition_whole(regclass) hands the configured
-- archive_fn a write-blocked partition's whole [lo, hi) and writes the covered_hi it gets back into
-- pgpm.archive_ledger, the row retire() reads as its drop precondition. pgpm._archive_step holds the
-- same return to issue #454's contract first (pgpm._archive_contract_breach: null, at or below lo, or
-- past hi is refused, logged fail_archive_contract, and nothing is written); the script did not. A
-- strategy that answered [0, 1000) with 1000000 and archived nothing therefore marked the partition
-- covered, and retire() dropped it with nothing archived. Its PARTIAL message compared covered_hi to
-- hi as text, after the row was already written, so it reported the overshoot as partial progress,
-- and reported a full cover spelt '1000.0' as partial too.
--
-- THE CONTRACT. The script refuses exactly what _archive_step refuses, before any ledger write, and
-- tells full from partial by value:
--   PART A  an overshooting strategy: no ledger row, the coverage gate shut, retire() refuses, the 7
--           rows still there by id, fail_archive_contract logged over the range handed, and the
--           returned message names the rule broken.
--   PART B  a strategy that covered nothing (covered_hi = lo): refused the same way, so the script
--           cannot write the (lo, lo) row that wedges the ledger on its primary key.
--   PART C  LIVENESS of the gate: an honest strategy covering the whole range, spelt '1000.0', is
--           accepted; the message says fully archived, the gate opens, and retire() drops that
--           partition, so A's refusal is the contract and not a retire() that can never drop.
--   PART D  an honest partial cover is accepted as partial, and the next call resumes from it.
--
-- ASYMMETRIC FIXTURE. Four tables with different row sets (7, 3, 5 and 4 rows in [0, 1000)); A and B
-- keep theirs, C loses its 5, D keeps its 4. Every strategy records the calls it gets, so "what the
-- strategy was handed" is read back by identity.
--
-- bench/archive_partition_whole_contract.sh runs this file against the script with
-- bench/mutations/mutate.py's archive_whole_contract_unchecked (the check removed again) and
-- archive_whole_partial_compared_as_text (the text comparison back). The script's path is the psql
-- variable archive_whole_script, defaulting to the tree's copy, so the guard can point it at a mutant.
create extension if not exists pgtap;
set client_min_messages = warning;

\if :{?archive_whole_script}
\else
\set archive_whole_script /repo/scripts/archive_partition_whole.sql
\endif
\i :archive_whole_script

select plan(27);

create schema t286;
create table t286.calls (strategy text, p_child name, p_lo text, p_hi text);

create function t286.overshoot(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into t286.calls values ('overshoot', p_child, p_lo, p_hi);
  v.covered_hi := (p_hi::numeric * 1000)::text;   -- past the range handed, nothing archived
  v.rows_archived := 0;
  return v;
end $$;

create function t286.stall(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into t286.calls values ('stall', p_child, p_lo, p_hi);
  v.covered_hi := p_lo;   -- no progress
  v.rows_archived := 0;
  return v;
end $$;

create function t286.whole(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into t286.calls values ('whole', p_child, p_lo, p_hi);
  v.covered_hi := p_hi || '.0';   -- exactly hi, spelt differently from pgpm.part.hi
  v.rows_archived := 5;
  return v;
end $$;

create function t286.halfway(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into t286.calls values ('halfway', p_child, p_lo, p_hi);
  v.covered_hi := ((p_lo::numeric + p_hi::numeric) / 2)::bigint::text;
  v.rows_archived := 2;
  return v;
end $$;

-- One table per strategy: [0, 1000) is the monolith, write-blocked once the frontier row sets the
-- horizon at 1000 (retain 19000 below 20000).
create table public.t286_over  (id bigint primary key, payload text);
create table public.t286_stall (id bigint primary key, payload text);
create table public.t286_full  (id bigint primary key, payload text);
create table public.t286_half  (id bigint primary key, payload text);
insert into public.t286_over  select g, 'over'  from generate_series(1, 7) g;
insert into public.t286_stall select g, 'stall' from generate_series(101, 103) g;
insert into public.t286_full  select g, 'full'  from generate_series(201, 205) g;
insert into public.t286_half  (id, payload) values (301, 'h'), (302, 'h'), (601, 'h'), (602, 'h');
call pgpm.transmute('public.t286_over',  'id', 1000, p_retain => 19000, p_paused => false);
call pgpm.transmute('public.t286_stall', 'id', 1000, p_retain => 19000, p_paused => false);
call pgpm.transmute('public.t286_full',  'id', 1000, p_retain => 19000, p_paused => false);
call pgpm.transmute('public.t286_half',  'id', 1000, p_retain => 19000, p_paused => false);
insert into public.t286_over  values (20000, 'frontier');
insert into public.t286_stall values (20000, 'frontier');
insert into public.t286_full  values (20000, 'frontier');
insert into public.t286_half  values (20000, 'frontier');
select pgpm._enforce_write_blocks('public.t286_over');
select pgpm._enforce_write_blocks('public.t286_stall');
select pgpm._enforce_write_blocks('public.t286_full');
select pgpm._enforce_write_blocks('public.t286_half');
select pgpm.set_archive_fn('public.t286_over',  't286.overshoot(regclass,name,text,text)'::regprocedure);
select pgpm.set_archive_fn('public.t286_stall', 't286.stall(regclass,name,text,text)'::regprocedure);
select pgpm.set_archive_fn('public.t286_full',  't286.whole(regclass,name,text,text)'::regprocedure);
select pgpm.set_archive_fn('public.t286_half',  't286.halfway(regclass,name,text,text)'::regprocedure);

select child_name as ch_over  from pgpm.part where parent_table = 'public.t286_over'::regclass  and lo = '0' \gset
select child_name as ch_stall from pgpm.part where parent_table = 'public.t286_stall'::regclass and lo = '0' \gset
select child_name as ch_full  from pgpm.part where parent_table = 'public.t286_full'::regclass  and lo = '0' \gset
select child_name as ch_half  from pgpm.part where parent_table = 'public.t286_half'::regclass  and lo = '0' \gset

select ok(pgpm._is_write_blocked('public.t286_over', :'ch_over')
      and pgpm._is_write_blocked('public.t286_stall', :'ch_stall')
      and pgpm._is_write_blocked('public.t286_full', :'ch_full')
      and pgpm._is_write_blocked('public.t286_half', :'ch_half'),
  'LIVENESS: all four monoliths are write-blocked, so the script will pick each one');
select ok(not pgpm._archive_fully_covered('public.t286_over', :'ch_over')
      and not pgpm._archive_fully_covered('public.t286_full', :'ch_full'),
  'LIVENESS: and none is covered yet');

-- ---------------------------------------------------------------- PART A: overshoot
select pgpm_archive_next_partition_whole('public.t286_over'::regclass) as msg_over \gset
select diag('A: ' || :'msg_over');

select results_eq($$ select p_child, p_lo, p_hi from t286.calls where strategy = 'overshoot' $$,
  format($$ values (%L::name, '0'::text, '1000'::text) $$, :'ch_over'),
  'LIVENESS: A: the script handed the overshooting strategy exactly [0, 1000) of the monolith');
select is((select count(*)::int from pgpm.archive_ledger where parent_table = 'public.t286_over'::regclass), 0,
  'A: no ledger row was written from a covered_hi past hi');
select ok(not pgpm._archive_fully_covered('public.t286_over', :'ch_over'), 'A: the coverage gate stays shut');
select ok(:'msg_over' like '%REFUSING%' and :'msg_over' like '%covered_hi must not exceed hi%',
  'A: the message refuses and names the rule the return broke');
select ok(:'msg_over' not like '%PARTIAL%' and :'msg_over' not like '%fully archived%',
  'A: and reports no progress, partial or full');
select ok(not pgpm.retire('public.t286_over', :'ch_over'), 'A: retire() refuses the drop');
select results_eq($$ select id from public.t286_over where id < 1000 order by id $$,
  $$ values (1::bigint), (2), (3), (4), (5), (6), (7) $$,
  'A: ids 1 to 7 are all still there');

-- ---------------------------------------------------------------- PART B: no progress
select pgpm_archive_next_partition_whole('public.t286_stall'::regclass) as msg_stall \gset
select diag('B: ' || :'msg_stall');

select results_eq($$ select p_child, p_lo, p_hi from t286.calls where strategy = 'stall' $$,
  format($$ values (%L::name, '0'::text, '1000'::text) $$, :'ch_stall'),
  'LIVENESS: B: the script handed the stalling strategy exactly [0, 1000)');
select is((select count(*)::int from pgpm.archive_ledger where parent_table = 'public.t286_stall'::regclass), 0,
  'B: no (lo, lo) ledger row was written from a covered_hi equal to lo');
select ok(:'msg_stall' like '%REFUSING%' and :'msg_stall' like '%covered_hi must be above lo%',
  'B: the message refuses and names the rule the return broke');
select results_eq($$ select id from public.t286_stall where id < 1000 order by id $$,
  $$ values (101::bigint), (102), (103) $$,
  'B: ids 101 to 103 are all still there');

-- The refusals leave the record _archive_step leaves for the same returns: exactly fail_archive_contract,
-- over the range handed, once per refused call, and for no other table.
select results_eq(
  $$ select parent_table::text, lo, hi from pgpm.log where action = 'fail_archive_contract' order by 1 $$,
  $$ values ('t286_over'::text, '0'::text, '1000'::text), ('t286_stall', '0', '1000') $$,
  'A and B: each refusal is logged fail_archive_contract over [0, 1000), and nothing else is');
select ok((select method from pgpm.log where action = 'fail_archive_contract'
            and parent_table = 'public.t286_over'::regclass) like '%returned covered_hi ''1000000''%',
  'A: the log row names the value the strategy returned');

-- ---------------------------------------------------------------- PART C: whole, spelt '1000.0'
select pgpm_archive_next_partition_whole('public.t286_full'::regclass) as msg_full \gset
select diag('C: ' || :'msg_full');

select results_eq($$ select p_child, p_lo, p_hi from t286.calls where strategy = 'whole' $$,
  format($$ values (%L::name, '0'::text, '1000'::text) $$, :'ch_full'),
  'LIVENESS: C: the script handed the honest strategy exactly [0, 1000)');
select results_eq(
  $$ select lo, hi::numeric, child_name, rows_archived from pgpm.archive_ledger
      where parent_table = 'public.t286_full'::regclass $$,
  format($$ values ('0'::text, 1000::numeric, %L::name, 5::bigint) $$, :'ch_full'),
  'C: one ledger row records [0, 1000) for the monolith, 5 rows');
select ok(:'msg_full' like '%fully archived in one file (5 rows%',
  'C: the message says fully archived: covered_hi equals hi as a value, whatever its spelling');
select ok(pgpm._archive_fully_covered('public.t286_full', :'ch_full'), 'LIVENESS: C: the coverage gate opens');
select ok(pgpm.retire('public.t286_full', :'ch_full'), 'LIVENESS: C: retire() drops the covered monolith');
select results_eq($$ select id from public.t286_full order by id $$, $$ values (20000::bigint) $$,
  'LIVENESS: C: ids 201 to 205 went with it; only the frontier row is left');

-- ---------------------------------------------------------------- PART D: honest partial, then resume
select pgpm_archive_next_partition_whole('public.t286_half'::regclass) as msg_half1 \gset
select pgpm_archive_next_partition_whole('public.t286_half'::regclass) as msg_half2 \gset
select diag('D: ' || :'msg_half1' || ' / ' || :'msg_half2');

select results_eq($$ select p_child, p_lo, p_hi from t286.calls where strategy = 'halfway' order by p_lo::numeric $$,
  format($$ values (%L::name, '0'::text, '1000'::text), (%1$L::name, '500'::text, '1000'::text) $$, :'ch_half'),
  'D: the second call resumed from where the first one honestly left off');
select results_eq(
  $$ select lo, hi from pgpm.archive_ledger where parent_table = 'public.t286_half'::regclass order by lo::numeric $$,
  $$ values ('0'::text, '500'::text), ('500', '750') $$,
  'D: both partial covers were recorded');
select ok(:'msg_half1' like '%PARTIAL only (requested hi 1000, got 500)%'
      and :'msg_half2' like '%PARTIAL only (requested hi 1000, got 750)%',
  'D: each call says it was partial');
select ok(not pgpm._archive_fully_covered('public.t286_half', :'ch_half'), 'D: the coverage gate stays shut');
select ok(not pgpm.retire('public.t286_half', :'ch_half'), 'D: retire() refuses the partly covered monolith');
select results_eq($$ select id from public.t286_half where id < 1000 order by id $$,
  $$ values (301::bigint), (302), (601), (602) $$,
  'D: ids 301, 302, 601 and 602 are all still there');

select * from finish();
