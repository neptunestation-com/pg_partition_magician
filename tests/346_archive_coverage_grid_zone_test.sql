-- Every reader of a stored archive-ledger bound reads it on the grid's clock, not the caller's (issue #1336, bullet 8).
--
-- THE DEFECT. Before #977 the archive step stored a strategy's covered_hi as the strategy wrote it, and a strategy
-- may write it with no offset ('2026-10-15 06:00:00'). No upgrade rewrites a ledger row, live or retired, and such
-- text names a different instant in every zone. #1305 (#1264) made _over_retired_chunks read a RETIRED row's bound
-- through pgpm._native_bound_key, on the grid's clock (config.partition_tz); every other reader still cast it in
-- the CALLER's session. _archive_fully_covered, retire()'s drop gate, read a live row's offset-less hi as many hours
-- later from a session west of the grid's zone, so retain() from America/New_York dropped a partly archived
-- partition with rows no strategy was handed.
--
-- THE CONTRACT. Every reader of a stored ledger bound gives the same answer from every session, the bound read as
-- pgpm._native_bound_ts reads it (offset-less text is wall time in partition_tz). One part per reader:
--   PART A  _archive_fully_covered, and retain() through it (the reported reader): a monolith archived three hours
--           short of its hi is not covered from Tokyo, UTC or New York, and retain() from New York keeps it.
--   PART B  _next_archive_chunk: the next chunk starts where the legacy hi ends on the grid's clock.
--   PART C  _discard_contradicted_coverage, through retain(): a 0-row chunk over a row is discarded from a session
--           east of the grid's zone too, where the session's own parse makes its range empty.
--   PART D  the archive step's orphan discard (#511): an orphan reaching into a tracked partition on the grid's
--           clock is discarded from such a session too.
--   PART E  _mark_retired_chunks, the upgrade's #1141 pass: a chunk inside a logged retain_drop is marked from UTC.
--   PART F  scripts/archive_partition_whole.sql resumes from the same instant as B.
--   PART G  LIVENESS of the gate: once the strategy archived the rest, retain() from New York drops the monolith.
--
-- THE FIXTURE. Every grid is registered in Asia/Tokyo (+09), so its wall clock is UTC's for no session below and a
-- fix that reads offset-less text as UTC, or in the caller's zone, fails. 1 second grids with retain 0 (tests/273's
-- shape) so the monoliths age past the horizon after a short sleep. Each part has a LIVENESS witness that the
-- session's own parse of the legacy text gives the other answer. Asymmetric: three rows in A (two archived, one
-- not), two in C (one archived, one in the 0-row chunk), two orphans in D (one discarded, one kept), two chunks in E
-- (one marked, one not); each check names which.
--
-- bench/archive_coverage_grid_zone.sh runs this file against bench/mutations/mutate.py's mutations, one per reader.
-- The script's path is the psql variable archive_whole_script, defaulting to the tree's copy, so the guard can point
-- it at a mutant.
create extension if not exists pgtap;
set client_min_messages = warning;
set datestyle = 'ISO, MDY';
set timezone = 'Asia/Tokyo';

\if :{?archive_whole_script}
\else
\set archive_whole_script /repo/scripts/archive_partition_whole.sql
\endif
\i :archive_whole_script

select plan(30);

create schema t346;
create table t346.calls (n serial primary key, p_child name, p_lo text, p_hi text);
create table t346.archived (parent regclass, ts timestamptz, body text);
create function t346.strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_n bigint;
begin
  insert into t346.calls (p_child, p_lo, p_hi) values (p_child, p_lo, p_hi);
  execute format('insert into t346.archived select %L::regclass, ts, body from %s where ts >= %L::timestamptz and ts < %L::timestamptz',
                 p_parent, p_parent, p_lo, p_hi);
  get diagnostics v_n = row_count;
  v.rows_archived := v_n;
  v.covered_hi := p_hi;
  return v;
end $$;
-- the text a pgpm before #977 stored: the instant as wall-clock text on the grid's clock, with no offset
create function t346.wall(p_at timestamptz) returns text language sql immutable as $$
  select to_char(p_at at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI:SS.US');
$$;

create table t346.a (ts timestamptz not null, body text);
insert into t346.a values (now() - interval '5 hours', 'early1'), (now() - interval '4 hours', 'early2'),
                          (now() - interval '1 hour', 'late');
create table t346.c (ts timestamptz not null, body text);
insert into t346.c values (now() - interval '4 hours', 'hidden'), (now() - interval '1 hour', 'kept');
create table t346.d (ts timestamptz not null, body text);
insert into t346.d values (now() - interval '2 hours', 'd1');
create table t346.d_orph (x int);
create table t346.e (ts timestamptz not null, body text);
insert into t346.e values (now() - interval '2 hours', 'e1');

call pgpm.transmute('t346.a', 'ts', interval '1 second', 3, p_retain => interval '0 seconds', p_paused => true);
call pgpm.transmute('t346.c', 'ts', interval '1 second', 3, p_retain => interval '0 seconds', p_paused => true);
call pgpm.transmute('t346.d', 'ts', interval '1 second', 3, p_paused => true);
call pgpm.transmute('t346.e', 'ts', interval '1 second', 3, p_paused => true);
select pgpm.set_archive_fn(p, 't346.strategy(regclass, name, text, text)')
  from unnest(array['t346.a', 't346.c', 't346.d', 't346.e']::regclass[]) p;

select child_name as a_mono, lo as a_lo, hi as a_hi from pgpm.part
 where parent_table = 't346.a'::regclass order by lo::timestamptz limit 1 \gset
select child_name as c_mono, lo as c_lo, hi as c_hi from pgpm.part
 where parent_table = 't346.c'::regclass order by lo::timestamptz limit 1 \gset
select lo as d_lo from pgpm.part where parent_table = 't346.d'::regclass order by lo::timestamptz limit 1 \gset

select is((select string_agg(distinct partition_tz, ',') from pgpm.config where parent_table::text like 't346.%'),
          'Asia/Tokyo', 'GUARD: every grid is registered in Asia/Tokyo, nine hours east of UTC');

-- ==================== (E) _mark_retired_chunks, first: no other parent has logged a retain_drop yet ====================
-- A retain_drop logged over [P, P + 1 h), as retire() logs one. e_in, archived from it with a legacy hi half an hour
-- short of P + 1 h, is that partition's chunk; e_out, after it, is not.
select pgpm._ts_text(now() - interval '10 hours') as e_p \gset
insert into pgpm.log (parent_table, action, lo, hi)
  values ('t346.e', 'retain_drop', :'e_p', pgpm._ts_text(:'e_p'::timestamptz + interval '1 hour'));
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, archived_at) values
  ('t346.e', :'e_p', t346.wall(:'e_p'::timestamptz + interval '30 minutes'), 'e_in', 1, now() - interval '1 day'),
  ('t346.e', pgpm._ts_text(:'e_p'::timestamptz + interval '1 hour'), pgpm._ts_text(:'e_p'::timestamptz + interval '2 hours'),
   'e_out', 1, now() - interval '1 day');
set timezone = 'UTC';
select ok(t346.wall(:'e_p'::timestamptz + interval '30 minutes')::timestamptz > :'e_p'::timestamptz + interval '1 hour',
          'LIVENESS: read in UTC, e_in''s legacy hi lies past the dropped range');
select pgpm._mark_retired_chunks();
select is((select string_agg(child_name || ':' || (retired_at is not null), ',' order by lo::timestamptz)
             from pgpm.archive_ledger where parent_table = 't346.e'::regclass),
          'e_in:true,e_out:false',
          'from UTC _mark_retired_chunks marks e_in, inside the logged drop on the grid''s clock, and not e_out');
delete from pgpm.archive_ledger where parent_table = 't346.e'::regclass;
set timezone = 'Asia/Tokyo';

-- ==================== the legacy chunks, then the monoliths age past retain 0 ====================
-- A: the monolith's first chunk, archived up to three hours short of its hi (early1 and early2), with the legacy hi.
insert into t346.archived select 't346.a', ts, body from t346.a where body in ('early1', 'early2');
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid)
  values ('t346.a', :'a_lo', t346.wall(:'a_hi'::timestamptz - interval '3 hours'), :'a_mono', 2,
          to_regclass('t346.' || :'a_mono')::oid);
-- C: a chunk of 0 rows over the range holding 'hidden' (legacy hi two hours short of the monolith's hi), then one
-- archiving 'kept' to the hi, so the watermark alone reads the monolith as covered.
insert into t346.archived select 't346.c', ts, body from t346.c where body = 'kept';
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid) values
  ('t346.c', :'c_lo', t346.wall(:'c_hi'::timestamptz - interval '2 hours'), :'c_mono', 0, to_regclass('t346.' || :'c_mono')::oid),
  ('t346.c', pgpm._ts_text(:'c_hi'::timestamptz - interval '2 hours'), :'c_hi', :'c_mono', 1, to_regclass('t346.' || :'c_mono')::oid);
-- D: two orphans under a name no partition tracks (a relation that exists, so neither is marked gone): d_orph reaches
-- an hour into the monolith on the grid's clock, d_far ends twenty hours before it.
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid) values
  ('t346.d', pgpm._ts_text(:'d_lo'::timestamptz - interval '3 hours'), t346.wall(:'d_lo'::timestamptz + interval '1 hour'),
   'd_orph', 1, 't346.d_orph'::regclass::oid),
  ('t346.d', pgpm._ts_text(:'d_lo'::timestamptz - interval '30 hours'), pgpm._ts_text(:'d_lo'::timestamptz - interval '20 hours'),
   'd_far', 1, 't346.d_orph'::regclass::oid);
-- the write block a tick would have put on the archived monoliths (without it retire() discards their coverage, #564)
select pgpm._install_write_block('t346.a', :'a_mono'), pgpm._install_write_block('t346.c', :'c_mono');
select pg_sleep(2.5);

-- ==================== (A) _archive_fully_covered, and retain() through it ====================
select ok(not pgpm._archive_fully_covered('t346.a', :'a_mono'),
          'from Asia/Tokyo the monolith archived three hours short of its hi is not covered');
set timezone = 'UTC';
select ok((select hi::timestamptz from pgpm.archive_ledger where parent_table = 't346.a'::regclass) > :'a_hi'::timestamptz,
          'LIVENESS: read in UTC, the legacy hi lies past the monolith''s hi');
select ok(not pgpm._archive_fully_covered('t346.a', :'a_mono'), 'from UTC the monolith is not covered');
set timezone = 'America/New_York';
select ok((select hi::timestamptz from pgpm.archive_ledger where parent_table = 't346.a'::regclass) > :'a_hi'::timestamptz,
          'LIVENESS: read in America/New_York, the legacy hi lies past the monolith''s hi');
select ok(not pgpm._archive_fully_covered('t346.a', :'a_mono'), 'from America/New_York the monolith is not covered');
select ok((select not pgpm._native_gt('time', :'a_hi', pgpm._retain_boundary(c)) from pgpm.config c
            where c.parent_table = 't346.a'::regclass),
          'LIVENESS: the monolith is past the retention horizon, so retain() reaches it');
select pgpm.retain('t346.a');
select ok(exists (select 1 from pgpm.part where parent_table = 't346.a'::regclass and child_name = :'a_mono')
          and to_regclass('t346.' || :'a_mono') is not null,
          'retain() from America/New_York keeps the partly archived monolith');
select is((select array_agg(body order by ts) from t346.a), array['early1', 'early2', 'late'],
          'every row, late included, is still readable through the parent');
select is((select count(*)::int from t346.calls), 0, 'and nothing was handed to the strategy');
select is(current_setting('TimeZone') || ' / ' || current_setting('DateStyle'), 'America/New_York / ISO, MDY',
          'the reads leave the caller''s TimeZone and DateStyle as they were');

-- ==================== (B) _next_archive_chunk resumes where the legacy hi ends on the grid's clock ====================
select is((select lo::timestamptz from pgpm._next_archive_chunk('t346.a', :'a_mono')),
          :'a_hi'::timestamptz - interval '3 hours',
          'from America/New_York the next chunk starts three hours short of the monolith''s hi');
set timezone = 'UTC';
select is((select lo::timestamptz || ' .. ' || hi::timestamptz from pgpm._next_archive_chunk('t346.a', :'a_mono')),
          (:'a_hi'::timestamptz - interval '3 hours') || ' .. ' || :'a_hi'::timestamptz,
          'from UTC the next chunk is the same, up to the monolith''s hi');

-- ==================== (C) _discard_contradicted_coverage, through retain() ====================
set timezone = 'Pacific/Kiritimati';
select ok((select hi::timestamptz from pgpm.archive_ledger where parent_table = 't346.c'::regclass and rows_archived = 0)
            <= :'c_lo'::timestamptz,
          'LIVENESS: read in Pacific/Kiritimati, the 0-row chunk''s legacy hi lies at or below its lo (an empty range)');
select ok(pgpm._archive_fully_covered('t346.c', :'c_mono'),
          'LIVENESS: the watermark reads the monolith as covered, so retire() asks the 0-row chunk');
select pgpm.retain('t346.c');
select ok(exists (select 1 from pgpm.part where parent_table = 't346.c'::regclass and child_name = :'c_mono')
          and to_regclass('t346.' || :'c_mono') is not null,
          'retain() from Pacific/Kiritimati keeps the monolith whose 0-row chunk holds hidden');
select is((select array_agg(body order by ts) from t346.c), array['hidden', 'kept'],
          'hidden, which no strategy archived, is still in the table');
select is((select rows::int from pgpm.log where parent_table = 't346.c'::regclass and action = 'archive_coverage_reset'
             and lo = :'c_lo'), 2,
          'the monolith''s two chunks were discarded as contradicted coverage (archive_coverage_reset)');
select is((select count(*)::int from pgpm.archive_ledger where parent_table = 't346.c'::regclass), 0,
          'and no chunk of the monolith is left in the ledger');

-- ==================== (D) the archive step's orphan discard ====================
select ok((select hi::timestamptz from pgpm.archive_ledger where parent_table = 't346.d'::regclass and child_name = 'd_orph')
            < :'d_lo'::timestamptz,
          'LIVENESS: read in Pacific/Kiritimati, d_orph''s legacy hi ends before the monolith');
select is(pgpm._archive_step('t346.d'), 0, 'LIVENESS: the archive step ran, with no partition to hand the strategy');
select is((select string_agg(child_name, ',') from pgpm.archive_ledger where parent_table = 't346.d'::regclass),
          'd_far', 'from Pacific/Kiritimati the step discards d_orph, which reaches into the monolith, and keeps d_far');
select ok(exists (select 1 from pgpm.log where parent_table = 't346.d'::regclass and action = 'archive_coverage_reset'
                   and method like '%for t346.d_orph,%'),
          'the discard is logged archive_coverage_reset, naming d_orph');

-- ==================== (F) the whole-partition script resumes on the grid's clock ====================
set timezone = 'America/New_York';
select ok(pgpm_archive_next_partition_whole('t346.a') like :'a_mono' || '%',
          'LIVENESS: from America/New_York the script archived the monolith');
select is((select p_lo::timestamptz from t346.calls where n = 1), :'a_hi'::timestamptz - interval '3 hours',
          'the script handed the strategy the monolith from three hours short of its hi, where the legacy chunk ends');
select is((select array_agg(body order by ts) from t346.archived where parent = 't346.a'::regclass),
          array['early1', 'early2', 'late'],
          'and the strategy archived late, the one row the legacy chunk left');

-- ==================== (G) LIVENESS of the gate ====================
select ok(pgpm._archive_fully_covered('t346.a', :'a_mono'),
          'LIVENESS: from America/New_York the monolith is covered once the rest is archived');
select pgpm.retain('t346.a');
select ok(exists (select 1 from pgpm.log where parent_table = 't346.a'::regclass and action = 'retain_drop'
                   and hi = :'a_hi'),
          'LIVENESS: retain() from America/New_York then drops the monolith');
set timezone = 'UTC';

select * from finish();
