-- The archive contract holds covered_hi to the control column's own type, and the ledger records it in the
-- spelling that type reads (issue #1071).
--
-- THE BUG. pgpm._archive_contract_breach judged an id grid's covered_hi as numeric and never as the column it
-- describes. A resumable strategy returning (lo + hi) / 2 on a bigint key got '15.0000000000000000' or
-- '22.5000000000000000' past the check, the ledger stored that text, and every later tick's
-- _next_archive_chunk compared the bigint column with it as a literal and raised 22P02 ('invalid input syntax
-- for type bigint'), logged skip_archive: the partition was never archived further and never retired, and
-- pointing set_archive_fn at a corrected strategy did not recover it, because the poisoned ledger row stayed.
--
-- THE CONTRACT.
--   PART A  _archive_step on a bigint key. An integral value spelt with a scale ('15.0000000000000000') is the
--           value 15, which the column holds: accepted and recorded as '15', and the next tick resumes from
--           it. A fractional one ('22.5000000000000000') is not a bigint: refused (fail_archive_contract,
--           naming the column's type), nothing recorded. A corrected strategy then archives on from 15, the
--           partition is covered and retired, and every id of it was archived first.
--   PART B  scripts/archive_partition_whole.sql, the second site, on a bigint key: the same refusal and the
--           same canonical record, through the same check.
--   PART C  CONTROL, a numeric key: a fractional covered_hi is a value the column holds, so it is accepted,
--           so the refusal in A and B is the column's type and not "a fraction".
--   PART D  ledger rows an earlier install already recorded with such values (a fraction, and a whole number
--           at the strategy's scale): the next tick still raises (skip_archive), and the repair
--           docs/reference.md gives for an integer key (hi written as the next whole number at or above it)
--           makes the next tick resume from it.
--
-- ASYMMETRIC FIXTURE. A has 25 rows and ends with 2 ledger rows, B 7 rows and 2 rows, C 26 rows (one of them
-- 22.5) and 3 rows; D's two tables hold 25 rows each and resume from 16 and from 15. Every strategy records
-- each call it gets (table, lo, hi, what it returned), so what each tick handed it is read back by identity.
--
-- bench/archive_covered_hi_column_type.sh runs this file against bench/mutations/mutate.py's
-- archive_covered_hi_scale_kept (the ledger records the strategy's scale again) and
-- archive_contract_column_type_unchecked (the column-type clause of the check removed).
create extension if not exists pgtap;
set client_min_messages = warning;

\if :{?archive_whole_script}
\else
\set archive_whole_script /repo/scripts/archive_partition_whole.sql
\endif
\i :archive_whole_script

select plan(27);

create schema t292;
create table t292.calls (seq serial, tbl text, strategy text, p_lo text, p_hi text, returned text);
create table t292.archived (tbl text, id numeric);

-- archives the lower half of the chunk it is handed and says so, unrounded: (lo + hi) / 2 as numeric text
create function t292.half(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_mid numeric := (p_lo::numeric + p_hi::numeric) / 2; n int;
begin
  execute format('insert into t292.archived select %L, id from %s where id >= %s and id < %s',
                 p_parent::text, p_parent::text, p_lo, v_mid);
  get diagnostics n = row_count;
  insert into t292.calls (tbl, strategy, p_lo, p_hi, returned) values (p_parent::text, 'half', p_lo, p_hi, v_mid::text);
  v.covered_hi := v_mid::text;
  v.rows_archived := n;
  return v;
end $$;

-- archives the first third of the chunk, unrounded
create function t292.third(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_to numeric := p_lo::numeric + (p_hi::numeric - p_lo::numeric) / 3; n int;
begin
  execute format('insert into t292.archived select %L, id from %s where id >= %s and id < %s',
                 p_parent::text, p_parent::text, p_lo, v_to);
  get diagnostics n = row_count;
  insert into t292.calls (tbl, strategy, p_lo, p_hi, returned) values (p_parent::text, 'third', p_lo, p_hi, v_to::text);
  v.covered_hi := v_to::text;
  v.rows_archived := n;
  return v;
end $$;

-- the corrected strategy: archives the whole chunk and returns hi as handed
create function t292.whole(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; n int;
begin
  execute format('insert into t292.archived select %L, id from %s where id >= %s and id < %s',
                 p_parent::text, p_parent::text, p_lo, p_hi);
  get diagnostics n = row_count;
  insert into t292.calls (tbl, strategy, p_lo, p_hi, returned) values (p_parent::text, 'whole', p_lo, p_hi, p_hi);
  v.covered_hi := p_hi;
  v.rows_archived := n;
  return v;
end $$;

-- ---------------------------------------------------------------- PART A: _archive_step, bigint key
-- [0, 30) is the monolith; the frontier row at 45 puts the retention horizon past it (retain 10).
create table public.t292_big (id bigint primary key, payload text);
insert into public.t292_big select g, 'big' from generate_series(1, 25) g;
call pgpm.transmute('public.t292_big', 'id', 10, p_retain => 10, p_paused => false);
insert into public.t292_big values (45, 'frontier');
select pgpm.set_archive_fn('public.t292_big', 't292.half(regclass,name,text,text)'::regprocedure);
select child_name as ch_big from pgpm.part where parent_table = 'public.t292_big'::regclass and lo = '0' \gset

call pgpm.maintain('public.t292_big');   -- tick 1: [0, 30) -> 15.0000000000000000
select results_eq(
  $$ select lo, hi from pgpm.archive_ledger where parent_table = 'public.t292_big'::regclass $$,
  $$ values ('0'::text, '15'::text) $$,
  'A: tick 1''s covered_hi 15.0000000000000000 is the value 15, and the ledger records it as the bigint reads it');

call pgpm.maintain('public.t292_big');   -- tick 2: [15, 30) -> 22.5000000000000000
select results_eq(
  $$ select strategy, p_lo, p_hi, returned from t292.calls where tbl = 't292_big' order by seq $$,
  $$ values ('half'::text, '0'::text, '30'::text, '15.0000000000000000'::text),
            ('half', '15', '30', '22.5000000000000000') $$,
  'LIVENESS: A: tick 2 read the partition from the recorded 15 and handed the strategy [15, 30)');
select results_eq(
  $$ select lo, hi from pgpm.archive_ledger where parent_table = 'public.t292_big'::regclass $$,
  $$ values ('0'::text, '15'::text) $$,
  'A: tick 2''s covered_hi 22.5000000000000000 is not a bigint, and nothing was recorded from it');
select results_eq(
  $$ select lo, hi, method like '%returned covered_hi ''22.5000000000000000''%' and method like '%bigint%'
       from pgpm.log where parent_table = 'public.t292_big'::regclass and action = 'fail_archive_contract' $$,
  $$ values ('15'::text, '30'::text, true) $$,
  'A: it is refused once, fail_archive_contract over [15, 30), naming the value and the column''s type');

select pgpm.set_archive_fn('public.t292_big', 't292.whole(regclass,name,text,text)'::regprocedure);
call pgpm.maintain('public.t292_big');   -- tick 3: the corrected strategy, [15, 30) -> 30
select results_eq(
  $$ select strategy, p_lo, p_hi from t292.calls where tbl = 't292_big' order by seq offset 2 $$,
  $$ values ('whole'::text, '15'::text, '30'::text) $$,
  'LIVENESS: A: tick 3 handed the corrected strategy [15, 30), from where the ledger honestly stands');
select results_eq(
  $$ select lo, hi from pgpm.archive_ledger where parent_table = 'public.t292_big'::regclass order by lo::numeric $$,
  $$ values ('0'::text, '15'::text), ('15', '30') $$,
  'A: the corrected strategy''s chunk is recorded, and the partition is covered to its hi');
select is_empty(
  $$ select 1 from pgpm.log where parent_table = 'public.t292_big'::regclass and action = 'skip_archive' $$,
  'A: no tick failed reading the partition back (no skip_archive)');
select is_empty(format($$ select 1 from pgpm.part where parent_table = 'public.t292_big'::regclass and child_name = %L $$, :'ch_big'),
  'A: tick 3 retired the covered monolith');
select results_eq($$ select id from public.t292_big order by id $$, $$ values (45::bigint) $$,
  'A: ids 1 to 25 went with it; only the frontier row is left');
select results_eq(
  $$ select distinct id from t292.archived where tbl = 't292_big' order by id $$,
  $$ select g::numeric from generate_series(1, 25) g $$,
  'A: and every one of ids 1 to 25 was archived first');

-- ---------------------------------------------------------------- PART B: the whole-partition script, bigint key
create table public.t292_whole (id bigint primary key, payload text);
insert into public.t292_whole select g, 'whole' from generate_series(1, 7) g;
call pgpm.transmute('public.t292_whole', 'id', 1000, p_retain => 19000, p_paused => false);
insert into public.t292_whole values (20000, 'frontier');
select pgpm._enforce_write_blocks('public.t292_whole');
select child_name as ch_whole from pgpm.part where parent_table = 'public.t292_whole'::regclass and lo = '0' \gset
select ok(pgpm._is_write_blocked('public.t292_whole', :'ch_whole'),
  'LIVENESS: B: the monolith is write-blocked, so the script picks it');

select pgpm.set_archive_fn('public.t292_whole', 't292.third(regclass,name,text,text)'::regprocedure);
select pgpm_archive_next_partition_whole('public.t292_whole'::regclass) as msg_third \gset
select diag('B third: ' || :'msg_third');
select results_eq(
  $$ select strategy, p_lo, p_hi, returned from t292.calls where tbl = 't292_whole' order by seq $$,
  $$ values ('third'::text, '0'::text, '1000'::text, '333.3333333333333333'::text) $$,
  'LIVENESS: B: the script handed the strategy [0, 1000) and it returned a third of it');
select is_empty($$ select 1 from pgpm.archive_ledger where parent_table = 'public.t292_whole'::regclass $$,
  'B: the script recorded nothing from a covered_hi the bigint key cannot hold');
select ok(:'msg_third' like '%REFUSING%' and :'msg_third' like '%bigint%',
  'B: its message refuses and names the column''s type');
select results_eq(
  $$ select lo, hi, method like '%bigint%' from pgpm.log
      where parent_table = 'public.t292_whole'::regclass and action = 'fail_archive_contract' $$,
  $$ values ('0'::text, '1000'::text, true) $$,
  'B: and logs fail_archive_contract over [0, 1000), as _archive_step does');

select pgpm.set_archive_fn('public.t292_whole', 't292.half(regclass,name,text,text)'::regprocedure);
select pgpm_archive_next_partition_whole('public.t292_whole'::regclass) as msg_half1 \gset
select pgpm_archive_next_partition_whole('public.t292_whole'::regclass) as msg_half2 \gset
select diag('B half: ' || :'msg_half1' || ' / ' || :'msg_half2');
select results_eq(
  $$ select p_lo, p_hi, returned from t292.calls where tbl = 't292_whole' and strategy = 'half' order by seq $$,
  $$ values ('0'::text, '1000'::text, '500.0000000000000000'::text), ('500', '1000', '750.0000000000000000') $$,
  'B: the second call resumed from the recorded 500');
select results_eq(
  $$ select lo, hi from pgpm.archive_ledger where parent_table = 'public.t292_whole'::regclass order by lo::numeric $$,
  $$ values ('0'::text, '500'::text), ('500', '750') $$,
  'B: both halves are recorded as the bigint reads them');
select ok(:'msg_half1' like '%PARTIAL only (requested hi 1000, got 500)%'
      and :'msg_half2' like '%PARTIAL only (requested hi 1000, got 750)%',
  'B: and each call reports the value it recorded');

-- ---------------------------------------------------------------- PART C: CONTROL, a numeric key
create table public.t292_num (id numeric primary key, payload text);
insert into public.t292_num select g, 'num' from generate_series(1, 25) g;
insert into public.t292_num values (22.5, 'num');
call pgpm.transmute('public.t292_num', 'id', 10, p_retain => 10, p_paused => false);
insert into public.t292_num values (45, 'frontier');
select pgpm.set_archive_fn('public.t292_num', 't292.half(regclass,name,text,text)'::regprocedure);

call pgpm.maintain('public.t292_num');   -- [0, 30) -> 15
call pgpm.maintain('public.t292_num');   -- [15, 30) -> 22.5
call pgpm.maintain('public.t292_num');   -- [22.5, 30) -> 26.25
select results_eq(
  $$ select p_lo, p_hi, returned from t292.calls where tbl = 't292_num' order by seq $$,
  $$ values ('0'::text, '30'::text, '15.0000000000000000'::text), ('15', '30', '22.5000000000000000'),
            ('22.5', '30', '26.2500000000000000') $$,
  'LIVENESS: C: three ticks each handed the strategy the chunk from the last recorded value');
select results_eq(
  $$ select lo, hi from pgpm.archive_ledger where parent_table = 'public.t292_num'::regclass order by lo::numeric $$,
  $$ values ('0'::text, '15'::text), ('15', '22.5'), ('22.5', '26.25') $$,
  'C: on a numeric key a fractional covered_hi is a value of the column, and is recorded');
select is_empty(
  $$ select 1 from pgpm.log where parent_table = 'public.t292_num'::regclass
       and action in ('fail_archive_contract', 'skip_archive') $$,
  'C: nothing was refused and no tick failed');
select results_eq(
  $$ select id from t292.archived where tbl = 't292_num' order by id $$,
  $$ select g::numeric from generate_series(1, 22) g union all values (22.5) union all select g from generate_series(23, 25) g $$,
  'C: ids 1 to 22, 22.5, and 23 to 25 were each archived once');

-- ---------------------------------------------------------------- PART D: values an earlier install recorded
-- Two tables, each with the row a pre-#1071 tick wrote, verbatim: a fraction (from (0 + 30) / 2 + 0.5) and a
-- whole number at the strategy's scale (from (0 + 30) / 2, the issue's own shape).
create table public.t292_old (id bigint primary key, payload text);
create table public.t292_old2 (id bigint primary key, payload text);
insert into public.t292_old select g, 'old' from generate_series(1, 25) g;
insert into public.t292_old2 select g, 'old2' from generate_series(1, 25) g;
call pgpm.transmute('public.t292_old', 'id', 10, p_retain => 10, p_paused => false);
call pgpm.transmute('public.t292_old2', 'id', 10, p_retain => 10, p_paused => false);
insert into public.t292_old values (45, 'frontier');
insert into public.t292_old2 values (45, 'frontier');
select pgpm._enforce_write_blocks('public.t292_old');
select pgpm._enforce_write_blocks('public.t292_old2');
select child_name as ch_old from pgpm.part where parent_table = 'public.t292_old'::regclass and lo = '0' \gset
select child_name as ch_old2 from pgpm.part where parent_table = 'public.t292_old2'::regclass and lo = '0' \gset
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived)
  values ('public.t292_old'::regclass, '0', '15.5000000000000000', :'ch_old', 15),
         ('public.t292_old2'::regclass, '0', '15.0000000000000000', :'ch_old2', 14);
select pgpm.set_archive_fn('public.t292_old', 't292.whole(regclass,name,text,text)'::regprocedure);
select pgpm.set_archive_fn('public.t292_old2', 't292.whole(regclass,name,text,text)'::regprocedure);

call pgpm.maintain('public.t292_old');
call pgpm.maintain('public.t292_old2');
select results_eq(
  $$ select parent_table::text, method like '%invalid input syntax for type bigint%' from pgpm.log
      where parent_table in ('public.t292_old'::regclass, 'public.t292_old2'::regclass) and action = 'skip_archive'
      order by 1 $$,
  $$ values ('t292_old'::text, true), ('t292_old2', true) $$,
  'D: each recorded value still fails the next tick reading its partition (skip_archive)');
select is_empty($$ select 1 from t292.calls where tbl in ('t292_old', 't292_old2') $$,
  'D: and neither strategy was reached');

-- the repair docs/reference.md gives for an integer key, verbatim but for the parents
update pgpm.archive_ledger set hi = ceil(hi::numeric)::text
 where parent_table in ('public.t292_old'::regclass, 'public.t292_old2'::regclass) and hi <> ceil(hi::numeric)::text;
call pgpm.maintain('public.t292_old');
call pgpm.maintain('public.t292_old2');
select results_eq(
  $$ select tbl, strategy, p_lo, p_hi from t292.calls where tbl in ('t292_old', 't292_old2') order by tbl $$,
  $$ values ('t292_old'::text, 'whole'::text, '16'::text, '30'::text), ('t292_old2', 'whole', '15', '30') $$,
  'D: after the repair the next tick resumes, from 16 and from 15');
select results_eq(
  $$ select 'old', id from public.t292_old union all select 'old2', id from public.t292_old2 order by 1, 2 $$,
  $$ values ('old'::text, 45::bigint), ('old2', 45) $$,
  'D: and both covered monoliths are retired');
select results_eq(
  $$ select tbl, id from t292.archived where tbl in ('t292_old', 't292_old2') order by tbl, id $$,
  $$ select 't292_old'::text, g::numeric from generate_series(16, 25) g
     union all select 't292_old2', g from generate_series(15, 25) g $$,
  'D: the ids each strategy was handed, 16 to 25 and 15 to 25, are the ones it archived');

select * from finish();
