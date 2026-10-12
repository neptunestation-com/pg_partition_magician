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
--
-- Identity, not cardinality: every assertion names which partition (by its range) or which ids. Fixtures are
-- asymmetric: three ids in the operator's table against one in the archived sibling (A), one vouched mark
-- against two unvouched (B), three ids against two (C).
--
-- bench/retirement_mark_needs_dispatch.sh runs this file against bench/mutations/mutate.py's
-- retirement_mark_vouches_alone (part B), archive_hold_vouches_detached_retirement (parts B and D),
-- retirement_mark_readers_whole (parts A to D) and archive_hold_passes_unanchored (part E). The script's path is
-- the psql variable archive_whole_script, defaulting to the tree's copy.
create extension if not exists pgtap;
set client_min_messages = warning;

\if :{?archive_whole_script}
\else
\set archive_whole_script /repo/scripts/archive_partition_whole.sql
\endif
\i :archive_whole_script

select plan(40);

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

select * from finish();
