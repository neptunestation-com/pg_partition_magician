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
select plan(45);

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
            like format('t309.a\_late holds [0, 100), over the retired chunk(s) [0, 100) of %s at t309.a/0,%%archive.to\_s3%%', :'a0'),
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

select * from finish();
