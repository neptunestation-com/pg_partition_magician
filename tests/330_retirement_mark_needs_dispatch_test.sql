-- A retirement mark vouches for a retirement of pgpm's own only with the record of pgpm's dispatch, at every
-- reader of the mark (issue #1259).
--
-- retire() stamps pgpm.part.retiring_at BEFORE it dispatches the concurrent detach, so a dispatch that fails (no
-- pg_cron here) leaves the mark on a partition pgpm never asked anything to detach. #705/#1250 taught retire(),
-- _detach_reap, _retain_recall and the install's pass that such a mark vouches for nothing: only
-- pgpm.part.detach_dispatched_oid, written in the dispatch's own transaction, says the detach was pgpm's
-- (_detach_dispatched). The other readers went on vouching for the mark by itself: _part_built (and through it
-- _part_detached_by_hand, which _enforce_write_blocks, _archive_step's candidate query, the auto-regrain scan,
-- progress() and scripts/archive_partition_whole.sql ask) and _archive_hold_partition. So once the operator
-- detached such a partition by hand, the next maintain() tick (its archive step runs before retain()) handed the
-- operator's table to the archive strategy and recorded coverage for it, in the very tick retire() disowned the
-- mark (retain_disown). A strategy reading through the parent, as pgpm_archive's transports do, found none of its
-- rows; when the operator took the documented remedy (attach it back, so retention retires it), retention dropped
-- it on that false coverage and its rows were in neither the table nor the archive. They now share one rule,
-- pgpm._retirement_vouched, built on _detach_dispatched.
--
--   A  the issue's acceptance flow through maintain(): the failed dispatch, the hand detach, the archive step
--      leaving the operator's table alone, and the reattach archiving ids 1, 2 and 15 before the drop.
--   B  the shared predicates, both directions, over three detached partitions of one parent: one whose mark
--      carries the record of pgpm's dispatch (pgpm's own retirement, still pgpm's), one whose mark carries
--      none (a failed dispatch) and one whose record names another relation. Only the first is built, only the
--      other two are detached by hand, the archive hold holds none of the three (only the attached sibling), and
--      the write-block step blocks the first and the attached sibling, never the other two.
--   C  scripts/archive_partition_whole.sql over a table detached by hand under a mark with no record: never
--      handed to the strategy, no coverage recorded, while the attached partition after it is archived.
--   D  the converse state (the per-PR verification's V-01): a mark WITH its record, pgpm's own detach landed, and
--      archiving configured only after the mark: the detached table is still pgpm's, but no strategy reading
--      through the parent can read it, so it is not handed off, nothing is recorded, retire() keeps it, the step
--      logs skip_archive with the remedy, and the remedy as typed archives its rows before the drop.
--   E  an unanchored, unmarked row (the state an upgrade from before #421 leaves) over a table the operator
--      detached by hand: not handed to the strategy, nothing recorded, kept, skip_archive with the remedy, and the
--      remedy as typed (attach it back, adopt_partition) archives its rows before the drop.
--   F  a DETACH PARTITION ... CONCURRENTLY that commits its first transaction UNDER the archive hold, through
--      maintain() (round 4; V-01 and V-02): ACCESS SHARE does not keep it from starting, and a read through the
--      parent planned after it sees none of the partition's rows. The hold is asked again after the strategy
--      returns: nothing is recorded for the monolith, the same step records [20, 30), skip_archive gives the
--      remedy, and the remedy as typed archives ids 1, 2 and 15 before the drop.
--   G  the same race through scripts/archive_partition_whole.sql: the call returns the reason, nothing recorded.
--   H  a chunk of 0 rows recorded for a table detached by hand (what an install before these fixes left; V-03),
--      the table then attached back: retire() does not drop it on that chunk, because the partition holds rows in
--      the chunk's range; it discards the coverage, and the next tick archives ids 1, 2 and 15 before the drop.
--   I  what that check leaves alone (a 0-row chunk over a range that holds no row: dropped as before), what it
--      discards with a false chunk (the partition's whole coverage), and a direct retire() call.
--   J  a strategy that archives everything and reports 0 instead of counting: the partition is kept, and the
--      archive_coverage_reset row names that cause and its remedy (report null when you do not count); the remedy
--      as typed (the strategy replaced to report null) lets retention retire the partition.
--
-- F and G need two more sessions, through dblink as tests/325 does: a TICK connection runs the call
-- asynchronously; its strategy takes an advisory lock (so this session sees it inside the strategy) and waits at
-- a gate; a DETACH connection runs the detach; this session polls pg_inherits until the first transaction has
-- committed, then opens the gate. No sleep is load-bearing: the read happens only once the gate is open.
--
-- Identity, not cardinality: every assertion names which partition (by its range) or which ids. Fixtures are
-- asymmetric: three ids in the operator's table against one in the archived sibling (A, F), one vouched mark
-- against two unvouched (B), three ids against two (C), one partition dropped with three chunks kept against one
-- kept with two chunks discarded (I).
--
-- bench/retirement_mark_needs_dispatch.sh runs this file against bench/mutations/mutate.py's
-- retirement_mark_vouches_alone (part B), archive_hold_vouches_detached_retirement (parts B and D),
-- retirement_mark_readers_whole (parts A to D), archive_hold_passes_unanchored (part E),
-- archive_step_records_without_second_ask (part F), archive_whole_records_without_second_ask (part G),
-- retire_drops_on_contradicted_coverage (parts H and I) and contradicted_reset_blames_detach_only (part J). The
-- script's path is the psql variable archive_whole_script, defaulting to the tree's copy.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

\if :{?archive_whole_script}
\else
\set archive_whole_script /repo/scripts/archive_partition_whole.sql
\endif
\i :archive_whole_script

select plan(82);

create schema t330;
-- every strategy call, with the ids it read through the parent
create table t330.calls (n serial primary key, parent regclass, p_child name, p_lo text, p_hi text, seen text);
create table t330.sink (parent regclass, id bigint, payload text);

-- reads [lo, hi) through the PARENT, as pgpm_archive's archive_to_s3_* do, into a sink
create function t330.via_parent(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_seen text; v_n bigint;
begin
  execute format('insert into t330.sink select %L::regclass, id, payload from %s where id >= %L::bigint and id < %L::bigint',
                 p_parent, p_parent, p_lo, p_hi);
  get diagnostics v_n = row_count;
  execute format('select string_agg(id::text, '','' order by id) from %s where id >= %L::bigint and id < %L::bigint',
                 p_parent, p_lo, p_hi)
    into v_seen;
  insert into t330.calls (parent, p_child, p_lo, p_hi, seen) values (p_parent, p_child, p_lo, p_hi, coalesce(v_seen, 'none'));
  v.covered_hi := p_hi; v.rows_archived := v_n; v.s3_key := 't330/' || p_parent::text || '/' || p_lo;
  return v;
end $$;

-- ================================ PART A: the acceptance flow through maintain() ================================
create table public.rm330a (id bigint primary key, payload text);
insert into public.rm330a values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.rm330a', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330a', '60');
insert into public.rm330a values (22, 'aged'), (55, 'frontier');
create table public.rm330a_ref (id bigint primary key, p_id bigint references public.rm330a (id));
insert into public.rm330a_ref values (1, 55);   -- referenced: retire() takes the dispatched-detach path
select child_name as a_mono, child_oid as a_mono_oid from pgpm.part
 where parent_table = 'public.rm330a'::regclass and lo = '0' \gset
select child_name as a_p20 from pgpm.part where parent_table = 'public.rm330a'::regclass and lo = '20' \gset

-- no pg_cron in this database: retire() stamps the mark, then its dispatch of the detach fails
call pgpm.maintain('public.rm330a');

select ok(exists (select 1 from pgpm.part where parent_table = 'public.rm330a'::regclass and lo = '0'
                   and retiring_at is not null and detach_dispatched_oid is null)
          and exists (select 1 from pgpm.log where parent_table = 'public.rm330a'::regclass and lo = '0'
                       and action = 'fail_retain_detach')
          and pgpm._is_write_blocked('public.rm330a', :'a_mono'),
  'LIVENESS: A: the write-blocked monolith [0, 20) carries a retirement mark with no dispatch record (the dispatch failed)');

-- the operator detaches it by hand: a finished, plain DETACH, which pgpm never issued
select format('alter table public.rm330a detach partition public.%I', :'a_mono') \gexec
select ok(not exists (select 1 from pg_inherits where inhrelid = :a_mono_oid)
          and exists (select 1 from pg_class where oid = :a_mono_oid),
  'LIVENESS: A: the monolith is detached by hand and still exists');

select pgpm.set_archive_fn('public.rm330a', 't330.via_parent(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.rm330a'::regclass;   -- every candidate gets a turn

call pgpm.maintain('public.rm330a');

select ok(exists (select 1 from pgpm.log where parent_table = 'public.rm330a'::regclass and lo = '0'
                   and action = 'retain_disown'),
  'LIVENESS: A: in the same tick retire() judged the detach the operator''s (retain_disown)');
select results_eq($$ select p_child, p_lo, p_hi, seen from t330.calls where parent = 'public.rm330a'::regclass order by n $$,
  format($$ values (%L::name, '20'::text, '30'::text, '22'::text) $$, :'a_p20'),
  'A: the archive step handed the strategy [20, 30) (id 22) alone, never the table the operator detached by hand');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.rm330a'::regclass
                            and child_name = %L $$, :'a_mono'),
  'A: and recorded no archive coverage for the operator''s table');

-- the documented remedy (docs/reference.md, retire): attach the table back on its bounds so retention retires
-- it. The referencing table goes first, so retire() takes the one-step path this database can run without pg_cron.
drop table public.rm330a_ref;
select format('alter table public.rm330a attach partition public.%I for values from (0) to (20)', :'a_mono') \gexec
select ok(exists (select 1 from pg_inherits where inhrelid = :a_mono_oid and inhparent = 'public.rm330a'::regclass),
  'LIVENESS: A: the operator attached the table back to the parent on its bounds');

call pgpm.maintain('public.rm330a');
call pgpm.maintain('public.rm330a');

select ok(not exists (select 1 from pg_class where oid = :a_mono_oid),
  'LIVENESS: A: retention retired the attached-back monolith (dropped)');
select is((select array_agg(distinct s.id order by s.id) from t330.sink s where s.parent = 'public.rm330a'::regclass),
  array[1, 2, 15, 22]::bigint[],
  'A: ids 1, 2 and 15 were archived before the drop, beside [20, 30)''s id 22');

-- ================================ PART B: the shared predicates, both directions ================================
create table public.rm330b (id bigint primary key, payload text);
insert into public.rm330b values (1, 'a'), (2, 'b');
call pgpm.transmute('public.rm330b', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330b', '100');
insert into public.rm330b values (25, 'own'), (35, 'failed'), (45, 'other'), (55, 'sibling'), (95, 'frontier');
select child_name as b_own,   child_oid as b_own_oid   from pgpm.part where parent_table = 'public.rm330b'::regclass and lo = '20' \gset
select child_name as b_fail,  child_oid as b_fail_oid  from pgpm.part where parent_table = 'public.rm330b'::regclass and lo = '30' \gset
select child_name as b_other, child_oid as b_other_oid from pgpm.part where parent_table = 'public.rm330b'::regclass and lo = '40' \gset
select child_oid as b_sib_oid from pgpm.part where parent_table = 'public.rm330b'::regclass and lo = '50' \gset

-- [20, 30): pgpm's own retirement, its dispatched detach landed (the mark and the record retire() writes together)
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = child_oid, detach_dispatched_oid = child_oid
 where parent_table = 'public.rm330b'::regclass and lo = '20';
-- [30, 40): the state a failed dispatch leaves, the mark with no record
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = child_oid
 where parent_table = 'public.rm330b'::regclass and lo = '30';
-- [40, 50): a record that names another relation (the [20, 30) table's), not this one
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = child_oid, detach_dispatched_oid = :b_own_oid
 where parent_table = 'public.rm330b'::regclass and lo = '40';
select format('alter table public.rm330b detach partition public.%I', c) from unnest(array[:'b_own', :'b_fail', :'b_other']::name[]) c \gexec

select ok(not exists (select 1 from pg_inherits where inhparent = 'public.rm330b'::regclass
                       and inhrelid in (:b_own_oid, :b_fail_oid, :b_other_oid))
          and (select count(*) from pg_class where oid in (:b_own_oid, :b_fail_oid, :b_other_oid)) = 3
          and (select count(*) from pgpm.part where parent_table = 'public.rm330b'::regclass and attached
                and retiring_at is not null and lo in ('20', '30', '40')) = 3,
  'LIVENESS: B: [20, 30), [30, 40) and [40, 50) are detached, still exist, and each carries a retirement mark');
select ok(not exists (select 1 from pg_trigger where tgrelid in (:b_own_oid, :b_fail_oid, :b_other_oid, :b_sib_oid)
                       and tgname = 'pgpm_write_block'),
  'LIVENESS: B: none of the four carries a write block before the step');

create temporary table b330 as
  select p.lo, pgpm._part_built(p.parent_table, p.child_oid, p.retiring_at) as built,
         pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at) as by_hand
    from pgpm.part p
   where p.parent_table = 'public.rm330b'::regclass and p.lo in ('20', '30', '40', '50');
select is((select array_agg(lo order by lo::int) from b330 where built), array['20', '50'],
  'B: _part_built counts the attached [50, 60) and pgpm''s own retirement [20, 30), not the two marks without a record of their own');
select is((select array_agg(lo order by lo::int) from b330 where by_hand), array['30', '40'],
  'B: _part_detached_by_hand names [30, 40) (no record) and [40, 50) (a record naming another relation)');
select is((select array_agg(p.lo order by p.lo::int) from pgpm.part p
            where p.parent_table = 'public.rm330b'::regclass and p.lo in ('20', '30', '40', '50')
              and pgpm._archive_hold_partition(p.parent_table, p.child_oid, p.retiring_at)),
  array['50'],
  'B: _archive_hold_partition holds the attached [50, 60) alone: no detached table, whatever its mark (part D says why)');

select pgpm._enforce_write_blocks('public.rm330b');

select ok(exists (select 1 from pg_trigger where tgrelid = :b_sib_oid and tgname = 'pgpm_write_block'),
  'LIVENESS: B: the write-block step blocked the attached sibling [50, 60)');
select is((select array_agg(p.lo order by p.lo::int) from pgpm.part p
            join pg_trigger t on t.tgrelid = p.child_oid and t.tgname = 'pgpm_write_block'
           where p.parent_table = 'public.rm330b'::regclass and p.lo in ('20', '30', '40', '50')),
  array['20', '50'],
  'B: the write-block step blocks pgpm''s own retirement and the sibling, not the operator''s two tables');
select lives_ok(format('update public.%I set payload = ''kept'' where id = 35', :'b_fail'),
  'B: the operator writes to the table detached under a mark with no record');

-- one detach in flight is database-wide: no mark outlives its part
update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'public.rm330b'::regclass;

-- ================================ PART C: scripts/archive_partition_whole.sql ================================
create table public.rm330c (id bigint primary key, payload text);
insert into public.rm330c values (1, 'a');
call pgpm.transmute('public.rm330c', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330c', '100');
insert into public.rm330c values (21, 'x'), (24, 'y'), (27, 'z'), (31, 'p'), (33, 'q'), (95, 'frontier');
select pgpm._enforce_write_blocks('public.rm330c');
select child_name as c_mono from pgpm.part where parent_table = 'public.rm330c'::regclass and lo = '0' \gset
select child_name as c_p20, child_oid as c_p20_oid from pgpm.part where parent_table = 'public.rm330c'::regclass and lo = '20' \gset
select child_name as c_p30 from pgpm.part where parent_table = 'public.rm330c'::regclass and lo = '30' \gset
-- the state a failed dispatch leaves, then the operator's detach by hand; the archive strategy reads through the parent
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = child_oid
 where parent_table = 'public.rm330c'::regclass and lo = '20';
select format('alter table public.rm330c detach partition public.%I', :'c_p20') \gexec
select pgpm.set_archive_fn('public.rm330c', 't330.via_parent(regclass,name,text,text)'::regprocedure);

select ok(pgpm._is_write_blocked('public.rm330c', :'c_p20') and pgpm._is_write_blocked('public.rm330c', :'c_p30')
          and not exists (select 1 from pg_inherits where inhrelid = :c_p20_oid)
          and exists (select 1 from pgpm.part where parent_table = 'public.rm330c'::regclass and lo = '20'
                       and retiring_at is not null and detach_dispatched_oid is null),
  'LIVENESS: C: [20, 30) and [30, 40) are write-blocked; [20, 30) is detached by hand under a mark with no record');

select pgpm_archive_next_partition_whole('public.rm330c'::regclass);
select pgpm_archive_next_partition_whole('public.rm330c'::regclass);
select pgpm_archive_next_partition_whole('public.rm330c'::regclass);
select pgpm_archive_next_partition_whole('public.rm330c'::regclass);

select ok(exists (select 1 from t330.calls where parent = 'public.rm330c'::regclass and p_child = :'c_p30'
                   and seen = '31,33'),
  'LIVENESS: C: the script archived [30, 40) (ids 31 and 33), past [20, 30)');
select is_empty(format($$ select 1 from t330.calls where parent = 'public.rm330c'::regclass and p_child = %L $$, :'c_p20'),
  'C: the script never handed the strategy the table detached under a mark with no record');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.rm330c'::regclass
                            and child_name = %L $$, :'c_p20'),
  'C: and recorded no coverage for it');
select format('select string_agg(id::text, '','' order by id) as c20_ids from public.%I', :'c_p20') as c20_sql \gset
:c20_sql \gset
select is(:'c20_ids'::text, '21,24,27',
  'C: the operator''s table keeps its ids 21, 24 and 27');

update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'public.rm330c'::regclass;

-- ======== PART D: pgpm's own retirement, detached before archiving was configured, is not handed off ========
-- The mark HAS its record here (pgpm's own dispatched detach, landed), and archiving is switched on only after the
-- mark was stamped, so retire()'s coverage gate never ran for the range. The rows are no longer in the parent's
-- range: a strategy reading through the parent would read none of them, and the range used to be recorded as
-- covered with 0 rows and the table dropped on it (#1259's per-PR verification, V-01). It is now never handed to a
-- strategy, nothing is recorded, retire() keeps it, the step logs skip_archive with the remedy, and the remedy as
-- typed (attach it back) archives ids 1, 2 and 15 before the drop.
create table public.rm330d (id bigint primary key, payload text);
insert into public.rm330d values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.rm330d', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330d', '60');
insert into public.rm330d values (22, 'aged'), (55, 'frontier');
create table public.rm330d_ref (id bigint primary key, p_id bigint references public.rm330d (id));
insert into public.rm330d_ref values (1, 55);   -- referenced: retire() takes the dispatched-detach path
select child_name as d_mono, child_oid as d_mono_oid from pgpm.part
 where parent_table = 'public.rm330d'::regclass and lo = '0' \gset
select child_name as d_p20 from pgpm.part where parent_table = 'public.rm330d'::regclass and lo = '20' \gset

-- no archive strategy yet: retire() stamps the mark and dispatches the detach
call pgpm.maintain('public.rm330d');
-- fixture: this harness has no pg_cron, so the dispatch fails here; with pg_cron it succeeds and retire() writes
-- the record in the same transaction ("update pgpm.part set detach_dispatched_oid = v_child::oid"). Written as
-- retire() writes it.
update pgpm.part set detach_dispatched_oid = child_oid
 where parent_table = 'public.rm330d'::regclass and lo = '0' and retiring_at is not null;
select ok((select pgpm._detach_dispatched(parent_table, child_name, child_oid) from pgpm.part
            where parent_table = 'public.rm330d'::regclass and lo = '0'),
  'LIVENESS: D: fixture: the monolith [0, 20) carries pgpm''s retirement mark with the record of its dispatch');
-- fixture: pg_cron's pgpm_detach job runs the dispatched detach, which lands
select format('alter table public.rm330d detach partition public.%I concurrently', :'d_mono') \gexec
select ok(not exists (select 1 from pg_inherits where inhrelid = :d_mono_oid)
          and exists (select 1 from pg_class where oid = :d_mono_oid),
  'LIVENESS: D: fixture: pgpm''s dispatched detach landed; the table stands outside the parent');

select pgpm.set_archive_fn('public.rm330d', 't330.via_parent(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.rm330d'::regclass;
create temporary table markd330 as select coalesce(max(id), 0) as id from pgpm.log;

call pgpm.maintain('public.rm330d');
call pgpm.maintain('public.rm330d');

select results_eq($$ select p_child, p_lo, p_hi, seen from t330.calls where parent = 'public.rm330d'::regclass order by n $$,
  format($$ values (%L::name, '20'::text, '30'::text, '22'::text) $$, :'d_p20'),
  'D: the strategy was handed [20, 30) (id 22) alone, never the detached monolith of pgpm''s own retirement');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.rm330d'::regclass
                            and child_name = %L $$, :'d_mono'),
  'D: no coverage is recorded for the detached monolith');
select ok(exists (select 1 from pg_class where oid = :d_mono_oid)
          and not exists (select 1 from pgpm.log where parent_table = 'public.rm330d'::regclass and lo = '0'
                           and action = 'retain_drop'),
  'D: retire() keeps the table while its range is uncovered');
-- (the table gone: no ids, so the assertion fails rather than the file)
select case when exists (select 1 from pg_class where oid = :d_mono_oid)
            then format('select coalesce(string_agg(id::text, '','' order by id), ''none'') as d_ids from public.%I', :'d_mono')
            else 'select ''gone''::text as d_ids' end as d_sql \gset
:d_sql \gset
select is(:'d_ids'::text, '1,2,15', 'D: the detached table keeps ids 1, 2 and 15');
select is((select array_agg(distinct l.lo || '-' || l.hi) from pgpm.log l
            where l.parent_table = 'public.rm330d'::regclass and l.action = 'skip_archive'
              and l.id > (select id from markd330)
              and l.method like '%ATTACH PARTITION%'),
  array['0-20'],
  'D: the archive step logs skip_archive over [0, 20), with the remedy');

-- the remedy as the log row types it. The referencing table goes first, so retire() then takes the one-step
-- path this database can run without pg_cron.
drop table public.rm330d_ref;
-- (no such row: a statement that does nothing, so the LIVENESS below fails rather than the file)
select coalesce((select substring(l.method from 'ALTER TABLE .* FOR VALUES FROM \(''[^'']*''\) TO \(''[^'']*''\)')
                   from pgpm.log l
                  where l.parent_table = 'public.rm330d'::regclass and l.action = 'skip_archive' and l.lo = '0'
                  order by l.id desc limit 1), 'select 1') as d_remedy \gset
:d_remedy;
select ok(exists (select 1 from pg_inherits where inhrelid = :d_mono_oid and inhparent = 'public.rm330d'::regclass),
  'LIVENESS: D: the remedy as typed attached the table back to the parent');

call pgpm.maintain('public.rm330d');
call pgpm.maintain('public.rm330d');

select ok(not exists (select 1 from pg_class where oid = :d_mono_oid),
  'LIVENESS: D: retention completed the retirement (the monolith is dropped)');
select is((select array_agg(distinct s.id order by s.id) from t330.sink s where s.parent = 'public.rm330d'::regclass),
  array[1, 2, 15, 22]::bigint[],
  'D: ids 1, 2 and 15 were archived before the drop, beside [20, 30)''s id 22');

update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'public.rm330d'::regclass;

-- ======== PART E: an unanchored row is never handed to a strategy (round 3; #705's archive-step residue) ========
-- A row with no child_oid (one an upgrade from before #421 could not anchor) names no relation the hold can ask,
-- and the candidate query cannot call its table detached by hand. The hold used to answer true for it, so a table
-- the operator detached by hand under such a row was handed to the strategy, which read none of its rows through
-- the parent, and the range was recorded as covered with 0 rows; attached back, retention dropped it. It is now
-- not handed off, nothing is recorded, retire() keeps it, skip_archive gives the remedy, and the remedy as typed
-- (attach it back, then anchor the row with adopt_partition) archives ids 1, 2 and 15 before the drop.
create table t330.gate (open boolean);
insert into t330.gate values (false);
-- via_parent behind a gate: closed, it raises, so the archive step defers and retire() keeps every partition
create function t330.gated(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
begin
  if not (select open from t330.gate) then raise exception 't330: transport not ready yet'; end if;
  return t330.via_parent(p_parent, p_child, p_lo, p_hi);
end $$;

create table public.rm330e (id bigint primary key, payload text);
insert into public.rm330e values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.rm330e', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330e', '60');
insert into public.rm330e values (22, 'aged'), (55, 'frontier');
select child_name as e_mono, child_oid as e_mono_oid from pgpm.part
 where parent_table = 'public.rm330e'::regclass and lo = '0' \gset
select child_name as e_p20 from pgpm.part where parent_table = 'public.rm330e'::regclass and lo = '20' \gset
select pgpm.set_archive_fn('public.rm330e', 't330.gated(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.rm330e'::regclass;

call pgpm.maintain('public.rm330e');
select ok(pgpm._is_write_blocked('public.rm330e', :'e_mono') and exists (select 1 from pg_class where oid = :e_mono_oid),
  'LIVENESS: E: the aged monolith [0, 20) is write-blocked and kept (archiving deferred, its range uncovered)');

-- the operator detaches it by hand; fixture: the row is unanchored, as an upgrade from before #421 leaves a
-- partition its backfill could not resolve
select format('alter table public.rm330e detach partition public.%I', :'e_mono') \gexec
update pgpm.part set child_oid = null where parent_table = 'public.rm330e'::regclass and lo = '0';
select ok(not exists (select 1 from pg_inherits where inhrelid = :e_mono_oid)
          and exists (select 1 from pgpm.part where parent_table = 'public.rm330e'::regclass and lo = '0'
                       and child_oid is null and retiring_at is null),
  'LIVENESS: E: fixture: the monolith is detached by hand, its row unanchored and unmarked');

update t330.gate set open = true;
create temporary table marke330 as select coalesce(max(id), 0) as id from pgpm.log;
call pgpm.maintain('public.rm330e');
call pgpm.maintain('public.rm330e');

select results_eq($$ select p_child, p_lo, p_hi, seen from t330.calls where parent = 'public.rm330e'::regclass order by n $$,
  format($$ values (%L::name, '20'::text, '30'::text, '22'::text) $$, :'e_p20'),
  'E: the strategy was handed [20, 30) (id 22) alone, never the table under the unanchored row');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.rm330e'::regclass
                            and child_name = %L $$, :'e_mono'),
  'E: no coverage is recorded for it');
-- (the table gone: no ids, so the assertion fails rather than the file)
select case when exists (select 1 from pg_class where oid = :e_mono_oid)
            then format('select coalesce(string_agg(id::text, '','' order by id), ''none'') as e_ids from public.%I', :'e_mono')
            else 'select ''gone''::text as e_ids' end as e_sql \gset
:e_sql \gset
select is(:'e_ids'::text, '1,2,15', 'E: the detached table is kept with ids 1, 2 and 15');
select is((select array_agg(distinct l.lo || '-' || l.hi) from pgpm.log l
            where l.parent_table = 'public.rm330e'::regclass and l.action = 'skip_archive'
              and l.id > (select id from marke330)
              and l.method like '%records no oid%' and l.method like '%adopt_partition%'),
  array['0-20'],
  'E: the archive step logs skip_archive over [0, 20), with the remedy');

-- the remedy as the log row types it: attach the table back, then anchor the row
select coalesce((select substring(l.method from 'ALTER TABLE .* FOR VALUES FROM \(''[^'']*''\) TO \(''[^'']*''\)')
                   from pgpm.log l
                  where l.parent_table = 'public.rm330e'::regclass and l.action = 'skip_archive' and l.lo = '0'
                  order by l.id desc limit 1), 'select 1') as e_attach,
       coalesce((select substring(l.method from 'select pgpm\.adopt_partition\([^)]*\)')
                   from pgpm.log l
                  where l.parent_table = 'public.rm330e'::regclass and l.action = 'skip_archive' and l.lo = '0'
                  order by l.id desc limit 1), 'select 1') as e_adopt \gset
:e_attach;
:e_adopt;
select ok(exists (select 1 from pg_inherits where inhrelid = :e_mono_oid and inhparent = 'public.rm330e'::regclass)
          and exists (select 1 from pgpm.part where parent_table = 'public.rm330e'::regclass and lo = '0'
                       and child_oid = :e_mono_oid),
  'LIVENESS: E: the remedy as typed attached the table back and anchored its row');

call pgpm.maintain('public.rm330e');
call pgpm.maintain('public.rm330e');

select ok(not exists (select 1 from pg_class where oid = :e_mono_oid),
  'LIVENESS: E: retention retired the attached-back monolith (dropped)');
select is((select array_agg(distinct s.id order by s.id) from t330.sink s where s.parent = 'public.rm330e'::regclass),
  array[1, 2, 15, 22]::bigint[],
  'E: ids 1, 2 and 15 were archived before the drop, beside [20, 30)''s id 22');

-- ======== PART F: a DETACH ... CONCURRENTLY that begins under the hold, through maintain() (round 4; V-01, V-02) ========
-- The hold's ACCESS SHARE on the parent does not conflict with the SHARE UPDATE EXCLUSIVE a concurrent detach's
-- first transaction takes, so that transaction commits while the step is between the hold and the strategy's read.
-- A read through the parent planned after it (one call below the strategy, as pgpm_archive's transports read)
-- leaves the partition out: 0 rows, and the chunk used to be recorded as covered. The hold is now asked again when
-- the strategy has returned, and nothing is recorded on a false answer.
create table t330.gate_f (go boolean);
insert into t330.gate_f values (false);
-- the read, one call below the strategy: planned under the calling statement's snapshot, taken after the gate opened
create function t330.read_deep(p_parent regclass, p_lo text, p_hi text, out n bigint, out seen text)
language plpgsql as $$
begin
  execute format('insert into t330.sink select %L::regclass, id, payload from %s where id >= %L::bigint and id < %L::bigint',
                 p_parent, p_parent, p_lo, p_hi);
  get diagnostics n = row_count;
  execute format('select string_agg(id::text, '','' order by id) from %s where id >= %L::bigint and id < %L::bigint',
                 p_parent, p_lo, p_hi)
    into seen;
end $$;
-- says it is inside (an advisory lock another session can see), waits at the gate (bounded at 30 s), then reads
create function t330.gated_deep(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_n bigint; v_seen text; k int := 0;
begin
  perform pg_advisory_xact_lock(p_parent::oid::bigint);
  while not (select go from t330.gate_f) and k < 3000 loop
    perform pg_sleep(0.01); k := k + 1;
  end loop;
  if not (select go from t330.gate_f) then raise exception 't330: the gate never opened'; end if;
  select d.n, d.seen into v_n, v_seen from t330.read_deep(p_parent, p_lo, p_hi) d;
  insert into t330.calls (parent, p_child, p_lo, p_hi, seen) values (p_parent, p_child, p_lo, p_hi, coalesce(v_seen, 'none'));
  v.covered_hi := p_hi; v.rows_archived := v_n; v.s3_key := 't330/' || p_parent::text || '/' || p_lo;
  return v;
end $$;

-- The race. Runs p_call in the tick session; waits until that session is inside the strategy (its advisory lock);
-- starts the operator's DETACH ... CONCURRENTLY of p_child in another; waits until its first transaction has
-- committed (pg_inherits.inhdetachpending) with the tick still inside the strategy and the gate still shut; opens
-- the gate (in a session of its own, so the tick sees it); collects the call's result, then the detach's, which
-- finishes once the tick's transaction ends. Every wait is bounded at 30 s. pg_locks and pg_inherits only: no
-- pg_stat_activity, so no statistics snapshot to clear.
create function t330.race_concurrent(p_parent regclass, p_child name, p_call text,
                                     out entered boolean, out committed_inside boolean, out result text)
language plpgsql as $$
declare v_child oid; v_pid int;
begin
  entered := false; committed_inside := false;
  select c.oid into v_child from pg_class c where c.relname = p_child and c.relnamespace = 'public'::regnamespace;
  perform dblink_connect('a330', 'dbname=' || current_database());
  select t.pid into v_pid from dblink('a330', 'select pg_backend_pid()') as t(pid int);
  perform dblink_send_query('a330', p_call);
  for i in 1 .. 3000 loop
    entered := exists (select 1 from pg_locks l where l.pid = v_pid and l.locktype = 'advisory'
                          and l.classid = 0 and l.objid = p_parent::oid and l.granted);
    exit when entered or dblink_is_busy('a330') = 0;
    perform pg_sleep(0.01);
  end loop;

  perform dblink_connect('d330', 'dbname=' || current_database());
  perform dblink_send_query('d330', format('alter table %s detach partition public.%I concurrently', p_parent, p_child));
  for i in 1 .. 3000 loop
    committed_inside := exists (select 1 from pg_inherits h where h.inhrelid = v_child and h.inhdetachpending)
                    and exists (select 1 from pg_locks l where l.pid = v_pid and l.locktype = 'advisory'
                                   and l.classid = 0 and l.objid = p_parent::oid and l.granted)
                    and dblink_is_busy('a330') = 1
                    and not (select go from t330.gate_f);
    exit when committed_inside or dblink_is_busy('d330') = 0 or dblink_is_busy('a330') = 0;
    perform pg_sleep(0.01);
  end loop;

  perform dblink_exec('dbname=' || current_database(), 'update t330.gate_f set go = true');
  select t.r into result from dblink_get_result('a330') as t(r text);
  perform * from dblink_get_result('a330') as t(r text);          -- drain the empty result that ends the query
  perform * from dblink_get_result('d330', false) as t(r text);   -- the detach finishes once the tick's transaction ends
  perform * from dblink_get_result('d330', false) as t(r text);
  perform dblink_disconnect('a330');
  perform dblink_disconnect('d330');
end $$;

create table public.rm330f (id bigint primary key, payload text);
insert into public.rm330f values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.rm330f', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330f', '60');
insert into public.rm330f values (22, 'aged'), (55, 'frontier');
select pgpm._enforce_write_blocks('public.rm330f');
select child_name as f_mono, child_oid as f_mono_oid from pgpm.part
 where parent_table = 'public.rm330f'::regclass and lo = '0' \gset
select child_name as f_p20 from pgpm.part where parent_table = 'public.rm330f'::regclass and lo = '20' \gset
select pgpm.set_archive_fn('public.rm330f', 't330.gated_deep(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.rm330f'::regclass;   -- every candidate gets a turn

select ok(pgpm._is_write_blocked('public.rm330f', :'f_mono') and pgpm._is_write_blocked('public.rm330f', :'f_p20')
          and exists (select 1 from pg_inherits where inhrelid = :f_mono_oid and inhparent = 'public.rm330f'::regclass
                         and not inhdetachpending)
          and not exists (select 1 from pgpm.archive_ledger where parent_table = 'public.rm330f'::regclass),
  'LIVENESS: F: the monolith [0, 20) and [20, 30) are attached, write-blocked and uncovered: both archive candidates');

create temporary table markf330 as select coalesce(max(id), 0) as id from pgpm.log;
select * from t330.race_concurrent('public.rm330f', :'f_mono', $$call pgpm.maintain('public.rm330f')$$) \gset f_

select ok(:'f_entered'::boolean,
  'LIVENESS: F: the tick held the monolith and was inside the strategy, before its read, when the detach started');
select ok(:'f_committed_inside'::boolean,
  'LIVENESS: F: the operator''s DETACH ... CONCURRENTLY committed its first transaction with the tick still there');
select ok(exists (select 1 from t330.calls where parent = 'public.rm330f'::regclass and p_child = :'f_mono'
                     and p_lo = '0' and p_hi = '20' and seen = 'none'),
  'LIVENESS: F: the strategy''s read through the parent then saw none of the monolith''s rows');
select ok(exists (select 1 from pgpm.archive_ledger where parent_table = 'public.rm330f'::regclass and lo = '20'
                     and child_name = :'f_p20' and rows_archived = 1),
  'LIVENESS: F: the same step recorded [20, 30) (id 22), still attached when asked again');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.rm330f'::regclass
                            and child_name = %L $$, :'f_mono'),
  'F: no coverage is recorded for the monolith, whose detach began under the hold');
select is((select array_agg(distinct l.lo || '-' || l.hi) from pgpm.log l
            where l.parent_table = 'public.rm330f'::regclass and l.action = 'skip_archive'
              and l.id > (select id from markf330)
              and l.method like '%stopped being an attached partition of%' and l.method like '%ATTACH PARTITION%'),
  array['0-20'],
  'F: the archive step logs skip_archive over [0, 20), saying why and with the remedy');
select ok(not exists (select 1 from pg_inherits where inhrelid = :f_mono_oid)
          and exists (select 1 from pg_class where oid = :f_mono_oid),
  'LIVENESS: F: the operator''s detach finished once the tick ended; the table stands outside the parent');
-- (the table gone: no ids, so the assertion fails rather than the file)
select case when exists (select 1 from pg_class where oid = :f_mono_oid)
            then format('select coalesce(string_agg(id::text, '','' order by id), ''none'') as f_ids from public.%I', :'f_mono')
            else 'select ''gone''::text as f_ids' end as f_sql \gset
:f_sql \gset
select is(:'f_ids'::text, '1,2,15', 'F: the detached table keeps ids 1, 2 and 15');

-- the remedy as the log row types it
-- (no such row: a statement that does nothing, so the LIVENESS below fails rather than the file)
select coalesce((select substring(l.method from 'ALTER TABLE .* FOR VALUES FROM \(''[^'']*''\) TO \(''[^'']*''\)')
                   from pgpm.log l
                  where l.parent_table = 'public.rm330f'::regclass and l.action = 'skip_archive' and l.lo = '0'
                    and l.method like '%stopped being an attached partition of%'
                  order by l.id desc limit 1), 'select 1') as f_remedy \gset
:f_remedy;
select ok(exists (select 1 from pg_inherits where inhrelid = :f_mono_oid and inhparent = 'public.rm330f'::regclass),
  'LIVENESS: F: the remedy as typed attached the table back to the parent');

call pgpm.maintain('public.rm330f');
call pgpm.maintain('public.rm330f');

select ok(not exists (select 1 from pg_class where oid = :f_mono_oid),
  'LIVENESS: F: retention retired the attached-back monolith (dropped)');
select is((select array_agg(distinct s.id order by s.id) from t330.sink s where s.parent = 'public.rm330f'::regclass),
  array[1, 2, 15, 22]::bigint[],
  'F: ids 1, 2 and 15 were archived before the drop, beside [20, 30)''s id 22');

-- ======== PART G: the same race through scripts/archive_partition_whole.sql ========
update t330.gate_f set go = false;
create table public.rm330g (id bigint primary key, payload text);
insert into public.rm330g values (3, 'a'), (4, 'b'), (16, 'c');
call pgpm.transmute('public.rm330g', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330g', '60');
insert into public.rm330g values (23, 'aged'), (56, 'frontier');
select pgpm._enforce_write_blocks('public.rm330g');
select child_name as g_mono, child_oid as g_mono_oid from pgpm.part
 where parent_table = 'public.rm330g'::regclass and lo = '0' \gset
select child_name as g_p20 from pgpm.part where parent_table = 'public.rm330g'::regclass and lo = '20' \gset
select pgpm.set_archive_fn('public.rm330g', 't330.gated_deep(regclass,name,text,text)'::regprocedure);

select ok(pgpm._is_write_blocked('public.rm330g', :'g_mono')
          and exists (select 1 from pg_inherits where inhrelid = :g_mono_oid and inhparent = 'public.rm330g'::regclass
                         and not inhdetachpending)
          and not exists (select 1 from pgpm.archive_ledger where parent_table = 'public.rm330g'::regclass),
  'LIVENESS: G: the monolith [0, 20) is attached, write-blocked and uncovered: the script''s next partition');

select * from t330.race_concurrent('public.rm330g', :'g_mono',
  $$select pgpm_archive_next_partition_whole('public.rm330g'::regclass)$$) \gset g_
select diag('G: ' || :'g_result');

select ok(:'g_entered'::boolean,
  'LIVENESS: G: the call held the monolith and was inside the strategy, before its read, when the detach started');
select ok(:'g_committed_inside'::boolean,
  'LIVENESS: G: the operator''s DETACH ... CONCURRENTLY committed its first transaction with the call still there');
select ok(exists (select 1 from t330.calls where parent = 'public.rm330g'::regclass and p_child = :'g_mono'
                     and p_lo = '0' and p_hi = '20' and seen = 'none'),
  'LIVENESS: G: the strategy''s read through the parent then saw none of the monolith''s rows');
select is_empty($$ select 1 from pgpm.archive_ledger where parent_table = 'public.rm330g'::regclass $$,
  'G: the script recorded no coverage for it');
select matches(:'g_result'::text, format('^%s\.%s stopped being an attached partition of ', 'public', :'g_mono'),
  'G: the call says which table began leaving while the strategy ran');
-- (the table gone: no ids, so the assertion fails rather than the file)
select case when exists (select 1 from pg_class where oid = :g_mono_oid)
                 and not exists (select 1 from pg_inherits where inhrelid = :g_mono_oid)
            then format('select coalesce(string_agg(id::text, '','' order by id), ''none'') as g_ids from public.%I', :'g_mono')
            else 'select ''gone or still attached''::text as g_ids' end as g_sql \gset
:g_sql \gset
select is(:'g_ids'::text, '3,4,16', 'G: the detach finished and the operator''s table keeps ids 3, 4 and 16');
select pgpm_archive_next_partition_whole('public.rm330g'::regclass);
select results_eq($$ select p_child, p_lo, p_hi, seen from t330.calls where parent = 'public.rm330g'::regclass order by n $$,
  format($$ values (%L::name, '0'::text, '20'::text, 'none'::text), (%L::name, '20'::text, '30'::text, '23'::text) $$,
         :'g_mono', :'g_p20'),
  'G: the next call leaves the detached table out and archives [20, 30), id 23');

-- ======== PART H: retention does not drop on a 0-row chunk over rows the partition holds (V-03) ========
-- What an install before these fixes left: the archive step handed a table detached by hand to the strategy, which
-- read none of its rows through the parent, and [0, 20) was recorded as covered with 0 rows. Attached back, the
-- reference's remedy, the table read as fully covered and retention dropped it. retire() now asks, where coverage
-- opens its drop gate, whether a chunk of 0 rows lies over rows the partition holds: it discards the coverage
-- instead of dropping, and the next tick archives ids 1, 2 and 15 before the drop.
update t330.gate set open = false;
create table public.rm330h (id bigint primary key, payload text);
insert into public.rm330h values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.rm330h', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330h', '60');
insert into public.rm330h values (22, 'aged'), (55, 'frontier');
select child_name as h_mono, child_oid as h_mono_oid from pgpm.part
 where parent_table = 'public.rm330h'::regclass and lo = '0' \gset
select pgpm.set_archive_fn('public.rm330h', 't330.gated(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.rm330h'::regclass;

call pgpm.maintain('public.rm330h');
select ok(pgpm._is_write_blocked('public.rm330h', :'h_mono') and exists (select 1 from pg_class where oid = :h_mono_oid),
  'LIVENESS: H: the aged monolith [0, 20) is write-blocked and kept (archiving deferred, its range uncovered)');

-- the operator detached it by hand, and (fixture) the older install's archive step recorded it as covered from a
-- read through the parent that saw none of its rows
select format('alter table public.rm330h detach partition public.%I', :'h_mono') \gexec
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid)
values ('public.rm330h'::regclass, '0', '20', :'h_mono', 0, :h_mono_oid);
select ok(not exists (select 1 from pg_inherits where inhrelid = :h_mono_oid)
          and not exists (select 1 from t330.sink where parent = 'public.rm330h'::regclass)
          and exists (select 1 from pgpm.archive_ledger where parent_table = 'public.rm330h'::regclass and lo = '0'
                       and hi = '20' and rows_archived = 0 and child_oid = :h_mono_oid and retired_at is null),
  'LIVENESS: H: fixture: the table is detached by hand, the ledger says [0, 20) is covered with 0 rows, and none of its rows is archived');

update t330.gate set open = true;
create temporary table markh330 as select coalesce(max(id), 0) as id from pgpm.log;
call pgpm.maintain('public.rm330h');
select ok(exists (select 1 from t330.sink where parent = 'public.rm330h'::regclass and id = 22)
          and exists (select 1 from pgpm.log where parent_table = 'public.rm330h'::regclass and lo = '0'
                       and action = 'fail_retain_drop' and id > (select id from markh330)),
  'LIVENESS: H: a tick archived the attached [20, 30) and retire() reported the table as detached by hand (fail_retain_drop)');

-- the reference's remedy for a table detached by hand: attach it back so retention retires it
select format('alter table public.rm330h attach partition public.%I for values from (0) to (20)', :'h_mono') \gexec
select ok(exists (select 1 from pg_inherits where inhrelid = :h_mono_oid and inhparent = 'public.rm330h'::regclass)
          and pgpm._archive_fully_covered('public.rm330h', :'h_mono'),
  'LIVENESS: H: the operator attached the table back on its bounds, and by the ledger it is fully covered');

call pgpm.maintain('public.rm330h');
select is((select array_agg(id order by id) from public.rm330h where id < 20), array[1, 2, 15]::bigint[],
  'H: retention does not drop the attached-back table on a chunk that archived none of its rows: ids 1, 2 and 15 are still there');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.rm330h'::regclass
                            and child_name = %L and retired_at is null $$, :'h_mono'),
  'H: retire() discarded the 0-row coverage instead');
select is((select array_agg(l.lo || '-' || l.hi || ':' || l.rows order by l.id) from pgpm.log l
            where l.parent_table = 'public.rm330h'::regclass and l.action = 'archive_coverage_reset'
              and l.id > (select id from markh330)),
  array['0-20:1'],
  'H: logged archive_coverage_reset over [0, 20), one chunk');

call pgpm.maintain('public.rm330h');
select ok(not exists (select 1 from pg_class where oid = :h_mono_oid),
  'LIVENESS: H: once archived, retention retired the monolith (dropped)');
select is((select array_agg(distinct s.id order by s.id) from t330.sink s where s.parent = 'public.rm330h'::regclass),
  array[1, 2, 15, 22]::bigint[],
  'H: ids 1, 2 and 15 were archived before the drop, beside [20, 30)''s id 22');

-- ======== PART I: what that check leaves alone, and a direct retire() ========
-- Two fully covered partitions, each with a chunk of 0 rows. The monolith's is true: [5, 10) holds no row, so
-- retire() drops it as before and its chunks stay as the record of where its rows went. [20, 30)'s is not: [25, 30)
-- records 0 rows and the partition holds id 27 there, so its whole coverage is discarded (a chunk above or below
-- a false one keeps nothing covered: coverage is read as a watermark) and it is kept, then archived from lo.
create table public.rm330i (id bigint primary key, payload text);
insert into public.rm330i values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.rm330i', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330i', '100');
insert into public.rm330i values (21, 'x'), (27, 'y'), (95, 'frontier');
select pgpm._enforce_write_blocks('public.rm330i');
select child_name as i_mono, child_oid as i_mono_oid from pgpm.part
 where parent_table = 'public.rm330i'::regclass and lo = '0' \gset
select child_name as i_p20, child_oid as i_p20_oid from pgpm.part
 where parent_table = 'public.rm330i'::regclass and lo = '20' \gset
select pgpm.set_archive_fn('public.rm330i', 't330.via_parent(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.rm330i'::regclass;
-- fixture: the ledger. The monolith, three chunks, the middle one over a range with no row; [20, 30), two chunks,
-- the second recording 0 rows over id 27.
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid)
values ('public.rm330i'::regclass, '0',  '5',  :'i_mono', 2, :i_mono_oid),
       ('public.rm330i'::regclass, '5',  '10', :'i_mono', 0, :i_mono_oid),
       ('public.rm330i'::regclass, '10', '20', :'i_mono', 1, :i_mono_oid),
       ('public.rm330i'::regclass, '20', '25', :'i_p20',  1, :i_p20_oid),
       ('public.rm330i'::regclass, '25', '30', :'i_p20',  0, :i_p20_oid);
select ok(pgpm._archive_fully_covered('public.rm330i', :'i_mono') and pgpm._archive_fully_covered('public.rm330i', :'i_p20')
          and pgpm._is_write_blocked('public.rm330i', :'i_mono') and pgpm._is_write_blocked('public.rm330i', :'i_p20')
          and (select array_agg(id order by id) from public.rm330i where id < 30) = array[1, 2, 15, 21, 27]::bigint[],
  'LIVENESS: I: fixture: the monolith (ids 1, 2, 15) and [20, 30) (ids 21, 27) are attached, write-blocked and fully covered by the ledger');

create temporary table marki330 as select coalesce(max(id), 0) as id from pgpm.log;
select is(pgpm.retire('public.rm330i', :'i_mono'), true,
  'I: a partition whose 0-row chunk lies over a range it holds no row in is dropped, as before');
select is((select array_agg(l.lo || '-' || l.hi || ':' || l.rows_archived || ':' || (l.retired_at is not null)
                            order by l.lo::int)
             from pgpm.archive_ledger l where l.parent_table = 'public.rm330i'::regclass and l.child_name = :'i_mono'),
  array['0-5:2:true', '5-10:0:true', '10-20:1:true'],
  'I: and its three chunks are kept, marked retired');
select is(pgpm.retire('public.rm330i', :'i_p20'), false,
  'I: a direct retire() does not drop [20, 30), whose chunk [25, 30) records 0 rows over id 27');
select is((select array_agg(id order by id) from public.rm330i where id >= 20 and id < 30), array[21, 27]::bigint[],
  'I: ids 21 and 27 are still there');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.rm330i'::regclass
                            and child_name = %L $$, :'i_p20'),
  'I: both of its chunks are discarded, the one that records a row too: nothing above or below a false chunk stays covered');
select is((select array_agg(l.lo || '-' || l.hi || ':' || l.rows order by l.id) from pgpm.log l
            where l.parent_table = 'public.rm330i'::regclass and l.action = 'archive_coverage_reset'
              and l.id > (select id from marki330)),
  array['20-30:2'],
  'I: logged archive_coverage_reset once, over [20, 30), two chunks: nothing for the monolith');

call pgpm.maintain('public.rm330i');
call pgpm.maintain('public.rm330i');
select ok(not exists (select 1 from pg_class where oid = :i_p20_oid),
  'LIVENESS: I: once archived from lo, retention retired [20, 30) (dropped)');
select is((select array_agg(distinct s.id order by s.id) from t330.sink s where s.parent = 'public.rm330i'::regclass),
  array[21, 27]::bigint[],
  'I: ids 21 and 27 were archived before the drop');

-- ======== PART J: a strategy that archives everything and reports 0 instead of counting ========
-- The check in retire() cannot tell this from a read that saw none of the rows: both leave a chunk of 0 rows over
-- rows the partition holds. So the partition is kept, and the archive_coverage_reset row must name both causes,
-- this one with the strategy and its remedy: report the count, or null when it does not count. Typed (the strategy
-- replaced in place to report null), the remedy lets retention retire the partition.
create table t330.up (n serial primary key, parent regclass, p_lo text);
create function t330.uncounted(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into t330.up (parent, p_lo) values (p_parent, p_lo);   -- stands for an upload of the whole chunk
  v.covered_hi := p_hi; v.rows_archived := 0;
  return v;
end $$;
create table public.rm330j (id bigint primary key, payload text);
insert into public.rm330j values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.rm330j', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rm330j', '60');
insert into public.rm330j values (22, 'aged'), (55, 'frontier');
select child_oid as j_mono_oid from pgpm.part where parent_table = 'public.rm330j'::regclass and lo = '0' \gset
select pgpm.set_archive_fn('public.rm330j', 't330.uncounted(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.rm330j'::regclass;
create temporary table markj330 as select coalesce(max(id), 0) as id from pgpm.log;

call pgpm.maintain('public.rm330j');
call pgpm.maintain('public.rm330j');

select ok(exists (select 1 from t330.up where parent = 'public.rm330j'::regclass and p_lo = '0'),
  'LIVENESS: J: the strategy was handed the aged monolith [0, 20)');
select ok(exists (select 1 from pg_class where oid = :j_mono_oid),
  'J: retention keeps the monolith, whose chunk reports 0 rows over ids 1, 2 and 15');
select is((select array_agg(distinct l.lo || '-' || l.hi) from pgpm.log l
            where l.parent_table = 'public.rm330j'::regclass and l.action = 'archive_coverage_reset'
              and l.id > (select id from markj330)
              and l.method like '%t330.uncounted(regclass,name,text,text)%'
              and l.method like '%reported 0 instead of counting%'
              and l.method like '%or null when it does not count%'),
  array['0-20', '20-30'],
  'J: the archive_coverage_reset rows over [0, 20) and [20, 30) (id 22) name the strategy, the uncounted 0, and the remedy: report null');

-- the remedy as the row names it: the strategy, replaced in place, reports null when it does not count
create or replace function t330.uncounted(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into t330.up (parent, p_lo) values (p_parent, p_lo);
  v.covered_hi := p_hi; v.rows_archived := null;
  return v;
end $$;
call pgpm.maintain('public.rm330j');
call pgpm.maintain('public.rm330j');
select ok(not exists (select 1 from pg_class where oid = :j_mono_oid),
  'J: once the strategy reports null, retention retires the monolith (dropped)');

select * from finish();
