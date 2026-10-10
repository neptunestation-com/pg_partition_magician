-- A partition the operator DETACHed by hand is the operator's table: no maintain() step write-blocks or
-- archives it (issue #705).
--
-- #652 made retire() refuse a child that is no longer a partition of its parent and carries no retiring_at
-- (pgpm's own retirement in flight): it logs fail_retain_drop and, per the reference, "neither write-blocks
-- nor drops the table". The two other maintain() steps that read pgpm.part.attached were left trusting it.
-- pgpm.part says what pgpm did, not what the catalog holds, and an operator's own DETACH PARTITION never
-- touches it, so:
--
--   * _enforce_write_blocks walked the detached table like any attached partition, and once retention
--     reached its range put pgpm_write_block on it: every write to a table pgpm no longer manages was
--     refused "past its retention boundary" (re-found in review pass 10 as F4-03);
--   * _archive_step took it for a candidate as long as it carried a block (one pgpm put on before the
--     operator detached it), handed it to the archive strategy and recorded coverage for it.
--
-- Both now ask the predicate obtain and status() ask (pgpm._part_built, through _part_detached_by_hand):
-- a child whose relation still exists, is not a partition of the parent, and carries no retiring_at, is
-- left alone, and its pgpm.part row stays for retire() to refuse and log, as the reference says. The rule
-- is one-directional: a child pgpm's own retirement detached (retiring_at set) is still pgpm's, and a
-- partition dropped by hand still takes the skip_write_block path tests/94 is built on.
--
-- Identity, not cardinality: every assertion names WHICH partition, by its lo, carries a block, was
-- handed to the strategy, or was dropped. Fixtures are asymmetric: three attached partitions are past the
-- horizon beside the one detached, so a block missing from one and present on another cannot cancel.
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(50);

create schema pgpm_test307;

-- ============== part A: the write-block step leaves a hand-detached partition writable ==============
-- Monolith [0, 20000) of ids 1..15000, then [20000, 30000) holding 25000 and 26000 (the operator's
-- table-to-be), [30000, 40000) holding 35000, [40000, 50000) holding 45000. A frontier row at 85000 puts
-- the horizon at 50000 (85000 - 30000, floored to the grid): the monolith, [20000, 30000), [30000, 40000)
-- and [40000, 50000) are all at or below it.
create table public.wb307 (id bigint primary key, payload text);
insert into public.wb307 select g, 'base' from generate_series(1, 15000) g;
call pgpm.transmute('public.wb307', 'id', 10000, p_retain => 30000, p_paused => false);
insert into public.wb307 values (25000, 'kept-a'), (26000, 'kept-b'), (35000, 'sib-30k'), (45000, 'sib-40k');
select pgpm.obtain('public.wb307');

create table pgpm_test307.wb_names as
  select lo, child_name, child_oid from pgpm.part where parent_table = 'public.wb307'::regclass;
select child_name as wb_kept, child_oid as wb_kept_oid from pgpm_test307.wb_names where lo = '20000' \gset

-- the operator detaches [20000, 30000) to keep it, BEFORE retention reaches it
select format('alter table public.wb307 detach partition public.%I', :'wb_kept') \gexec
insert into public.wb307 values (85000, 'frontier');

select ok(not exists (select 1 from pg_inherits where inhparent = 'public.wb307'::regclass
                       and inhrelid = :'wb_kept_oid'::oid),
  'LIVENESS: [20000, 30000) is no longer a partition of the table (detached by hand)');
select is(pgpm._retain_boundary((select c from pgpm.config c where parent_table = 'public.wb307'::regclass)), '50000',
  'LIVENESS: retention reaches [20000, 30000) and the three attached partitions around it');
select is((select retiring_at from pgpm.part where child_oid = :'wb_kept_oid'::oid), null,
  'LIVENESS: the detached partition carries no retiring_at (pgpm did not detach it)');

-- the write-block step alone, so what it does is not mixed with retain()'s
select pgpm._enforce_write_blocks('public.wb307');

select is((select array_agg(n.lo::bigint order by n.lo::bigint)
             from pgpm_test307.wb_names n join pg_trigger t on t.tgrelid = n.child_oid
            where t.tgname = 'pgpm_write_block'),
  array[0::bigint, 30000, 40000],
  'the write-block step blocks exactly the three attached partitions past the horizon, not the detached one');
select ok(not exists (select 1 from pg_trigger where tgrelid = :'wb_kept_oid'::oid and tgname = 'pgpm_write_block'),
  'no pgpm write block is put on the operator''s detached table');
select lives_ok(format('update public.%I set payload = ''still mine'' where id = 25000', :'wb_kept'),
  'the operator can write to the table they detached after the write-block step');
select is((select array_agg(id || ':' || payload order by id) from public.wb307 where id < 50000 and id >= 30000),
  array['35000:sib-30k', '45000:sib-40k'],
  'LIVENESS: the attached partitions'' rows are untouched by the step');

-- a whole tick: write block, archive (none), retain. retire() drops the three attached partitions and
-- refuses the detached one, which is the #652 contract the write-block step now agrees with.
call pgpm.maintain('public.wb307');

select is((select array_agg(lo::bigint order by lo::bigint) from pgpm.log
            where parent_table = 'public.wb307'::regclass and action = 'retain_drop'),
  array[0::bigint, 30000, 40000],
  'LIVENESS: the tick reached retention and dropped exactly the three attached partitions past the horizon');
select is((select array_agg(lo order by lo) from pgpm.log
            where parent_table = 'public.wb307'::regclass and action = 'fail_retain_drop'),
  array['20000'],
  'LIVENESS: retire() refused the detached partition as detached by the operator');
select ok(not exists (select 1 from pg_trigger where tgrelid = :'wb_kept_oid'::oid and tgname = 'pgpm_write_block'),
  'after a whole maintain() tick the operator''s detached table still carries no pgpm write block');
select lives_ok(format('insert into public.%I values (27000, ''added by hand'')', :'wb_kept'),
  'the operator can still insert into the table they detached after the tick');
select results_eq(format('select id, payload from public.%I order by id', :'wb_kept'),
  $$values (25000::bigint, 'still mine'::text), (26000, 'kept-b'), (27000, 'added by hand')$$,
  'the detached table holds exactly its own two rows, the update and the insert made by hand');
select ok((select attached from pgpm.part where child_oid = :'wb_kept_oid'::oid),
  'the detached partition''s pgpm.part row is left as it was, so retire() keeps refusing and logging it');

-- ============== part B: the archive step does not archive a hand-detached partition ==============
-- Same shape, with a strategy that RECORDS what it is handed and archive_batch unlimited, so every
-- write-blocked candidate gets a turn in one call. The write-block step runs BEFORE the operator detaches
-- [20000, 30000), so the detached table carries pgpm's block, which is what made it a candidate.
create table pgpm_test307.handed (child name, id bigint);
create function pgpm_test307.recorder(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v_rows bigint; v_result pgpm.archive_result;
begin
  execute format('insert into pgpm_test307.handed (child, id) select %L, id from public.%I where id >= %L::bigint and id < %L::bigint',
                 p_child, p_child, p_lo, p_hi);
  get diagnostics v_rows = row_count;
  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  return v_result;
end;
$$;

create table public.ar307 (id bigint primary key, payload text);
insert into public.ar307 select g, 'base' from generate_series(1, 50) g;
call pgpm.transmute('public.ar307', 'id', 10000, p_retain => 30000, p_paused => false);
select pgpm.obtain('public.ar307');
insert into public.ar307 values (25000, 'kept-a'), (26000, 'kept-b'), (35000, 'sib-30k'), (85000, 'frontier');
update pgpm.config set archive_batch = null where parent_table = 'public.ar307'::regclass;
select pgpm.set_archive_fn('public.ar307', 'pgpm_test307.recorder(regclass,name,text,text)');

create table pgpm_test307.ar_names as
  select lo, child_name, child_oid from pgpm.part where parent_table = 'public.ar307'::regclass;
select child_name as ar_kept, child_oid as ar_kept_oid from pgpm_test307.ar_names where lo = '20000' \gset
select child_name as ar_sib from pgpm_test307.ar_names where lo = '30000' \gset

select pgpm._enforce_write_blocks('public.ar307');
select format('alter table public.ar307 detach partition public.%I', :'ar_kept') \gexec

select ok(exists (select 1 from pg_trigger where tgrelid = :'ar_kept_oid'::oid and tgname = 'pgpm_write_block' and tgenabled = 'A'),
  'LIVENESS: the detached table carries the block pgpm put on it before the operator detached it');
select ok(not exists (select 1 from pg_inherits where inhparent = 'public.ar307'::regclass
                       and inhrelid = :'ar_kept_oid'::oid),
  'LIVENESS: [20000, 30000) of ar307 is no longer a partition of the table (detached by hand)');

select pgpm._archive_step('public.ar307');

select is((select array_agg(id order by id) from pgpm_test307.handed where child = :'ar_sib'),
  array[35000::bigint],
  'LIVENESS: the archive step handed the attached sibling [30000, 40000) its row 35000');
select is((select count(*) from pgpm_test307.handed where child = :'ar_kept'), 0::bigint,
  'the archive step never hands the operator''s detached table to the strategy');
select is((select array_agg(child_name order by lo::bigint) from pgpm.archive_ledger
            where parent_table = 'public.ar307'::regclass and child_name in (:'ar_kept', :'ar_sib')),
  array[:'ar_sib']::name[],
  'coverage is recorded for the attached sibling and none for the detached table');

-- part B, at archive_batch's default of 1 (#1159): the detached table is left out in the candidate query
-- itself, before `limit`, so the call's one turn goes to the next partition. _archive_hold_partition would
-- refuse the table too once it was picked, but a call that picked it would archive nothing, and since it is
-- the oldest every later call would pick it again: the parent's archiving would stop behind it for good.
create table public.ab307 (id bigint primary key, payload text);
insert into public.ab307 select g, 'base' from generate_series(1, 50) g;
call pgpm.transmute('public.ab307', 'id', 10000, p_retain => 30000, p_paused => false);
select pgpm.obtain('public.ab307');
insert into public.ab307 values (15000, 'next-a'), (17000, 'next-b'), (85000, 'frontier');
select pgpm.set_archive_fn('public.ab307', 'pgpm_test307.recorder(regclass,name,text,text)');
select child_name as ab_old, child_oid as ab_old_oid from pgpm.part where parent_table = 'public.ab307'::regclass and lo = '0' \gset
select child_name as ab_next from pgpm.part where parent_table = 'public.ab307'::regclass and lo = '10000' \gset
select pgpm._enforce_write_blocks('public.ab307');
select format('alter table public.ab307 detach partition public.%I', :'ab_old') \gexec

select ok((select archive_batch = 1 from pgpm.config where parent_table = 'public.ab307'::regclass)
          and exists (select 1 from pg_trigger where tgrelid = :'ab_old_oid'::oid and tgname = 'pgpm_write_block')
          and not exists (select 1 from pg_inherits where inhrelid = :'ab_old_oid'::oid),
  'LIVENESS: at archive_batch 1, the oldest write-blocked partition [0, 10000) of ab307 is detached by hand, block and all');
select is(pgpm._archive_step('public.ab307'), 1, 'one archive step call records one chunk');
select is((select array_agg(child || ':' || id order by id) from pgpm_test307.handed where child in (:'ab_old', :'ab_next')),
  array[:'ab_next' || ':15000', :'ab_next' || ':17000'],
  'and its one turn went to the next partition, [10000, 20000), ids 15000 and 17000, not to the detached table');

-- ============== part C: pgpm's own retirement is still pgpm's (the rule is one-directional) ==============
-- retire() detaches a referenced partition concurrently and marks it retiring_at first; between the detach
-- landing and the DROP the partition stands outside the table and is still pgpm's to block and drop. Here
-- the detach is done directly and the marker set as retire() sets it, without the FK and pg_cron that
-- would bring it about: what is under test is that the write-block step treats such a child as its own.
create table public.rt307 (id bigint primary key, payload text);
insert into public.rt307 select g, 'base' from generate_series(1, 50) g;
call pgpm.transmute('public.rt307', 'id', 10000, p_retain => 30000, p_paused => false);
select pgpm.obtain('public.rt307');
insert into public.rt307 values (25000, 'retiring'), (35000, 'sib-30k'), (85000, 'frontier');
select child_name as rt_ret, child_oid as rt_ret_oid from pgpm.part
 where parent_table = 'public.rt307'::regclass and lo = '20000' \gset
select child_oid as rt_sib_oid from pgpm.part where parent_table = 'public.rt307'::regclass and lo = '30000' \gset
select format('alter table public.rt307 detach partition public.%I', :'rt_ret') \gexec
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = child_oid
 where parent_table = 'public.rt307'::regclass and child_name = :'rt_ret';

select ok(not exists (select 1 from pg_inherits where inhparent = 'public.rt307'::regclass
                       and inhrelid = :'rt_ret_oid'::oid),
  'LIVENESS: the retiring partition is no longer a partition of rt307');
select ok(not exists (select 1 from pg_trigger where tgrelid = :'rt_ret_oid'::oid and tgname = 'pgpm_write_block'),
  'LIVENESS: the retiring partition carries no block before the step');

select pgpm._enforce_write_blocks('public.rt307');

select ok(exists (select 1 from pg_trigger where tgrelid = :'rt_sib_oid'::oid and tgname = 'pgpm_write_block'),
  'LIVENESS: the write-block step blocked the attached sibling [30000, 40000) of rt307');
select ok(exists (select 1 from pg_trigger where tgrelid = :'rt_ret_oid'::oid and tgname = 'pgpm_write_block' and tgenabled = 'A'),
  'a partition pgpm''s own retirement detached (retiring_at set) is still write-blocked by the step');
select throws_like(format('update public.%I set payload = ''late'' where id = 25000', :'rt_ret'),
  '%past its retention boundary%',
  'a write into pgpm''s own retiring partition is refused');

-- ============== part D: a partition dropped by hand keeps its skip_write_block path ==============
-- The relation is gone, so it is not a detached table anyone keeps: the step still tries it, fails on the
-- missing relation and logs skip_write_block over its hi (tests/94), and the rest of the step goes on.
create table public.dr307 (id bigint primary key, payload text);
insert into public.dr307 select g, 'base' from generate_series(1, 50) g;
call pgpm.transmute('public.dr307', 'id', 10000, p_retain => 30000, p_paused => false);
select pgpm.obtain('public.dr307');
insert into public.dr307 values (35000, 'sib-30k'), (85000, 'frontier');
select child_name as dr_gone from pgpm.part where parent_table = 'public.dr307'::regclass and lo = '20000' \gset
select child_oid as dr_sib_oid from pgpm.part where parent_table = 'public.dr307'::regclass and lo = '30000' \gset
select format('drop table public.%I', :'dr_gone') \gexec

select pgpm._enforce_write_blocks('public.dr307');

select is((select array_agg(hi order by hi) from pgpm.log
            where parent_table = 'public.dr307'::regclass and action = 'skip_write_block'),
  array['30000'],
  'a partition dropped by hand is still attempted and logged skip_write_block over its hi');
select ok(exists (select 1 from pg_trigger where tgrelid = :'dr_sib_oid'::oid and tgname = 'pgpm_write_block'),
  'LIVENESS: the step went on past it and blocked the attached sibling [30000, 40000)');
select ok(not exists (select 1 from pgpm.log where action = 'skip_write_block'
                       and parent_table in ('public.wb307'::regclass, 'public.ar307'::regclass, 'public.rt307'::regclass)),
  'no detached partition was reported as a deferral: a hand-detached table is left alone, not attempted');

-- ============== part E: the auto-regrain step does not pick a hand-detached coarse child ==============
-- Two frozen coarse children: the monolith [0, 20000) of ids 1..15000, and [20000, 40000) holding 25000 and
-- 35000, built in place of the empty forward cells [20000, 30000) and [30000, 40000) and recorded in
-- pgpm.part the way obtain records a partition. With both attached, the monolith is the first candidate
-- (oldest first). The operator detaches the monolith to keep its history; auto-regrain must pass it over
-- and work [20000, 40000), not put its capture and TRUNCATE guard on the operator's table, copy its rows,
-- and then fail every swap on it ("is not a partition"), which held auto-regrain on it for good.
create table public.rg307 (id bigint primary key, payload text);
insert into public.rg307 select g, 'hist' from generate_series(1, 15000) g;
call pgpm.transmute('public.rg307', 'id', 10000, p_paused => false);
select pgpm.obtain('public.rg307');
select format('drop table public.%I', child_name) from pgpm.part
 where parent_table = 'public.rg307'::regclass and lo in ('20000', '30000') \gexec
delete from pgpm.part where parent_table = 'public.rg307'::regclass and lo in ('20000', '30000');
create table public.rg307_coarse2 partition of public.rg307 for values from (20000) to (40000);
insert into pgpm.part (parent_table, child_name, lo, hi, attached, child_oid)
  values ('public.rg307'::regclass, 'rg307_coarse2', '20000', '40000', true, 'public.rg307_coarse2'::regclass::oid);
insert into public.rg307 values (25000, 'coarse2-a'), (35000, 'coarse2-b'), (55000, 'frontier');
select child_name as rg_mono, child_oid as rg_mono_oid from pgpm.part
 where parent_table = 'public.rg307'::regclass and lo = '0' \gset

select is((select coarse_frozen from pgpm.progress('public.rg307')), 2::bigint,
  'LIVENESS: with both attached, the monolith [0, 20000) and [20000, 40000) are frozen coarse children');
select is((select array_agg(child_name::text order by lo::bigint) from pgpm.part
            where parent_table = 'public.rg307'::regclass and attached
              and pgpm._native_gt('id', hi, pgpm._grid_next('id', '10000', lo, null))),
  array[:'rg_mono', 'rg307_coarse2'],
  'LIVENESS: the monolith is the oldest coarse child, the one the auto-regrain scan reaches first');

select format('alter table public.rg307 detach partition public.%I', :'rg_mono') \gexec
select pgpm.set_regrain('public.rg307', '5000');

select ok(not exists (select 1 from pg_inherits where inhparent = 'public.rg307'::regclass and inhrelid = :'rg_mono_oid'::oid)
          and (select attached and retiring_at is null from pgpm.part where child_oid = :'rg_mono_oid'::oid),
  'LIVENESS: the monolith is detached by hand, and its pgpm.part row still says attached with no retiring_at');
select is((select coarse_frozen from pgpm.progress('public.rg307')), 1::bigint,
  'progress() counts only [20000, 40000) as a frozen coarse child once the monolith is the operator''s');

call pgpm.maintain('public.rg307');
call pgpm.maintain('public.rg307');
call pgpm.maintain('public.rg307');

select is((select array_agg(lo order by lo) from pgpm.log
            where parent_table = 'public.rg307'::regclass and action = 'regrain_prepare'),
  array['20000'],
  'auto-regrain prepared exactly one run, on [20000, 40000), the next candidate');
select is((select array_agg(tgname::text order by tgname) from pg_trigger
            where tgrelid = 'public.rg307_coarse2'::regclass and not tgisinternal and tgname like 'pgpm%'),
  array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard'],
  'LIVENESS: the run on [20000, 40000) put its capture and TRUNCATE guard on that partition');
select is((select array_agg(tgname::text order by tgname) from pg_trigger
            where tgrelid = :'rg_mono_oid'::oid and not tgisinternal and tgname like 'pgpm%'),
  null,
  'no pgpm trigger (regrain capture or TRUNCATE guard) is put on the operator''s detached monolith');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.rg307'::regclass and not attached
                       and not pgpm._native_gt('id', lo, '20000') and pgpm._native_gt('id', '20000', lo)),
  'no regrain copy of the operator''s detached monolith [0, 20000) is built');
select is((select count(*) from pgpm.log where parent_table = 'public.rg307'::regclass and action = 'skip_regrain'),
  0::bigint,
  'auto-regrain logged no skip_regrain: it is not stuck failing a swap on the detached monolith');
select lives_ok(format('truncate public.%I', :'rg_mono'),
  'the operator can TRUNCATE the table they detached');

-- ============== part F: a regrain in flight when its source is detached by hand is ended ==============
-- Auto-regrain starts on the frozen coarse monolith [0, 20000) of ids 1..15000 (a prepare tick and a copy
-- tick), and the operator then detaches the monolith. The swap needs its source to be a partition and the
-- scan no longer picks the child, so the run would stay in flight for good with pgpm's capture and TRUNCATE
-- guard on the operator's table. The next tick ends it: logged regrain_source_detached once (not
-- regrain_cancel: nobody asked), the triggers off the table, the copies dropped, the cursor cleared, and the
-- table's rows untouched.
create table public.rf307 (id bigint primary key, payload text);
insert into public.rf307 select g, 'hist' from generate_series(1, 15000) g;
call pgpm.transmute('public.rf307', 'id', 10000, p_paused => false);
select pgpm.obtain('public.rf307');
insert into public.rf307 values (55000, 'frontier');
update pgpm.config set regrain_batch = 2000 where parent_table = 'public.rf307'::regclass;
select pgpm.set_regrain('public.rf307', '5000');
select child_name as rf_mono, child_oid as rf_mono_oid from pgpm.part
 where parent_table = 'public.rf307'::regclass and lo = '0' \gset
call pgpm.maintain('public.rf307');
call pgpm.maintain('public.rf307');
create table pgpm_test307.rf_copies as
  select child_name, child_oid from pgpm.part where parent_table = 'public.rf307'::regclass and not attached;

select ok((select regrain_cursor from pgpm.config where parent_table = 'public.rf307'::regclass) is not null,
  'LIVENESS: a regrain of rf307''s monolith is in flight (regrain_cursor set)');
select is((select array_agg(tgname::text order by tgname) from pg_trigger
            where tgrelid = :'rf_mono_oid'::oid and not tgisinternal and tgname like 'pgpm%'),
  array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard'],
  'LIVENESS: the monolith carries the run''s capture and TRUNCATE guard');
select ok((select count(*) from pgpm_test307.rf_copies) > 0
          and (select bool_and(exists (select 1 from pg_class c where c.oid = k.child_oid)) from pgpm_test307.rf_copies k),
  'LIVENESS: the run has built unattached copies, and their tables exist');

select format('alter table public.rf307 detach partition public.%I', :'rf_mono') \gexec
select ok(not exists (select 1 from pg_inherits where inhparent = 'public.rf307'::regclass and inhrelid = :'rf_mono_oid'::oid)
          and (select attached and retiring_at is null from pgpm.part where child_oid = :'rf_mono_oid'::oid),
  'LIVENESS: the monolith is detached by hand mid-run, its pgpm.part row still attached with no retiring_at');

call pgpm.maintain('public.rf307');
call pgpm.maintain('public.rf307');

select is((select array_agg(lo || ':' || hi) from pgpm.log
            where parent_table = 'public.rf307'::regclass and action = 'regrain_source_detached'),
  array['0:20000'],
  'the tick ended the run on the detached source, logged regrain_source_detached once over its range');
select is((select count(*) from pgpm.log where parent_table = 'public.rf307'::regclass and action = 'regrain_cancel'),
  0::bigint,
  'it is not logged as regrain_cancel: no operator asked for a cancel');
select is((select array_agg(tgname::text order by tgname) from pg_trigger
            where tgrelid = :'rf_mono_oid'::oid and not tgisinternal and tgname like 'pgpm%'),
  null,
  'no pgpm trigger is left on the operator''s detached table');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.rf307'::regclass and not attached)
          and not exists (select 1 from pgpm_test307.rf_copies k join pg_class c on c.oid = k.child_oid),
  'no copy of the detached source is left, neither its pgpm.part row nor its table');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rf307'::regclass), null,
  'regrain_cursor is cleared: the run is no longer in flight');
select results_eq(format('select count(*), min(id), max(id) from public.%I', :'rf_mono'),
  $$values (15000::bigint, 1::bigint, 15000::bigint)$$,
  'the detached table keeps exactly its rows 1..15000');
select lives_ok(format('truncate public.%I', :'rf_mono'),
  'the operator can TRUNCATE the table they detached mid-regrain');

select * from finish();
