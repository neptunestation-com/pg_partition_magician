-- scripts/archive_partition_whole.sql picks, resumes and resolves a partition as pgpm._archive_step does
-- (issue #1054, bullets 1 to 3).
--
-- THE BUGS. The operator utility pgpm_archive_next_partition_whole(regclass) archives one write-blocked,
-- uncovered partition per call and writes a pgpm.archive_ledger row, retire()'s drop precondition. Three of
-- its steps had drifted from the shipped archiver's:
--   1. it ordered the candidates by pgpm.part.lo as TEXT, so on an id grid crossing a power of ten its third
--      call archived [1000, 1100) ahead of the older [200, 300), though its header promises the OLDEST;
--   2. it read its resume watermark as max(hi::<type>)::text, rendered in the CALLER's DateStyle, and wrote
--      that text as the next ledger row's lo: a call under 'SQL, DMY' wrote '13/08/2020 12:00:00 UTC', and
--      once retire() had dropped the partition (its chunks stay in the ledger) _archive_step's #511 discard
--      query cast that lo under the default DateStyle and raised 22008, so maintain() logged skip_archive on
--      every tick and the next write-blocked partition was never archived again;
--   3. it resolved the partition in the PARENT's schema, so after ALTER TABLE <parent> SET SCHEMA (which
--      moves the parent alone) its identity check found nothing under the name and refused the intact,
--      recorded partition, telling the operator to clear its pgpm.part row.
--
-- THE CONTRACT. The script does what _archive_step does at each of those steps:
--   PART A  candidates in the control's native order (pgpm._native_type): three calls archive [0, 100),
--           [100, 200) and [200, 300), named, while [1000, 1100) is a candidate too and stays uncovered.
--   PART B  the watermark through pgpm._max_hi_native, so the ledger lo a call under 'SQL, DMY' writes is the
--           canonical text of the instant (_ts_text), the strategy is handed that text, and after retire()
--           the next maintain() tick archives the next write-blocked partition with no skip_archive.
--   PART C  the partition's schema through pgpm._child_nsp (#727): after the parent moves, the partition
--           that stayed behind is archived, its ledger row names the relation pgpm.part recorded, and the
--           strategy read that relation's rows.
--   PART D  CONTROL for C: the identity check is still made in the partition's own schema. A moved parent's
--           partition renamed aside, with a decoy put under its name there, is refused: no strategy call, no
--           ledger row, the decoy's oid named in the message. So C passing is the resolution, not a check
--           that no longer refuses anything.
--
-- ASYMMETRIC FIXTURES. A: ids 7, 250, 260 and 1050 over four partitions, 1 + 0 + 2 archived and 1 left. B: three
-- rows of August 2020, 2 before the first call's covered_hi and 1 after. C: ids 2, 5 and 9 in the moved
-- partition. Every strategy records the calls it gets, so what each was handed is read back by identity.
--
-- bench/archive_partition_whole_follows_step.sh runs this file against the script with bench/mutations/mutate.py's
-- archive_whole_order_by_text, archive_whole_resume_session_render and archive_whole_parent_schema, one per
-- bullet. The script's path is the psql variable archive_whole_script, defaulting to the tree's copy, so the
-- guard can point it at a mutant.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
set datestyle = 'ISO, MDY';

\if :{?archive_whole_script}
\else
\set archive_whole_script /repo/scripts/archive_partition_whole.sql
\endif
\i :archive_whole_script

select plan(20);

create schema t289;
create table t289.calls (n serial primary key, strategy text, p_child name, p_lo text, p_hi text, seen text);

-- ---------------------------------------------------------------- PART A: oldest first, natively
create function t289.ord(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into t289.calls (strategy, p_child, p_lo, p_hi) values ('ord', p_child, p_lo, p_hi);
  v.covered_hi := p_hi; v.rows_archived := 0; return v;
end $$;

create table public.t289_ord (id bigint primary key, payload text);
insert into public.t289_ord values (7, 'a');
call pgpm.transmute('public.t289_ord', 'id', 100, p_retain => 1000, p_paused => false);
insert into public.t289_ord values (250, 'b'), (260, 'c'), (1050, 'd');
insert into public.t289_ord values (2150, 'frontier');   -- horizon 1150: [0, 100) to [1000, 1100) write-blocked
select pgpm._enforce_write_blocks('public.t289_ord');
select pgpm.set_archive_fn('public.t289_ord', 't289.ord(regclass,name,text,text)'::regprocedure);
select child_name as ord0    from pgpm.part where parent_table = 'public.t289_ord'::regclass and lo = '0'    \gset
select child_name as ord100  from pgpm.part where parent_table = 'public.t289_ord'::regclass and lo = '100'  \gset
select child_name as ord200  from pgpm.part where parent_table = 'public.t289_ord'::regclass and lo = '200'  \gset
select child_name as ord1000 from pgpm.part where parent_table = 'public.t289_ord'::regclass and lo = '1000' \gset

select ok(pgpm._is_write_blocked('public.t289_ord', :'ord200') and pgpm._is_write_blocked('public.t289_ord', :'ord1000')
          and not pgpm._archive_fully_covered('public.t289_ord', :'ord200')
          and not pgpm._archive_fully_covered('public.t289_ord', :'ord1000'),
  'LIVENESS: A: [200, 300) and [1000, 1100) are both write-blocked and uncovered, so both are candidates');

select pgpm_archive_next_partition_whole('public.t289_ord'::regclass) as msg_ord1 \gset
select pgpm_archive_next_partition_whole('public.t289_ord'::regclass) as msg_ord2 \gset
select pgpm_archive_next_partition_whole('public.t289_ord'::regclass) as msg_ord3 \gset
select diag('A: ' || :'msg_ord3');

select results_eq($$ select p_child, p_lo, p_hi from t289.calls where strategy = 'ord' order by n $$,
  format($$ values (%L::name, '0'::text, '100'::text), (%L::name, '100'::text, '200'::text), (%L::name, '200'::text, '300'::text) $$,
         :'ord0', :'ord100', :'ord200'),
  'A: the three calls archived [0, 100), [100, 200) and [200, 300), oldest first, in that order');
select ok(not pgpm._archive_fully_covered('public.t289_ord', :'ord1000'),
  'A: the newer [1000, 1100) was not archived ahead of [200, 300)');
select ok(pgpm._is_write_blocked('public.t289_ord', :'ord1000'),
  'LIVENESS: A: [1000, 1100) is still a candidate the next call will reach');

-- ---------------------------------------------------------------- PART B: a resumed call under SQL, DMY
-- The first call for a partition covers up to 2020-08-13 12:00 UTC (a day above 12, so a DMY rendering of it
-- is no valid MDY date); every later call covers the whole range it is handed.
create function t289.resume(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into t289.calls (strategy, p_child, p_lo, p_hi) values ('resume', p_child, p_lo, p_hi);
  if (select count(*) from t289.calls where strategy = 'resume') = 1 then
    v.covered_hi := '2020-08-13 12:00:00+00';
  else
    v.covered_hi := p_hi;
  end if;
  v.rows_archived := 1;
  return v;
end $$;

create table public.t289_ts (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into public.t289_ts (ts) values ('2020-08-10 09:00+00'), ('2020-08-12 09:00+00'), ('2020-08-20 09:00+00');
call pgpm.transmute('public.t289_ts', 'ts', interval '1 second', p_obtain => 2, p_retain => interval '0 seconds', p_paused => false);
select pg_sleep(2.5);   -- the monolith and the first grid cells age past a retain of 0 on the 1 s grid
select pgpm._enforce_write_blocks('public.t289_ts');
select pgpm.set_archive_fn('public.t289_ts', 't289.resume(regclass,name,text,text)'::regprocedure);
-- filtered by parent before any bound is cast (#973)
select child_name as mono from (
  with mine as materialized (select p.child_name, p.lo from pgpm.part p
                              where p.parent_table = 'public.t289_ts'::regclass and p.attached)
  select child_name from mine order by lo::timestamptz limit 1) s \gset
select pgpm._ts_text('2020-08-13 12:00:00+00') as mark \gset

select ok(pgpm._is_write_blocked('public.t289_ts', :'mono')
          and (select lo::timestamptz < :'mark'::timestamptz and hi::timestamptz > :'mark'::timestamptz
                 from pgpm.part where parent_table = 'public.t289_ts'::regclass and child_name = :'mono'),
  'LIVENESS: B: the oldest write-blocked partition spans 2020-08-13 12:00 UTC');

select pgpm_archive_next_partition_whole('public.t289_ts'::regclass) as msg_b1 \gset
set datestyle = 'SQL, DMY';
select pgpm_archive_next_partition_whole('public.t289_ts'::regclass) as msg_b2 \gset
set datestyle = 'ISO, MDY';
select diag('B: ' || :'msg_b1' || ' / ' || :'msg_b2');

select ok(:'msg_b1' like '%PARTIAL only%', 'LIVENESS: B: the first call covered part of the partition');
select results_eq(
  format($$ select lo, hi from pgpm.archive_ledger
             where parent_table = 'public.t289_ts'::regclass and child_name = %L order by archived_at $$, :'mono'),
  format($$ select p.lo, %L::text from pgpm.part p where p.parent_table = 'public.t289_ts'::regclass and p.child_name = %L
            union all
            select %1$L::text, p.hi from pgpm.part p where p.parent_table = 'public.t289_ts'::regclass and p.child_name = %2$L $$,
         :'mark', :'mono'),
  'B: the call under SQL, DMY recorded its chunk from the canonical text of 2020-08-13 12:00 UTC, not the caller''s rendering');
select is((select p_lo from t289.calls where strategy = 'resume' order by n offset 1 limit 1), :'mark',
  'B: and handed the strategy that canonical text as the chunk''s lo');

select ok(pgpm.retire('public.t289_ts', :'mono'),
  'LIVENESS: B: retire() dropped the covered partition, leaving its two chunks under a name no longer tracked');
select coalesce((
  with mine as materialized (select p.child_name, p.lo from pgpm.part p
                              where p.parent_table = 'public.t289_ts'::regclass and p.attached)
  select child_name from mine
   where pgpm._is_write_blocked('public.t289_ts', child_name)
     and not pgpm._archive_fully_covered('public.t289_ts', child_name)
   order by lo::timestamptz limit 1), '') as next_ts \gset
select ok(:'next_ts' <> '', 'LIVENESS: B: another write-blocked partition is waiting to be archived');

call pgpm.maintain('public.t289_ts');

select ok(exists (select 1 from pgpm.archive_ledger
                   where parent_table = 'public.t289_ts'::regclass and child_name = :'next_ts'),
  'B: the next maintain() tick archived that partition');
select is_empty($$ select method from pgpm.log where parent_table = 'public.t289_ts'::regclass and action = 'skip_archive' $$,
  'B: and no tick deferred this parent''s archiving');

-- ---------------------------------------------------------------- PART C: the parent moved, the partition did not
-- Reads the chunk through the parent, as pgpm_archive's transports do, and records which ids it read.
create function t289.read(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_seen text;
begin
  execute format('select array_agg(id order by id)::text from %s where id >= %s and id < %s', p_parent, p_lo, p_hi)
    into v_seen;
  insert into t289.calls (strategy, p_child, p_lo, p_hi, seen) values ('read', p_child, p_lo, p_hi, v_seen);
  v.covered_hi := p_hi; v.rows_archived := 3; return v;
end $$;

create schema t289_moved;
create table public.t289_mv (id bigint primary key, payload text);
insert into public.t289_mv values (2, 'a'), (5, 'b'), (9, 'c');
call pgpm.transmute('public.t289_mv', 'id', 1000, p_retain => 19000, p_paused => false);
insert into public.t289_mv values (20000, 'frontier');
select pgpm._enforce_write_blocks('public.t289_mv');
select pgpm.set_archive_fn('public.t289_mv', 't289.read(regclass,name,text,text)'::regprocedure);
select child_name as mv, child_oid as mv_oid from pgpm.part where parent_table = 'public.t289_mv'::regclass and lo = '0' \gset
alter table public.t289_mv set schema t289_moved;

select ok(to_regclass(format('public.%I', :'mv'))::oid = :'mv_oid'::oid
          and to_regclass(format('t289_moved.%I', :'mv')) is null
          and pgpm._is_write_blocked('t289_moved.t289_mv', :'mv')
          and not pgpm._archive_fully_covered('t289_moved.t289_mv', :'mv'),
  'LIVENESS: C: the parent moved to t289_moved, its recorded partition stayed in public, write-blocked and uncovered');

select pgpm_archive_next_partition_whole('t289_moved.t289_mv'::regclass) as msg_mv \gset
select diag('C: ' || :'msg_mv');

select results_eq($$ select p_child, p_lo, p_hi, seen from t289.calls where strategy = 'read' $$,
  format($$ values (%L::name, '0'::text, '1000'::text, '{2,5,9}'::text) $$, :'mv'),
  'C: the strategy was handed the recorded partition''s [0, 1000) and read ids 2, 5 and 9');
select results_eq(
  $$ select lo, hi, child_name, to_regclass(format('public.%I', child_name))::oid from pgpm.archive_ledger
      where parent_table = 't289_moved.t289_mv'::regclass $$,
  format($$ values ('0'::text, '1000'::text, %L::name, %s::oid) $$, :'mv', :'mv_oid'),
  'C: one ledger row covers [0, 1000) for the relation pgpm.part recorded, by oid');
select ok(:'msg_mv' like '%fully archived in one file (3 rows%', 'C: and the message says so');

-- ---------------------------------------------------------------- PART D: CONTROL, a decoy in the partition's schema
create table public.t289_dc (id bigint primary key, payload text);
insert into public.t289_dc values (4, 'a'), (8, 'b');
call pgpm.transmute('public.t289_dc', 'id', 1000, p_retain => 19000, p_paused => false);
insert into public.t289_dc values (20000, 'frontier');
select pgpm._enforce_write_blocks('public.t289_dc');
select pgpm.set_archive_fn('public.t289_dc', 't289.read(regclass,name,text,text)'::regprocedure);
select child_name as dc, child_oid as dc_oid from pgpm.part where parent_table = 'public.t289_dc'::regclass and lo = '0' \gset
alter table public.t289_dc set schema t289_moved;
-- the recorded partition renamed aside in its own schema, and a write-blocked decoy put under its name there
select format('alter table public.%I rename to t289_dc_kept', :'dc') \gexec
select format('create table public.%I (id bigint, payload text)', :'dc') \gexec
select format($$ create trigger pgpm_write_block before insert or update or delete
                   on public.%I for each row execute function pgpm._write_block_raise() $$, :'dc') \gexec
select format('alter table public.%I enable always trigger pgpm_write_block', :'dc') \gexec
select format('public.%I', :'dc')::regclass::oid as dc_decoy \gset

select ok(pgpm._is_write_blocked('t289_moved.t289_dc', :'dc')
          and not pgpm._archive_fully_covered('t289_moved.t289_dc', :'dc')
          and to_regclass('public.t289_dc_kept')::oid = :'dc_oid'::oid,
  'LIVENESS: D: the decoy is a write-blocked, uncovered candidate, and the recorded partition sits aside');

select pgpm_archive_next_partition_whole('t289_moved.t289_dc'::regclass) as msg_dc \gset
select diag('D: ' || :'msg_dc');

select ok(:'msg_dc' like format('%%public.%s is oid %s now, not the oid %s recorded%%REFUSING%%', :'dc', :'dc_decoy', :'dc_oid'),
  'D: the script refuses the decoy it found under the name in the partition''s own schema, naming both oids');
select is_empty(format($$ select 1 from t289.calls where strategy = 'read' and p_child = %L $$, :'dc'),
  'D: the strategy was never called for the decoy');
select is_empty($$ select 1 from pgpm.archive_ledger where parent_table = 't289_moved.t289_dc'::regclass $$,
  'D: and nothing was recorded for it');

select * from finish();
