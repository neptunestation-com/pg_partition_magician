-- scripts/archive_partition_whole.sql leaves a partition the operator DETACHed by hand out of its candidates,
-- as pgpm._archive_step does (issue #1159; #705).
--
-- THE BUG. The operator utility pgpm_archive_next_partition_whole(regclass) picks the oldest write-blocked,
-- uncovered partition with an ATTACHED pgpm.part row, hands its [lo, hi) to the table's archive_fn and writes
-- the pgpm.archive_ledger row that is retire()'s drop precondition. pgpm.part.attached says what pgpm did, not
-- what the catalog holds, and an operator's own ALTER TABLE ... DETACH PARTITION never touches it, so a table
-- detached by hand (still carrying pgpm's write block) was a candidate. A strategy reading the range through
-- the parent, as pgpm_archive's transports do, found none of the detached table's rows there, returned
-- covered_hi = hi, and the script recorded [lo, hi) as covered with 0 rows. Once the operator attached the
-- table back (the remedy docs/reference.md gives), retain() dropped it with rows nothing had archived.
-- _archive_step has left such a table out since #705 (pgpm._part_detached_by_hand); the script's candidate
-- query never got the predicate.
--
-- THE CONTRACT. The script's candidates are _archive_step's: a table detached by hand is not one. It is never
-- handed to the strategy and no coverage is recorded for it, and because it is left out in the WHERE clause,
-- before `limit 1`, the call goes to the parent's next eligible partition instead of to nothing.
--   PART A  [0, 100) (ids 7, 42, 88) detached by hand, [100, 200) (ids 150, 160) attached, both write-blocked
--           and uncovered. The first call archives [100, 200), by name, and the strategy saw 150 and 160; the
--           second call finds nothing eligible. No ledger row and no strategy call name [0, 100).
--   PART B  CONTROL for A: the operator attaches [0, 100) back, and the next call archives it, the strategy
--           seeing 7, 42 and 88 through the parent. So A's skip is the detach, not something about the
--           partition, and the table is archived (and so retire()'s drop gate opened) only once its rows are
--           back where the strategy reads them.
--
-- ASYMMETRIC FIXTURES. 3 rows in the detached partition, 2 in the attached one, every strategy call recorded
-- with the ids it read, so what each call was handed is read back by identity.
--
-- bench/archive_whole_skips_hand_detached.sh runs this file against the script with bench/mutations/mutate.py's
-- archive_whole_trusts_part_attached. The script's path is the psql variable archive_whole_script, defaulting
-- to the tree's copy, so the guard can point it at a mutant.
create extension if not exists pgtap;
set client_min_messages = warning;

\if :{?archive_whole_script}
\else
\set archive_whole_script /repo/scripts/archive_partition_whole.sql
\endif
\i :archive_whole_script

select plan(11);

create schema t313;
create table t313.calls (n serial primary key, p_child name, p_lo text, p_hi text, seen text);

-- reads [lo, hi) through the PARENT, as pgpm_archive's archive_to_s3_* do, and records what it saw
create function t313.via_parent(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_seen text; v_n bigint;
begin
  execute format('select string_agg(id::text, '','' order by id), count(*) from %s where id >= %L::bigint and id < %L::bigint',
                 p_parent, p_lo, p_hi)
    into v_seen, v_n;
  insert into t313.calls (p_child, p_lo, p_hi, seen) values (p_child, p_lo, p_hi, coalesce(v_seen, 'none'));
  v.covered_hi := p_hi; v.rows_archived := v_n; v.s3_key := 't313/' || p_lo;
  return v;
end $$;

create table public.t313_ev (id bigint primary key, payload text);
insert into public.t313_ev values (7, 'a'), (42, 'b'), (88, 'c');
call pgpm.transmute('public.t313_ev', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.t313_ev values (150, 'd'), (160, 'e');
insert into public.t313_ev values (500, 'frontier');   -- horizon 200: [0, 100) and [100, 200) write-blocked
select pgpm._enforce_write_blocks('public.t313_ev');
select pgpm.set_archive_fn('public.t313_ev', 't313.via_parent(regclass,name,text,text)'::regprocedure);
select child_name as p0   from pgpm.part where parent_table = 'public.t313_ev'::regclass and lo = '0'   \gset
select child_name as p100 from pgpm.part where parent_table = 'public.t313_ev'::regclass and lo = '100' \gset

select ok(pgpm._is_write_blocked('public.t313_ev', :'p0') and pgpm._is_write_blocked('public.t313_ev', :'p100')
          and not pgpm._archive_fully_covered('public.t313_ev', :'p0')
          and not pgpm._archive_fully_covered('public.t313_ev', :'p100'),
  'LIVENESS: [0, 100) and [100, 200) are both write-blocked and uncovered, so both are candidates');

-- ---------------------------------------------------------------- PART A: the operator detaches the older one
select format('alter table public.t313_ev detach partition public.%I', :'p0') as detach_sql \gset
:detach_sql;

select ok((select p.attached and pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
             from pgpm.part p where p.parent_table = 'public.t313_ev'::regclass and p.child_name = :'p0')
          and pgpm._is_write_blocked('public.t313_ev', :'p0'),
  'LIVENESS: A: [0, 100) is detached by hand, keeps its attached pgpm.part row and pgpm''s write block');
select format('select string_agg(id::text, '','' order by id) as p0_ids from public.%I', :'p0') as p0_ids_sql \gset
:p0_ids_sql \gset
select is(:'p0_ids'::text, '7,42,88',
  'LIVENESS: A: the detached table holds ids 7, 42 and 88, which a read through the parent no longer finds');

select pgpm_archive_next_partition_whole('public.t313_ev'::regclass) as msg_a1 \gset
select diag('A: ' || :'msg_a1');
select pgpm_archive_next_partition_whole('public.t313_ev'::regclass) as msg_a2 \gset

select results_eq($$ select p_child, p_lo, p_hi, seen from t313.calls order by n $$,
  format($$ values (%L::name, '100'::text, '200'::text, '150,160'::text) $$, :'p100'),
  'A: the strategy was handed [100, 200) alone, and read ids 150 and 160 through the parent');
select results_eq($$ select child_name, lo, hi, rows_archived from pgpm.archive_ledger
                      where parent_table = 'public.t313_ev'::regclass order by lo::bigint $$,
  format($$ values (%L::name, '100'::text, '200'::text, 2::bigint) $$, :'p100'),
  'A: the ledger covers [100, 200) with its 2 rows, and nothing else');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.t313_ev'::regclass
                            and child_name = %L $$, :'p0'),
  'A: no coverage is recorded for the table detached by hand');
select is(:'msg_a2'::text, format('nothing eligible left to archive for %s', 'public.t313_ev'::regclass),
  'A: with [100, 200) archived, the second call finds nothing eligible: the detached table is not a candidate');
select ok(not pgpm._archive_fully_covered('public.t313_ev', :'p0'),
  'A: retire()''s drop gate stays shut on [0, 100)');

-- ---------------------------------------------------------------- PART B (control): attached back, it is archived
select format('alter table public.t313_ev attach partition public.%I for values from (0) to (100)', :'p0') as attach_sql \gset
:attach_sql;
select ok(not (select pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
                 from pgpm.part p where p.parent_table = 'public.t313_ev'::regclass and p.child_name = :'p0'),
  'LIVENESS: B: the operator attached [0, 100) back, so it is not detached by hand any more');

select pgpm_archive_next_partition_whole('public.t313_ev'::regclass) as msg_b \gset
select diag('B: ' || :'msg_b');

select results_eq($$ select p_child, p_lo, p_hi, seen from t313.calls order by n $$,
  format($$ values (%L::name, '100'::text, '200'::text, '150,160'::text), (%L::name, '0'::text, '100'::text, '7,42,88'::text) $$,
         :'p100', :'p0'),
  'B: the next call handed [0, 100) to the strategy, which read ids 7, 42 and 88 through the parent');
select results_eq($$ select child_name, lo, hi, rows_archived from pgpm.archive_ledger
                      where parent_table = 'public.t313_ev'::regclass order by lo::bigint $$,
  format($$ values (%L::name, '0'::text, '100'::text, 3::bigint), (%L::name, '100'::text, '200'::text, 2::bigint) $$,
         :'p0', :'p100'),
  'B: the ledger covers [0, 100) with its 3 rows, beside [100, 200)');

select * from finish();
