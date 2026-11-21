-- An idle archive step reads a bounded slice of the ledger, and obtain's stand-in lookup a bounded slice of the log
-- (issues #1219 and #1038, its last bullet).
--
-- THE GAPS.
--   A (#1219). Before anything else, every _archive_step call (every tick of a parent with an archive_fn) runs
--       _mark_gone_chunks(p_parent) and the #511 orphan-discard query. Both read the parent's ledger rows that are
--       NOT retired, but no index has that shape: they reached the rows through the (parent_table, lo) key, or a
--       sequential scan, and visited every retired row too. A retired row is never discarded (it is the record of
--       the only copy), so an idle tick's cost grew with the parent's whole archive history.
--   B (#1038). _obtain_name's stand-in lookup asks pgpm.log whether a relation holding a cell's plain name is a
--       partition pgpm forgot (forget_detached_partition, by parent_table and action), and pgpm.log, append-only and
--       never pruned, had no index but its identity key: the lookup read the whole log, and when obtain had already
--       built a cell earlier in the same call it did so holding ACCESS EXCLUSIVE on the parent.
--
-- THE CONTRACT. archive_ledger has a partial index on (parent_table, child_name) over the rows not retired, and
-- pgpm.log one on (parent_table, action); with them an idle archive step and the stand-in lookup each read a handful
-- of tuples whatever the history holds, and both still find what they exist to find.
--
-- THE INSTRUMENT is tests/317's: pg_stat_get_xact_tuples_returned/_fetched over the table and its indexes, read
-- before and after the call inside one function, so in the same transaction (the cumulative counters flush only at
-- transaction end; the xact ones count as the scan runs). Its liveness: a plain read of the history moves it by at
-- least the history's size. Parallel workers are off, so every scan is the leader's own and counted.
create extension if not exists pgtap;
set client_min_messages = warning;
set max_parallel_workers_per_gather = 0;
select plan(11);

create schema t391;

-- tuples read so far in this transaction from p_table (heap rows returned or fetched, index entries returned)
create function t391.counter(p_table regclass) returns bigint language sql volatile as $$
  select pg_stat_get_xact_tuples_returned(p_table) + pg_stat_get_xact_tuples_fetched(p_table)
       + coalesce((select sum(pg_stat_get_xact_tuples_returned(i.indexrelid))::bigint
                     from pg_index i where i.indrelid = p_table), 0);
$$;
-- run p_sql and say how many tuples of p_table it read, in one transaction
create function t391.reads_of(p_table regclass, p_sql text) returns bigint language plpgsql as $$
declare v_before bigint := t391.counter(p_table);
begin
  execute p_sql;
  return t391.counter(p_table) - v_before;
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- A. 30,000 retired chunks far below every attached partition, and two live rows the two reads exist for: a chunk of
-- a relation that is gone (_mark_gone_chunks marks it retired) and a chunk under a name no partition has, of a
-- relation that exists, over [0, 100)'s range (the orphan query discards it).
create table t391.a (id bigint primary key, payload text not null);
insert into t391.a select g, 'old' || g from generate_series(1, 90) g;
select pgpm_formal.baseline('t391.a');   -- the invariant oracle's row ledger (docs/formal/phase3-design.md)
call pgpm.transmute('t391.a', 'id', 100, p_retain => 100::bigint, p_paused => true);
insert into t391.a values (450, 'frontier');
select pgpm_formal.wrote('t391.a', 'id = 450');
select pgpm.set_archive_fn('t391.a', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
create table t391.elsewhere (id bigint);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, retired_at, child_oid)
select 't391.a'::regclass, (-1000000 + g)::text, (-1000000 + g + 1)::text, 'gone_' || (g / 100), now(), 4000000000 + g
  from generate_series(0, 29999) g;
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid) values
  ('t391.a', '-2000000', '-1999999', 'gone_live', 1, 4100000000),
  ('t391.a', '0', '50', 'renamed_away', 3, 't391.elsewhere'::regclass::oid);
analyze pgpm.archive_ledger;

select cmp_ok(t391.reads_of('pgpm.archive_ledger', $$select count(*) from pgpm.archive_ledger
                                                     where parent_table = 't391.a'::regclass and retired_at is not null$$),
              '>=', 30000::bigint,
  'LIVENESS: 30,000 retired chunks are recorded for t391.a, and the instrument sees a read of them');
select ok(not exists (select 1 from pgpm.part p where p.parent_table = 't391.a'::regclass and p.attached
                        and pgpm._is_write_blocked('t391.a', p.child_name)),
  'LIVENESS: no partition of t391.a is write-blocked, so the step has nothing to archive (an idle tick)');

create table t391.a_reads as
  select t391.reads_of('pgpm.archive_ledger', $$select pgpm._archive_step('t391.a')$$) as n;

select is((select array_agg(format('%s %s', child_name, case when retired_at is null then 'live' else 'retired' end)
                            order by lo::numeric)
             from pgpm.archive_ledger where parent_table = 't391.a'::regclass and child_name in ('gone_live', 'renamed_away')),
  array['gone_live retired'],
  'LIVENESS: the step''s two reads did their work: the gone relation''s chunk is marked retired, the orphan discarded');
select is((select array_agg(action || ' ' || lo || ' ' || hi order by id) from pgpm.log
            where parent_table = 't391.a'::regclass and action in ('archive_chunk_retired', 'archive_coverage_reset')),
  array['archive_chunk_retired -2000000 -1999999', 'archive_coverage_reset 0 50'],
  'LIVENESS: and logged each, by its range');
select cmp_ok((select n from t391.a_reads), '<', 1000::bigint,
  'an idle archive step reads a bounded slice of the ledger, not every retired chunk of the parent');
select ok(exists (select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
                   where i.indrelid = 'pgpm.archive_ledger'::regclass and c.relname = 'archive_ledger_live_child_idx'
                     and pg_get_expr(i.indpred, i.indrelid) = '(retired_at IS NULL)'),
  'archive_ledger_live_child_idx is partial, over the rows not retired');

-- ---------------------------------------------------------------------------------------------------------------
-- B. The #1038 fixture: monolith [0, 100), forward [100, 400); a view squats the plain name of [500, 600); frontier
-- 350, so one obtain builds [400, 500) (taking the parent's ACCESS EXCLUSIVE) and then meets the held name. The log
-- holds 100,000 rows of another table's history (it is shared and never pruned), and one forget_detached_partition
-- row of this parent's, for another relation, so the lookup has a row of its own kind to read past.
create table t391.ob (id bigint primary key, v text);
insert into t391.ob values (5, 'a'), (50, 'b');
select pgpm_formal.baseline('t391.ob');
call pgpm.transmute('t391.ob', 'id', 100, p_obtain => 3);
create view t391.ob_p0000000000000000500 as select 1 as squatter;
insert into t391.ob values (350, 'c');
select pgpm_formal.wrote('t391.ob', 'id = 350');
create table t391.other (id bigint);
insert into pgpm.log (parent_table, action, lo, hi, method)
  select 't391.other'::regclass, 'skip_obtain', g::text, g::text, repeat('x', 60) from generate_series(1, 100000) g;
insert into pgpm.log (parent_table, action, lo, hi, method)
  values ('t391.ob', 'forget_detached_partition', '900', '1000', 'forgot t391.gone (oid 4200000000)');
analyze pgpm.log;

select cmp_ok(t391.reads_of('pgpm.log', $$select count(*) from pgpm.log where method like 'x%'$$), '>=', 100000::bigint,
  'LIVENESS: the log holds 100,000 rows of another table''s history, and the instrument sees a read of them');

create table t391.ob_reads as select t391.reads_of('pgpm.log', $$select pgpm.obtain('t391.ob')$$) as n;

select is((select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = 't391.ob'::regclass and attached),
  array['0', '100', '200', '300', '400', '600'],
  'LIVENESS: obtain built [400, 500) before the held [500, 600), and [600, 700) after it');
select is((select array_agg(lo || '|' || hi) from pgpm.log where parent_table = 't391.ob'::regclass and action = 'fail_obtain_name'),
  array['500|600'], 'LIVENESS: the held name is the one it met, so the stand-in lookup ran');
select cmp_ok((select n from t391.ob_reads), '<', 1000::bigint,
  'the stand-in lookup reads a bounded slice of the log, not the whole of it');
select ok(exists (select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
                   where i.indrelid = 'pgpm.log'::regclass and c.relname = 'log_parent_action_idx'),
  'pgpm.log has its (parent_table, action) index');
select * from finish();
