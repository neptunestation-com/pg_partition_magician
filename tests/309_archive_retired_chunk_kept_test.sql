-- The ledger row of a chunk whose partition retire() dropped is the record of the only copy of its rows, and no
-- archive_coverage_reset discards it (issue #1141 bullet 1).
--
-- THE DEFECT. retire() leaves each dropped partition's chunks in pgpm.archive_ledger as the record of where its
-- rows went, and the archive_fn strategy keys a chunk's object by parent and lo. A partition re-created over the
-- retired range by plain DDL and recorded with pgpm.adopt_partition then met five archive_coverage_reset sites
-- that did not ask whether a chunk's partition was already gone: _archive_step's orphan discard (a different
-- name, over a range a tracked partition now holds) deleted the retired chunk's row and the same tick archived
-- the new partition to the same key, over the only copy; and under the SAME name, which pgpm's deterministic
-- naming gives a re-created partition, adopt_partition, retire(), _enforce_write_blocks and regrain's swap
-- deleted it by name, while _next_archive_chunk and _archive_fully_covered read it as the new partition's own
-- coverage, so retire() could drop the late rows unarchived.
--
-- THE CONTRACT.
--   * retire() marks the chunks of the partition it drops (pgpm.archive_ledger.retired_at), in the transaction
--     of the drop, and no reset site deletes a marked row under any name.
--   * No reader counts a marked row as a live partition's coverage: _next_archive_chunk starts a same-name
--     partition at its own lo and _archive_fully_covered reads it uncovered.
--   * A partition over a retired chunk's range is not archived at all (its first chunk would be keyed where the
--     retired chunk's object is): _archive_step skips it, logged ONCE as skip_archive_retired_range naming the
--     retired chunk, its object and the remedy, and moves on to the parent's other partitions in the same tick;
--     retire() never drops it, since it is never covered. The operator script scripts/archive_partition_whole.sql
--     leaves it alone too.
--   * The upgrade backfill marks the chunks retired before the column existed: a row a retain_drop over a range
--     holding it postdates, and nothing else.
--
-- The strategy is a stub that keys an "object" by parent and lo, as pgpm_archive's transports do, and PUTs over
-- an existing one, so the object-level consequence is visible here without MinIO (tests/archive/db/50 is the
-- same contract against the real transport).
--
-- ASYMMETRIC FIXTURES. Every retired chunk holds ids 1..90 'old<id>' and every re-created partition ids 1..40
-- 'late<id>'; A's second partition holds ids 101..107 'mid<id>'. Each check names the rows or the chunk.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(101);

create schema t309;
-- every call the strategy gets, with the rows it was handed
create table t309.calls (parent regclass, child name, lo text, hi text, handed text);
-- the object store: one body per key, a PUT replaces it
create table t309.objects (key text primary key, body text);
create function t309.strat(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v_body text; v_n bigint; v_key text := p_parent::text || '/' || p_lo; v_r pgpm.archive_result;
begin
  execute format('select string_agg(id || '':'' || payload, '','' order by id), count(*) from %s where id >= %L and id < %L',
                 p_parent, p_lo, p_hi) into v_body, v_n;
  insert into t309.calls values (p_parent, p_child, p_lo, p_hi, coalesce(v_body, ''));
  insert into t309.objects values (v_key, coalesce(v_body, ''))
    on conflict (key) do update set body = excluded.body;
  v_r.covered_hi := p_hi; v_r.rows_archived := v_n; v_r.s3_key := v_key;
  return v_r;
end $$;
create function t309.expect(p_tag text, p_from int, p_to int) returns text language sql immutable as $$
  select string_agg(g || ':' || p_tag || g, ',' order by g) from generate_series(p_from, p_to) g $$;
-- a parent of step p_step, retention 100, ids 1..90 'old<id>', a frontier at 450, the stub strategy, no drops yet
create procedure t309.mk(p_rel text, p_step bigint) language plpgsql as $$
begin
  execute format('create table t309.%I (id bigint primary key, payload text not null)', p_rel);
  execute format('insert into t309.%I select g, ''old'' || g from generate_series(1, 90) g', p_rel);
  call pgpm.transmute('t309.' || p_rel, 'id', p_step, p_retain => 100::bigint, p_paused => false);
  perform pgpm.extend_to(('t309.' || p_rel)::regclass, '500');
  execute format('insert into t309.%I values (450, ''frontier'')', p_rel);
  update pgpm.config set retain_batch = 0 where parent_table = ('t309.' || p_rel)::regclass;
  perform pgpm.set_archive_fn(('t309.' || p_rel)::regclass, 't309.strat(regclass,name,text,text)'::regprocedure);
end $$;

-- ============================ PART A: a different name, the orphan discard ============================
call t309.mk('a', 100);
insert into t309.a select g, 'mid' || g from generate_series(101, 107) g;
select child_name as a0 from pgpm.part where parent_table = 't309.a'::regclass and lo = '0' \gset
select child_name as a1 from pgpm.part where parent_table = 't309.a'::regclass and lo = '100' \gset
call pgpm.maintain('t309.a');
select is((select body from t309.objects where key = 't309.a/0'), t309.expect('old', 1, 90),
  'LIVENESS: A: the tick archived [0, 100) and its object holds ids 1..90 old<id>');
select ok(pgpm.retire('t309.a', :'a0'), 'LIVENESS: A: retire() dropped the covered partition [0, 100)');
select is((select format('%s|%s|%s|%s|%s', lo, hi, child_name, s3_key, rows_archived) from pgpm.archive_ledger
            where parent_table = 't309.a'::regclass and retired_at is not null),
          format('0|100|%s|t309.a/0|90', :'a0'),
  'A: retire() marked the dropped partition''s chunk retired, and only that one');
select is((select count(*)::int from pgpm.archive_ledger where parent_table = 't309.a'::regclass and retired_at is null), 0,
  'A: no live coverage is recorded for the parent (its [100, 200) has not been archived yet)');

create table t309.a_late partition of t309.a for values from (0) to (100);
insert into t309.a select g, 'late' || g from generate_series(1, 40) g;
select lives_ok($$ select pgpm.adopt_partition('t309.a', 't309.a_late') $$,
  'LIVENESS: A: adopt_partition records the re-created partition under another name');
call pgpm.maintain('t309.a');
select ok(pgpm._is_write_blocked('t309.a', 'a_late'),
  'LIVENESS: A: the tick write-blocked the re-created partition, which makes it an archive candidate');
select is(pgpm._archive_fully_covered('t309.a', 'a_late'), false, 'A: the re-created partition has no coverage');
select is((select format('%s|%s|%s|%s|%s', lo, hi, child_name, s3_key, rows_archived) from pgpm.archive_ledger
            where parent_table = 't309.a'::regclass and lo = '0'),
          format('0|100|%s|t309.a/0|90', :'a0'),
  'A: the retired chunk''s ledger row is where retire() left it');
select is((select body from t309.objects where key = 't309.a/0'), t309.expect('old', 1, 90),
  'A: the retired chunk''s object still holds ids 1..90 old<id>, the only copy of those rows');
select is((select count(*)::int from t309.calls where parent = 't309.a'::regclass and child = 'a_late'), 0,
  'A: the strategy was never handed the re-created partition');
select is((select string_agg(format('%s [%s, %s) %s', child, lo, hi, handed), '; ' order by lo::numeric) from t309.calls
            where parent = 't309.a'::regclass),
          format('%s [0, 100) %s; %s [100, 200) %s', :'a0', t309.expect('old', 1, 90), :'a1', t309.expect('mid', 101, 107)),
  'A: the tick that skipped it archived the parent''s next partition [100, 200) instead (no wedge at archive_batch 1)');
select is((select array_agg(action) from pgpm.log where parent_table = 't309.a'::regclass and action = 'archive_coverage_reset'),
  null::text[], 'A: no archive_coverage_reset was logged');
call pgpm.maintain('t309.a');
select is((select string_agg(format('%s|%s', lo, hi), ',') from pgpm.log
            where parent_table = 't309.a'::regclass and action = 'skip_archive_retired_range'),
  '0|100', 'A: the skip is logged once, over the re-created partition''s range, across two ticks');
select ok((select method from pgpm.log where parent_table = 't309.a'::regclass and action = 'skip_archive_retired_range')
            like format('t309.a\_late holds [0, 100), over chunk(s) pgpm.archive\_ledger marks retired: [0, 100) recorded for %s, whose relation no longer exists, at t309.a/0.%%archive.to\_s3%%', :'a0'),
  'A: its method names the retired chunk, its object key and the remedy');
select is((select string_agg(id || ':' || payload, ',' order by id) from t309.a where id < 100), t309.expect('late', 1, 40),
  'A: the re-created partition keeps ids 1..40 late<id>');
update pgpm.config set retain_batch = null where parent_table = 't309.a'::regclass;
select is(pgpm.retire('t309.a', 'a_late'), false, 'A: retire() does not drop the re-created partition, which is never covered');
select ok(to_regclass('t309.a_late') is not null, 'A: and the partition is still there');

-- ============================ PART B: the same name (adopt, retire, write blocks, readers, regrain's rename) ===
call t309.mk('b', 100);
select child_name as b0 from pgpm.part where parent_table = 't309.b'::regclass and lo = '0' \gset
call pgpm.maintain('t309.b');
select ok(pgpm.retire('t309.b', :'b0'), 'LIVENESS: B: retire() dropped the covered partition [0, 100)');
select format('create table t309.%I partition of t309.b for values from (0) to (100)', :'b0') as mk_b \gset
:mk_b;
insert into t309.b select g, 'late' || g from generate_series(1, 40) g;
select is((select format('%s|%s|%s', child_name, s3_key, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.b'::regclass and lo = '0'),
          format('%s|t309.b/0|t', :'b0'),
  'LIVENESS: B: a partition of the retired one''s own name holds [0, 100), and the retired chunk is recorded under that name');
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 't309.b', 't309.' || quote_ident(:'b0')),
  'LIVENESS: B: adopt_partition records it');
select is((select format('%s|%s|%s', child_name, s3_key, rows_archived) from pgpm.archive_ledger
            where parent_table = 't309.b'::regclass and lo = '0'),
          format('%s|t309.b/0|90', :'b0'),
  'B: adopt_partition kept the retired chunk recorded under the adopted name');
-- as a chunk recorded before pgpm.archive_ledger.child_oid existed: no oid, so only retired_at tells the readers
-- below that it is not the new partition's coverage
update pgpm.archive_ledger set child_oid = null where parent_table = 't309.b'::regclass and lo = '0';
select is(pgpm._archive_fully_covered('t309.b', :'b0'), false,
  'B: _archive_fully_covered does not read the retired chunk as the new partition''s coverage');
select is((select lo from pgpm._next_archive_chunk('t309.b', :'b0')), '0',
  'B: _next_archive_chunk starts the new partition at its own lo, not past the retired chunk');
select ok(not pgpm._is_write_blocked('t309.b', :'b0'),
  'LIVENESS: B: the new partition has no write block when retire() reaches it');
update pgpm.config set retain_batch = null where parent_table = 't309.b'::regclass;
select is(pgpm.retire('t309.b', :'b0'), false, 'B: retire() does not drop it');
select is((select format('%s|%s', child_name, rows_archived) from pgpm.archive_ledger
            where parent_table = 't309.b'::regclass and lo = '0'),
          format('%s|90', :'b0'),
  'B: retire() kept the retired chunk recorded under the name it is retiring');
select pgpm._remove_write_block('t309.b', :'b0');
select pgpm._enforce_write_blocks('t309.b');
select ok(pgpm._is_write_blocked('t309.b', :'b0'),
  'LIVENESS: B: _enforce_write_blocks found the partition unblocked and blocked it');
select is((select format('%s|%s', child_name, rows_archived) from pgpm.archive_ledger
            where parent_table = 't309.b'::regclass and lo = '0'),
          format('%s|90', :'b0'),
  'B: _enforce_write_blocks kept the retired chunk recorded under that name');
call pgpm.maintain('t309.b');
select is((select string_agg(format('%s [%s, %s) %s', child, lo, hi, handed), '; ') from t309.calls
            where parent = 't309.b'::regclass and lo::numeric < 100),
          format('%s [0, 100) %s', :'b0', t309.expect('old', 1, 90)),
  'B: the strategy was handed the retired partition''s rows once, and never the new partition''s');
select is((select body from t309.objects where key = 't309.b/0'), t309.expect('old', 1, 90),
  'B: the retired chunk''s object still holds ids 1..90 old<id>');
select is((select array_agg(method) from pgpm.log where parent_table = 't309.b'::regclass and action = 'archive_coverage_reset'),
  null::text[], 'B: no archive_coverage_reset was logged');
-- regrain of the same-named partition: one step wide, so its first fine child takes its name (#266's rename)
select pgpm.set_retain('t309.b', null);
select lives_ok(format('select pgpm.regrain(%L, %L, %L)', 't309.b', :'b0', '50'),
  'LIVENESS: B: the re-created partition is regrained to step 50');
select is((select string_agg(id || ':' || payload, ',' order by id) from t309.b where id < 100), t309.expect('late', 1, 40),
  'LIVENESS: B: the regrain kept ids 1..40 late<id>');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.b'::regclass and lo = '0'),
          format('%s|90|t', :'b0'),
  'B: the regrain neither renamed nor discarded the retired chunk');

-- ============================ PART C: a coarse partition, regrain's swap ============================
call t309.mk('c', 50);
select child_name as c0 from pgpm.part where parent_table = 't309.c'::regclass and lo = '0' \gset
select is((select hi from pgpm.part where parent_table = 't309.c'::regclass and child_name = :'c0'), '100',
  'LIVENESS: C: [0, 100) is one coarse partition on a step-50 grid');
call pgpm.maintain('t309.c');
select ok(pgpm.retire('t309.c', :'c0'), 'LIVENESS: C: retire() dropped the covered partition [0, 100)');
select format('create table t309.%I partition of t309.c for values from (0) to (100)', :'c0') as mk_c \gset
:mk_c;
insert into t309.c select g, 'late' || g from generate_series(1, 40) g;
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 't309.c', 't309.' || quote_ident(:'c0')),
  'LIVENESS: C: adopt_partition records the coarse partition re-created under its own name');
select pgpm.set_retain('t309.c', null);
select lives_ok(format('select pgpm.regrain(%L, %L, %L)', 't309.c', :'c0', '50'),
  'LIVENESS: C: it is regrained into two fine partitions, and its swap drops it');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.c'::regclass and lo = '0'),
          format('%s|90|t', :'c0'),
  'C: the swap kept the retired chunk recorded under the source''s name');

-- ============================ PART D: the operator script, scripts/archive_partition_whole.sql ==========
-- It picks a partition to archive whole as _archive_step does, and leaves a partition over a retired chunk alone
-- for the same reason. A's re-created partition is write-blocked and uncovered (part A), and every other
-- write-blocked partition of A is covered, so nothing is eligible.
\i /repo/scripts/archive_partition_whole.sql
create function pg_temp.t309_whole(p_parent regclass) returns text language plpgsql as $$
begin
  return pgpm_archive_next_partition_whole(p_parent);
exception when others then
  return 'raised: ' || sqlerrm;
end $$;
select is(pg_temp.t309_whole('t309.a'), 'nothing eligible left to archive for t309.a',
  'D: the operator script finds nothing of A to archive: the re-created partition is not eligible');
select is((select string_agg(format('%s [%s, %s)', child, lo, hi), '; ' order by lo::numeric) from t309.calls
            where parent = 't309.a'::regclass and lo::numeric < 100),
          format('%s [0, 100)', :'a0'),
  'D: and the strategy was handed no chunk of [0, 100) but the retired partition''s');

-- ============================ PART E: the upgrade backfill ============================
-- What a pre-fix install leaves: the same chunks, unmarked. Beside them A's [100, 200), which no retain_drop
-- covers (it is live); a chunk of a partition dropped by hand, which pgpm.log has no retain_drop for; and a
-- chunk of [0, 100) archived AFTER retire() dropped it (what a pre-fix tick recorded for a re-created
-- partition once the orphan discard had cleared the way), which is that partition's coverage, not a retired one.
create temp table t309_marked as
  select parent_table::text as parent, lo, hi from pgpm.archive_ledger
   where parent_table in ('t309.a'::regclass, 't309.b'::regclass, 't309.c'::regclass) and retired_at is not null;
select is((select string_agg(format('%s [%s, %s)', parent, lo, hi), '; ' order by parent, lo::numeric) from t309_marked),
  't309.a [0, 100); t309.b [0, 100); t309.b [100, 200); t309.c [0, 100)',
  'LIVENESS: E: retire() marked the four chunks of the partitions it dropped (B''s tick also retired [100, 200))');
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived)
  values ('t309.a', '300', '400', 'a_gone_by_hand', 3), ('t309.a', '50', '60', 'a_late', 2);
update pgpm.archive_ledger set retired_at = null
 where parent_table in ('t309.a'::regclass, 't309.b'::regclass, 't309.c'::regclass);
select is(pgpm._mark_retired_chunks(), 4, 'E: the backfill marks four chunks');
select is((select string_agg(format('%s [%s, %s)', parent_table, lo, hi), '; ' order by parent_table::text, lo::numeric)
             from pgpm.archive_ledger where parent_table in ('t309.a'::regclass, 't309.b'::regclass, 't309.c'::regclass)
              and retired_at is not null),
  (select string_agg(format('%s [%s, %s)', parent, lo, hi), '; ' order by parent, lo::numeric) from t309_marked),
  'E: they are the chunks retire() marked; A''s live [100, 200), its hand-dropped [300, 400) and its [50, 60) archived after the drop are not');
select is(pgpm._mark_retired_chunks(), 0, 'E: a second run marks nothing');

-- ============================ PART F: dropped by hand, re-created under another name ===================
-- No retire(): the operator drops the archived partition, deletes its stale pgpm.part row as adopt_partition's
-- own refusal says to, and adopts a partition re-created over the range. The chunk is unmarked, but its relation
-- is gone, and the archive step reads that from the oid the chunk was recorded with.
call t309.mk('f', 100);
select child_name as f0 from pgpm.part where parent_table = 't309.f'::regclass and lo = '0' \gset
call pgpm.maintain('t309.f');
select is((select child_oid = to_regclass('t309.' || quote_ident(:'f0'))::oid from pgpm.archive_ledger
            where parent_table = 't309.f'::regclass and lo = '0'), true,
  'F: the archive step recorded the oid of the relation it read the chunk from');
select format('drop table t309.%I', :'f0') as drop_f \gset
:drop_f;
create table t309.f_late partition of t309.f for values from (0) to (100);
insert into t309.f select g, 'late' || g from generate_series(1, 40) g;
select throws_like($$ select pgpm.adopt_partition('t309.f', 't309.f_late') $$, '%If that row is stale%delete it, then adopt%',
  'LIVENESS: F: adopt_partition refuses while the stale pgpm.part row stands, and names deleting it');
delete from pgpm.part where parent_table = 't309.f'::regclass and child_name = :'f0';
select lives_ok($$ select pgpm.adopt_partition('t309.f', 't309.f_late') $$,
  'LIVENESS: F: adopt_partition records the re-created partition once the stale row is gone');
select is((select retired_at is null from pgpm.archive_ledger where parent_table = 't309.f'::regclass and lo = '0'), true,
  'LIVENESS: F: nothing has marked the dropped partition''s chunk yet');
call pgpm.maintain('t309.f');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.f'::regclass and lo = '0'),
          format('%s|90|t', :'f0'),
  'F: the tick marked the hand-dropped partition''s chunk retired instead of discarding it');
select is((select format('%s|%s|%s|%s', lo, hi, rows, method like '%dropped outside retire()%') from pgpm.log
            where parent_table = 't309.f'::regclass and action = 'archive_chunk_retired'),
  '0|100|1|t', 'F: logged archive_chunk_retired once, over the chunk, saying the partition was dropped outside retire()');
select is((select body from t309.objects where key = 't309.f/0'), t309.expect('old', 1, 90),
  'F: the chunk''s object still holds ids 1..90 old<id>');
select is((select count(*)::int from t309.calls where parent = 't309.f'::regclass and child = 'f_late'), 0,
  'F: the strategy was never handed the re-created partition');
select is((select string_agg(format('%s|%s', lo, hi), ',') from pgpm.log
            where parent_table = 't309.f'::regclass and action = 'skip_archive_retired_range'),
  '0|100', 'F: the re-created partition is held, logged skip_archive_retired_range');

-- ============================ PART G: dropped by hand, re-created under the same name ==================
-- The stale pgpm.part row records the dropped relation's oid; the readers match a chunk by the oid it was
-- recorded with, so the new relation does not inherit its coverage, and adopt_partition (which re-anchors the
-- row) marks the chunk retired rather than discarding it.
call t309.mk('g', 100);
select child_name as g0 from pgpm.part where parent_table = 't309.g'::regclass and lo = '0' \gset
call pgpm.maintain('t309.g');
select format('drop table t309.%I', :'g0') as drop_g \gset
:drop_g;
select format('create table t309.%I partition of t309.g for values from (0) to (100)', :'g0') as mk_g \gset
:mk_g;
insert into t309.g select g, 'late' || g from generate_series(1, 40) g;
select is((select format('%s|%s', child_name, retired_at is null) from pgpm.archive_ledger
            where parent_table = 't309.g'::regclass and lo = '0'),
          format('%s|t', :'g0'),
  'LIVENESS: G: the dropped relation''s chunk is unmarked, under the name the new relation now has');
select is(pgpm._archive_fully_covered('t309.g', :'g0'), false,
  'G: _archive_fully_covered does not read the dropped relation''s chunk as the new relation''s coverage');
select is((select lo from pgpm._next_archive_chunk('t309.g', :'g0')), '0',
  'G: _next_archive_chunk starts the new relation at its own lo');
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 't309.g', 't309.' || quote_ident(:'g0')),
  'LIVENESS: G: adopt_partition re-anchors the stale row to the new relation');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.g'::regclass and lo = '0'),
          format('%s|90|t', :'g0'),
  'G: adopt_partition marked the dropped relation''s chunk retired instead of discarding it');
select is((select array_agg(method) from pgpm.log where parent_table = 't309.g'::regclass and action = 'archive_coverage_reset'),
  null::text[], 'G: no archive_coverage_reset was logged');

-- ============================ PARTS H, I, J: an unanchored row (no pgpm.part.child_oid) ==================
-- With no oid on the pgpm.part row (an install older than the anchor), nothing refuses the same-named
-- relation on identity, so retire(), the write-block step and regrain's swap reach the dropped relation's
-- chunk by name. Each marks it retired first.
create procedure t309.mk_gone(p_rel text, p_step bigint) language plpgsql as $$
declare v_c name; v_s text;   -- v_s receives maintain's INOUT status
begin
  call t309.mk(p_rel, p_step);
  select child_name into v_c from pgpm.part where parent_table = ('t309.' || p_rel)::regclass and lo = '0';
  call pgpm.maintain(('t309.' || p_rel)::regclass, v_s);
  execute format('drop table t309.%I', v_c);
  execute format('create table t309.%I partition of t309.%I for values from (0) to (100)', v_c, p_rel);
  execute format('insert into t309.%I select g, ''late'' || g from generate_series(1, 40) g', p_rel);
  update pgpm.part set child_oid = null where parent_table = ('t309.' || p_rel)::regclass and child_name = v_c;
end $$;
call t309.mk_gone('h', 100);
select child_name as h0 from pgpm.part where parent_table = 't309.h'::regclass and lo = '0' \gset
select ok(not pgpm._is_write_blocked('t309.h', :'h0')
          and exists (select 1 from pgpm.archive_ledger where parent_table = 't309.h'::regclass and lo = '0' and retired_at is null),
  'LIVENESS: H: the re-created relation is unblocked and the dropped one''s chunk unmarked, under its name');
update pgpm.config set retain_batch = null where parent_table = 't309.h'::regclass;
select is(pgpm.retire('t309.h', :'h0'), false, 'H: retire() does not drop the re-created relation');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.h'::regclass and lo = '0'),
          format('%s|90|t', :'h0'),
  'H: retire() marked the dropped relation''s chunk retired instead of discarding it');

call t309.mk_gone('i', 100);
select child_name as i0 from pgpm.part where parent_table = 't309.i'::regclass and lo = '0' \gset
select pgpm._enforce_write_blocks('t309.i');
select ok(pgpm._is_write_blocked('t309.i', :'i0'),
  'LIVENESS: I: the write-block step found the re-created relation unblocked and blocked it');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.i'::regclass and lo = '0'),
          format('%s|90|t', :'i0'),
  'I: the write-block step marked the dropped relation''s chunk retired instead of discarding it');

call t309.mk_gone('j', 50);
select child_name as j0 from pgpm.part where parent_table = 't309.j'::regclass and lo = '0' \gset
select pgpm.set_retain('t309.j', null);
select lives_ok(format('select pgpm.regrain(%L, %L, %L)', 't309.j', :'j0', '50'),
  'LIVENESS: J: the coarse re-created relation is regrained, and its swap drops it');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.j'::regclass and lo = '0'),
          format('%s|90|t', :'j0'),
  'J: the swap marked the dropped relation''s chunk retired instead of discarding it');

-- ============================ PART K: a held partition takes no retain_batch slot ======================
call t309.mk('k', 100);
insert into t309.k select g, 'mid' || g from generate_series(101, 107) g;
select child_name as k0 from pgpm.part where parent_table = 't309.k'::regclass and lo = '0' \gset
select child_name as k1 from pgpm.part where parent_table = 't309.k'::regclass and lo = '100' \gset
call pgpm.maintain('t309.k');
select ok(pgpm.retire('t309.k', :'k0'), 'LIVENESS: K: retire() dropped the covered partition [0, 100)');
create table t309.k_late partition of t309.k for values from (0) to (100);
insert into t309.k select g, 'late' || g from generate_series(1, 40) g;
select pgpm.adopt_partition('t309.k', 't309.k_late');
update pgpm.config set retain_batch = 1 where parent_table = 't309.k'::regclass;
call pgpm.maintain('t309.k');
call pgpm.maintain('t309.k');
call pgpm.maintain('t309.k');
select ok(to_regclass('t309.k_late') is not null
          and exists (select 1 from pgpm.log where parent_table = 't309.k'::regclass and action = 'skip_archive_retired_range'),
  'LIVENESS: K: the re-created partition [0, 100), the oldest eligible, is held');
select is((select string_agg(handed, '|') from t309.calls where parent = 't309.k'::regclass and child = :'k1'),
  t309.expect('mid', 101, 107), 'LIVENESS: K: [100, 200) was archived whole');
select ok(to_regclass('t309.' || quote_ident(:'k1')) is null,
  'K: at retain_batch 1, retention dropped [100, 200) behind the held partition');

-- ============================ PART L: the upgrade backfill of child_oid ============================
-- What an install from before the column leaves: rows with no oid. A's live [100, 200) has a tracked name; a
-- row under a name nothing has, and one whose oid names no relation, are a dropped relation's; and a row under a
-- name pgpm.part does not record but a relation has (a partition dropped by hand and re-created under its own
-- name, its stale row deleted, not yet adopted) is marked too: nothing vouches that relation is the chunk's.
create table t309.a_kept (id bigint);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid)
  values ('t309.a', '600', '650', 'a_nothing', 1, null), ('t309.a', '800', '850', 'a_kept', 1, null),
         ('t309.a', '900', '950', 'a_gone_oid', 1, 1);
update pgpm.archive_ledger set child_oid = null where parent_table = 't309.a'::regclass and lo = '100';
create temp table t309_live as select parent_table, lo from pgpm.archive_ledger where retired_at is null;
select pgpm._backfill_chunk_oids();
select is((select string_agg(format('%s [%s, %s)', l.parent_table, l.lo, l.hi), '; ' order by l.parent_table::text, l.lo::numeric)
             from pgpm.archive_ledger l join t309_live v using (parent_table, lo) where l.retired_at is not null),
  't309.a [300, 400); t309.a [600, 650); t309.a [800, 850); t309.a [900, 950)',
  'L: the backfill marks every row pgpm.part does not vouch for (untracked names, gone oids), and only those');
select is((select child_oid = to_regclass('t309.' || quote_ident(:'a1'))::oid from pgpm.archive_ledger
            where parent_table = 't309.a'::regclass and lo = '100'), true,
  'L: a live row gets the oid pgpm.part records for its name');
select ok(to_regclass('t309.a_kept') is not null
          and (select retired_at is not null from pgpm.archive_ledger where parent_table = 't309.a'::regclass and lo = '800'),
  'L: a row under an untracked name a relation has now is marked retired, not left to be discarded by name');

-- ============================ PART M: the orphan discard deletes only unretired chunks of its name ======
-- [0, 100) is archived and retired under m0's name; the operator then gives [200, 300) that name (renaming the
-- partition and its pgpm.part row), it is archived under it, and is renamed again to m_moved. The next tick
-- discards [200, 300)'s chunk as an orphan (its relation lives on as m_moved, which archives afresh), and the
-- retired [0, 100) under the same name stays.
call t309.mk('m', 100);
insert into t309.m select g, 'far' || g from generate_series(201, 203) g;
update pgpm.config set archive_batch = null where parent_table = 't309.m'::regclass;
select child_name as m0 from pgpm.part where parent_table = 't309.m'::regclass and lo = '0' \gset
select child_name as m2 from pgpm.part where parent_table = 't309.m'::regclass and lo = '200' \gset
call pgpm.maintain('t309.m');
select ok(pgpm.retire('t309.m', :'m0'), 'LIVENESS: M: retire() dropped the covered partition [0, 100)');
delete from pgpm.archive_ledger where parent_table = 't309.m'::regclass and lo = '200';
select format('alter table t309.%I rename to %I', :'m2', :'m0') as ren_m \gset
:ren_m;
update pgpm.part set child_name = :'m0' where parent_table = 't309.m'::regclass and child_name = :'m2';
call pgpm.maintain('t309.m');
select is((select string_agg(format('%s [%s, %s) %s', child_name = :'m0', lo, hi, retired_at is not null), '; ' order by lo::numeric)
             from pgpm.archive_ledger where parent_table = 't309.m'::regclass and lo in ('0', '200')),
  't [0, 100) t; t [200, 300) f',
  'LIVENESS: M: a retired and a live chunk are recorded under one name');
select format('alter table t309.%I rename to m_moved', :'m0') as ren_m2 \gset
:ren_m2;
update pgpm.part set child_name = 'm_moved' where parent_table = 't309.m'::regclass and child_name = :'m0';
call pgpm.maintain('t309.m');
select is((select format('%s|%s', lo, rows) from pgpm.log where parent_table = 't309.m'::regclass and action = 'archive_coverage_reset'),
  '200|1', 'LIVENESS: M: the tick discarded the renamed partition''s chunk as an orphan');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.m'::regclass and lo = '0'),
          format('%s|90|t', :'m0'),
  'M: the retired chunk under the same name stays');

-- ============================ PARTS N and O: a chunk under an UNANCHORED pgpm.part row, on upgrade ======
-- An install from before pgpm.part.child_oid had an archived partition dropped by hand: the #421 backfill cannot
-- anchor its row (the relation is gone), so the chunk's backfill finds a pgpm.part row with no oid. It vouches
-- for nothing, so the chunk is marked retired. Then the partition is re-created: N under its own name (adopt
-- re-anchors the stale row), O under another (the stale row deleted first, as adopt's refusal says). Either
-- way the next tick holds it, and the object keeps ids 1..90.
create procedure t309.mk_unanchored(p_rel text) language plpgsql as $$
declare v_c name; v_s text;   -- v_s receives maintain's INOUT status
begin
  call t309.mk(p_rel, 100);
  select child_name into v_c from pgpm.part where parent_table = ('t309.' || p_rel)::regclass and lo = '0';
  call pgpm.maintain(('t309.' || p_rel)::regclass, v_s);
  execute format('drop table t309.%I', v_c);
  -- what that older install leaves once the columns are added
  update pgpm.part set child_oid = null where parent_table = ('t309.' || p_rel)::regclass and child_name = v_c;
  update pgpm.archive_ledger set child_oid = null, retired_at = null
   where parent_table = ('t309.' || p_rel)::regclass and lo = '0';
end $$;
call t309.mk_unanchored('n');
call t309.mk_unanchored('o');
select child_name as n0 from pgpm.part where parent_table = 't309.n'::regclass and lo = '0' \gset
select child_name as o0 from pgpm.part where parent_table = 't309.o'::regclass and lo = '0' \gset
select is((select string_agg(format('%s [%s, %s) %s|%s', parent_table, lo, hi, child_oid is null, retired_at is null), '; '
                             order by parent_table::text)
             from pgpm.archive_ledger where parent_table in ('t309.n'::regclass, 't309.o'::regclass) and lo = '0'),
  't309.n [0, 100) t|t; t309.o [0, 100) t|t',
  'LIVENESS: N, O: each dropped partition''s chunk has no oid and no mark, under an unanchored pgpm.part row');
select pgpm._backfill_chunk_oids();
select is((select string_agg(format('%s|%s', parent_table, retired_at is not null), '; ' order by parent_table::text)
             from pgpm.archive_ledger where parent_table in ('t309.n'::regclass, 't309.o'::regclass) and lo = '0'),
  't309.n|t; t309.o|t',
  'N, O: the backfill marks a chunk whose pgpm.part row is unanchored retired');
select is((select count(*)::int from pgpm.archive_ledger where child_oid is null and retired_at is null
            and child_name not in ('a_late', 'a_kept')), 0,
  'N, O: after the backfill no row is both oid-less and unmarked but the ones this file wrote by hand');
-- N: re-created under its own name, adopted (the stale row is re-anchored)
select format('create table t309.%I partition of t309.n for values from (0) to (100)', :'n0') as mk_n \gset
:mk_n;
insert into t309.n select g, 'late' || g from generate_series(1, 40) g;
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 't309.n', 't309.' || quote_ident(:'n0')),
  'LIVENESS: N: adopt_partition re-anchors the stale row to the re-created partition');
call pgpm.maintain('t309.n');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.n'::regclass and lo = '0'),
          format('%s|90|t', :'n0'),
  'N: the chunk is still recorded, retired, after adopt and a tick');
select is((select body from t309.objects where key = 't309.n/0'), t309.expect('old', 1, 90),
  'N: its object still holds ids 1..90 old<id>');
-- O: re-created under another name, the stale row deleted, adopted
delete from pgpm.part where parent_table = 't309.o'::regclass and child_name = :'o0';
create table t309.o_late partition of t309.o for values from (0) to (100);
insert into t309.o select g, 'late' || g from generate_series(1, 40) g;
select lives_ok($$ select pgpm.adopt_partition('t309.o', 't309.o_late') $$,
  'LIVENESS: O: adopt_partition records the partition re-created under another name');
call pgpm.maintain('t309.o');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.o'::regclass and lo = '0'),
          format('%s|90|t', :'o0'),
  'O: the chunk is still recorded, retired, after adopt and a tick');
select is((select body from t309.objects where key = 't309.o/0'), t309.expect('old', 1, 90),
  'O: its object still holds ids 1..90 old<id>');

-- ============================ PART P: a row with no oid whose name resolves to nothing is gone ==========
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived)
  values ('t309.a', '1000', '1050', 'a_never', 1);
select is(pgpm._mark_gone_chunks('t309.a'), 1, 'P: _mark_gone_chunks marks one row');
select is((select retired_at is not null from pgpm.archive_ledger where parent_table = 't309.a'::regclass and lo = '1000'), true,
  'P: it is the oid-less row under a name no relation has');

-- ============================ PART Q: a partition renamed before the upgrade ============================
-- The #511 case: the operator renamed a partly archived partition and updated pgpm.part.child_name, leaving its
-- ledger rows under the old name. The upgrade cannot tell that from a partition dropped by hand (both: a name no
-- relation and no pgpm.part row has), so it marks the rows retired and the live renamed partition is held. The
-- skip row names the remedy that is safe because its rows are the chunks' rows, and once it is applied the
-- partition archives afresh.
call t309.mk('q', 100);
select child_name as q0 from pgpm.part where parent_table = 't309.q'::regclass and lo = '0' \gset
call pgpm.maintain('t309.q');
select format('alter table t309.%I rename to q_renamed', :'q0') as ren_q \gset
:ren_q;
update pgpm.part set child_name = 'q_renamed' where parent_table = 't309.q'::regclass and child_name = :'q0';
update pgpm.archive_ledger set child_oid = null, retired_at = null where parent_table = 't309.q'::regclass and lo = '0';
select pgpm._backfill_chunk_oids();
select is((select format('%s|%s', child_name, retired_at is not null) from pgpm.archive_ledger
            where parent_table = 't309.q'::regclass and lo = '0'),
  format('%s|t', :'q0'), 'LIVENESS: Q: the upgrade marked the old name''s chunk retired, as it would a dropped partition''s');
call pgpm.maintain('t309.q');
select ok((select method from pgpm.log where parent_table = 't309.q'::regclass and action = 'skip_archive_retired_range')
            like format('%%because q\_renamed is the relation those chunks were read from, renamed%%delete the retired rows recorded under %s%%', :'q0'),
  'Q: the held partition''s skip row names the rename remedy, with the old name');
select is((select count(*)::int from pgpm.log where parent_table = 't309.q'::regclass and action = 'skip_archive_retired_range'
            and method like '%retire() dropped%'), 0,
  'Q: and does not say retire() dropped a partition nothing dropped');
delete from pgpm.archive_ledger where parent_table = 't309.q'::regclass and child_name = :'q0' and retired_at is not null;
call pgpm.maintain('t309.q');
select is((select format('%s|%s|%s', child_name, rows_archived, retired_at is null) from pgpm.archive_ledger
            where parent_table = 't309.q'::regclass and lo = '0'),
  'q_renamed|90|t', 'Q: after the remedy the renamed partition archives afresh, all 90 rows');

-- ============================ PART R: a retired chunk with no child_name ============================
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, retired_at)
  values ('t309.f', '50', '60', null, 1, now());
create function pg_temp.t309_chunks(p_parent regclass) returns text language plpgsql as $$
begin
  return (select string_agg(chunks, ' | ') from pgpm._over_retired_chunks(p_parent));
exception when others then
  return 'raised: ' || sqlerrm;
end $$;
select ok(pg_temp.t309_chunks('t309.f') like '%[50, 60) recorded for an unnamed partition, whose relation no longer exists, at no object key%',
  'R: a retired chunk with no child_name is described, not refused');
call pgpm.maintain('t309.f');
select is((select array_agg(method) from pgpm.log where parent_table = 't309.f'::regclass and action = 'skip_archive'),
  null::text[], 'R: and the tick over it logs no skip_archive');

-- ============================ PART S: a same-name successor the #421 backfill anchored, on upgrade ======
-- A pre-#421 install: [0, 100) archived, dropped by hand and re-created under its own name, its pgpm.part row
-- kept. The #421 backfill anchors that row to whatever holds the name, the successor, which carries no write
-- block. The chunk's backfill attributes a chunk only to a write-blocked relation, so the dropped relation's
-- chunk is marked retired and the successor is held. CONTROL: [100, 200), live, write-blocked and archived, is
-- attributed and retired as usual.
call t309.mk('s', 100);
insert into t309.s select g, 'mid' || g from generate_series(101, 107) g;
update pgpm.config set archive_batch = null where parent_table = 't309.s'::regclass;
select child_name as s0 from pgpm.part where parent_table = 't309.s'::regclass and lo = '0' \gset
select child_name as s1 from pgpm.part where parent_table = 't309.s'::regclass and lo = '100' \gset
call pgpm.maintain('t309.s');
select format('drop table t309.%I', :'s0') as drop_s \gset
:drop_s;
select format('create table t309.%I partition of t309.s for values from (0) to (100)', :'s0') as mk_s \gset
:mk_s;
insert into t309.s select g, 'late' || g from generate_series(1, 40) g;
-- what the older install leaves once the columns are added, and the #421 backfill has run
update pgpm.part set child_oid = to_regclass('t309.' || quote_ident(:'s0'))::oid
 where parent_table = 't309.s'::regclass and child_name = :'s0';
update pgpm.archive_ledger set child_oid = null, retired_at = null
 where parent_table = 't309.s'::regclass and lo in ('0', '100');
select ok(not pgpm._is_write_blocked('t309.s', :'s0') and pgpm._is_write_blocked('t309.s', :'s1')
          and (select count(*) from pgpm.archive_ledger where parent_table = 't309.s'::regclass
                and lo in ('0', '100') and child_oid is null and retired_at is null) = 2,
  'LIVENESS: S: the successor of [0, 100) is unblocked, [100, 200) is blocked, and both chunks are unattributed');
select pgpm._backfill_chunk_oids();
select is((select string_agg(format('%s|%s|%s', lo, child_oid is null, retired_at is not null), '; ' order by lo::numeric)
             from pgpm.archive_ledger where parent_table = 't309.s'::regclass and lo in ('0', '100')),
  '0|t|t; 100|f|f',
  'S: the dropped relation''s chunk is marked retired, not attributed to the successor; the blocked one is attributed');
select is((select child_oid = to_regclass('t309.' || quote_ident(:'s1'))::oid from pgpm.archive_ledger
            where parent_table = 't309.s'::regclass and lo = '100'), true,
  'S: CONTROL: [100, 200)''s chunk has its relation''s oid');
update pgpm.config set retain_batch = null where parent_table = 't309.s'::regclass;
call pgpm.maintain('t309.s');
select is((select body from t309.objects where key = 't309.s/0'), t309.expect('old', 1, 90),
  'S: the dropped relation''s object still holds ids 1..90 old<id>');
select ok(to_regclass('t309.' || quote_ident(:'s0')) is not null
          and (select method from pgpm.log where parent_table = 't309.s'::regclass and action = 'skip_archive_retired_range')
              like format('%%[0, 100) recorded for %s, which pgpm cannot tie to the relation holding that name now,%%archive.to\_s3%%', :'s0'),
  'S: the successor is held, and its skip row says the chunk is not tied to it and names the export remedy');
select ok(to_regclass('t309.' || quote_ident(:'s1')) is null,
  'S: CONTROL: the attributed [100, 200) is retired as usual');

select * from finish();
