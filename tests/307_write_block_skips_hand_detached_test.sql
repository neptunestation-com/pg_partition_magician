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
select plan(26);

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

select * from finish();
