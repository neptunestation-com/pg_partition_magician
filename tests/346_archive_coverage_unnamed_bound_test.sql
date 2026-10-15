-- A live archive-ledger bound that names no instant by itself proves no coverage (issue #1336, bullet 8).
--
-- THE DEFECT. Before #977 the archive step checked a strategy's covered_hi with a cast in whatever session ran it
-- (pg_cron's, an operator's) and stored the text as written, and no upgrade rewrites a ledger row. Text with no
-- offset ('2026-10-15 06:00:00') names a different instant in every zone, and the zone of the session that checked
-- it was recorded nowhere. _archive_fully_covered, retire()'s drop gate, read it with max(hi::timestamptz) in the
-- CALLER's zone, so retain() from a session west of the writer's read it as hours later and dropped a partly
-- archived partition with rows no strategy was handed. Reading it on the grid's clock instead (config.partition_tz)
-- is no fix: a chunk an Asia/Tokyo session checked on a UTC grid reads nine hours late there.
--
-- THE CONTRACT. A live chunk whose bound names no instant by itself (pgpm._native_named) opens no drop gate from any
-- session, and the archive step (and scripts/archive_partition_whole.sql) discards that partition's live coverage,
-- logged archive_coverage_reset, and archives it again from lo, after which the gate opens on what was re-archived.
-- The archive step's orphan discard (#511) discards an orphan whose bound names no instant rather than place it, and
-- the upgrade's _mark_retired_chunks places such a chunk by its other bound.
--   PART A  the issue's shape: a UTC grid, a chunk written as UTC wall time, retain() from America/New_York.
--   PART B  written from Asia/Tokyo (east of the grid): retain() from UTC, the grid's own zone.
--   PART C  written from America/New_York (west of the grid): retain() from Pacific/Honolulu.
--   PART D  the remedy: one archive step re-archives each from its lo, and retain() then drops all three.
--   PART E  the orphan discard, from Pacific/Kiritimati.
--   PART F  _mark_retired_chunks, from UTC.
--   PART G  the whole-partition script discards and re-archives the same way.
--
-- THE FIXTURE. UTC grids of 1 second with retain 0 (tests/273's shape), so the monoliths age past the horizon after a
-- short sleep. Every monolith holds early1 and early2, which its legacy chunk archived, and late, which it did not;
-- the chunk's hi is the writer's wall time three hours short of the monolith's hi, with no offset. Each part has a
-- LIVENESS witness that the attacking session's own parse reads that hi past the monolith's hi. Asymmetric: two rows
-- archived and one not per monolith, two orphans in E (one discarded, one kept), two chunks in F (one marked, one
-- not); each check names which.
--
-- bench/archive_coverage_unnamed_bound.sh runs this file against bench/mutations/mutate.py's mutations. The script's path
-- is the psql variable archive_whole_script, defaulting to the tree's copy, so the guard can point it at a mutant.
create extension if not exists pgtap;
set client_min_messages = warning;
set datestyle = 'ISO, MDY';
set timezone = 'UTC';

\if :{?archive_whole_script}
\else
\set archive_whole_script /repo/scripts/archive_partition_whole.sql
\endif
\i :archive_whole_script

select plan(35);

create schema t346;
create table t346.calls (n serial primary key, parent regclass, p_child name, p_lo text, p_hi text);
create table t346.archived (parent regclass, ts timestamptz, body text);
create function t346.strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_n bigint;
begin
  insert into t346.calls (parent, p_child, p_lo, p_hi) values (p_parent, p_child, p_lo, p_hi);
  execute format('insert into t346.archived select %L::regclass, ts, body from %s where ts >= %L::timestamptz and ts < %L::timestamptz',
                 p_parent, p_parent, p_lo, p_hi);
  get diagnostics v_n = row_count;
  v.rows_archived := v_n;
  v.covered_hi := p_hi;
  return v;
end $$;
-- the text a pgpm before #977 stored: the instant as wall-clock text in the writing session's zone, with no offset
create function t346.wall(p_at timestamptz, p_zone text) returns text language sql immutable as $$
  select to_char(p_at at time zone p_zone, 'YYYY-MM-DD HH24:MI:SS.US');
$$;

-- four monoliths, each with the legacy chunk its writer's session left
do $$
declare t text;
begin
  foreach t in array array['a', 'b', 'w', 'f'] loop
    execute format('create table t346.%I (ts timestamptz not null, body text)', t);
    execute format('insert into t346.%I values (now() - interval ''5 hours'', ''early1''), (now() - interval ''4 hours'', ''early2''), (now() - interval ''1 hour'', ''late'')', t);
  end loop;
end $$;
call pgpm.transmute('t346.a', 'ts', interval '1 second', 3, p_retain => interval '0 seconds', p_paused => true);
call pgpm.transmute('t346.b', 'ts', interval '1 second', 3, p_retain => interval '0 seconds', p_paused => true);
call pgpm.transmute('t346.w', 'ts', interval '1 second', 3, p_retain => interval '0 seconds', p_paused => true);
call pgpm.transmute('t346.f', 'ts', interval '1 second', 3, p_retain => interval '0 seconds', p_paused => true);
create table t346.d (ts timestamptz not null, body text);
insert into t346.d values (now() - interval '2 hours', 'd1');
create table t346.d_orph (x int);
call pgpm.transmute('t346.d', 'ts', interval '1 second', 3, p_paused => true);
create table t346.e (ts timestamptz not null, body text);
insert into t346.e values (now() - interval '2 hours', 'e1');
call pgpm.transmute('t346.e', 'ts', interval '1 second', 3, p_paused => true);
select pgpm.set_archive_fn(p, 't346.strategy(regclass, name, text, text)')
  from unnest(array['t346.a', 't346.b', 't346.w', 't346.f', 't346.d', 't346.e']::regclass[]) p;

create table t346.mono as
  select distinct on (p.parent_table) p.parent_table as parent, p.child_name, p.lo, p.hi
    from pgpm.part p where p.parent_table::text in ('t346.a', 't346.b', 't346.w', 't346.f', 't346.d')
   order by p.parent_table, p.lo::timestamptz;
select child_name as a_mono, lo as a_lo, hi as a_hi from t346.mono where parent = 't346.a'::regclass \gset
select child_name as b_mono, lo as b_lo, hi as b_hi from t346.mono where parent = 't346.b'::regclass \gset
select child_name as w_mono, lo as w_lo, hi as w_hi from t346.mono where parent = 't346.w'::regclass \gset
select child_name as f_mono, lo as f_lo, hi as f_hi from t346.mono where parent = 't346.f'::regclass \gset
select lo as d_lo from t346.mono where parent = 't346.d'::regclass \gset

select is((select string_agg(distinct partition_tz, ',') from pgpm.config where parent_table::text like 't346.%'),
          'UTC', 'GUARD: every grid is registered in UTC');

-- ==================== (F) _mark_retired_chunks, first: no other parent has logged a retain_drop yet ====================
-- A retain_drop logged over [P, P + 1 h), as retire() logs one. e_in, archived from it before the drop with a hi an
-- Asia/Tokyo session wrote, half an hour past P on its own clock, is that partition's chunk; e_out, after it, is not.
select pgpm._ts_text(now() - interval '10 hours') as e_p \gset
insert into pgpm.log (parent_table, action, lo, hi)
  values ('t346.e', 'retain_drop', :'e_p', pgpm._ts_text(:'e_p'::timestamptz + interval '1 hour'));
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, archived_at) values
  ('t346.e', :'e_p', t346.wall(:'e_p'::timestamptz + interval '30 minutes', 'Asia/Tokyo'), 'e_in', 1, now() - interval '1 day'),
  ('t346.e', pgpm._ts_text(:'e_p'::timestamptz + interval '1 hour'), pgpm._ts_text(:'e_p'::timestamptz + interval '2 hours'),
   'e_out', 1, now() - interval '1 day');
select ok(t346.wall(:'e_p'::timestamptz + interval '30 minutes', 'Asia/Tokyo')::timestamptz > :'e_p'::timestamptz + interval '1 hour',
          'LIVENESS: read in UTC, e_in''s legacy hi lies past the dropped range');
select pgpm._mark_retired_chunks();
select is((select string_agg(child_name || ':' || (retired_at is not null), ',' order by lo::timestamptz)
             from pgpm.archive_ledger where parent_table = 't346.e'::regclass),
          'e_in:true,e_out:false',
          'from UTC _mark_retired_chunks marks e_in, whose lo lies inside the logged drop, and not e_out');
delete from pgpm.archive_ledger where parent_table = 't346.e'::regclass;

-- ==================== the legacy chunks, then the monoliths age past retain 0 ====================
insert into t346.archived select 't346.a', ts, body from t346.a where body <> 'late';
insert into t346.archived select 't346.b', ts, body from t346.b where body <> 'late';
insert into t346.archived select 't346.w', ts, body from t346.w where body <> 'late';
insert into t346.archived select 't346.f', ts, body from t346.f where body <> 'late';
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid)
select m.parent, m.lo, t346.wall(m.hi::timestamptz - interval '3 hours', z.zone), m.child_name, 2,
       to_regclass('t346.' || m.child_name)::oid
  from t346.mono m join (values ('t346.a'::regclass, 'UTC'), ('t346.b'::regclass, 'Asia/Tokyo'),
                                ('t346.w'::regclass, 'America/New_York'), ('t346.f'::regclass, 'Asia/Tokyo')) z(parent, zone)
    on z.parent = m.parent;
-- E: two orphans under a name no partition tracks (a relation that exists, so neither is marked gone): d_orph, written
-- as UTC wall time, reaches an hour into the monolith; d_far ends twenty hours before it, with its offsets.
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid) values
  ('t346.d', pgpm._ts_text(:'d_lo'::timestamptz - interval '3 hours'), t346.wall(:'d_lo'::timestamptz + interval '1 hour', 'UTC'),
   'd_orph', 1, 't346.d_orph'::regclass::oid),
  ('t346.d', pgpm._ts_text(:'d_lo'::timestamptz - interval '30 hours'), pgpm._ts_text(:'d_lo'::timestamptz - interval '20 hours'),
   'd_far', 1, 't346.d_orph'::regclass::oid);
-- the write block a tick would have put on the archived monoliths (without it retire() discards their coverage, #564)
select pgpm._install_write_block(m.parent, m.child_name) from t346.mono m where m.parent::text <> 't346.d';
select pg_sleep(2.5);
select ok((select bool_and(not pgpm._native_gt('time', m.hi, pgpm._retain_boundary(c)))
             from t346.mono m join pgpm.config c on c.parent_table = m.parent),
          'LIVENESS: every monolith is past the retention horizon, so retain() reaches it');

-- ==================== (A) the issue's shape: UTC wall time, retain() from America/New_York ====================
set timezone = 'America/New_York';
select ok((select hi::timestamptz from pgpm.archive_ledger where parent_table = 't346.a'::regclass) > :'a_hi'::timestamptz,
          'LIVENESS: read in America/New_York, a''s legacy hi lies past the monolith''s hi');
select ok(not pgpm._archive_fully_covered('t346.a', :'a_mono'), 'from America/New_York a''s monolith is not covered');
select pgpm.retain('t346.a');
select ok(to_regclass('t346.' || :'a_mono') is not null, 'retain() from America/New_York keeps a''s partly archived monolith');
select is((select array_agg(body order by ts) from t346.a), array['early1', 'early2', 'late'],
          'every row of a, late included, is still readable through the parent');

-- ==================== (B) written from Asia/Tokyo, east of the grid: retain() from UTC, the grid's own zone ====================
set timezone = 'UTC';
select ok((select hi::timestamptz from pgpm.archive_ledger where parent_table = 't346.b'::regclass) > :'b_hi'::timestamptz,
          'LIVENESS: read on the grid''s clock (UTC), b''s legacy hi lies past the monolith''s hi');
select ok((select (hi || ' Asia/Tokyo')::timestamptz from pgpm.archive_ledger where parent_table = 't346.b'::regclass)
            < :'b_hi'::timestamptz,
          'LIVENESS: read as the Tokyo session that wrote it meant it, b''s legacy hi is three hours short');
select ok(not pgpm._archive_fully_covered('t346.b', :'b_mono'), 'from UTC b''s monolith is not covered');
select pgpm.retain('t346.b');
select ok(to_regclass('t346.' || :'b_mono') is not null, 'retain() from UTC keeps b''s partly archived monolith');
select is((select array_agg(body order by ts) from t346.b), array['early1', 'early2', 'late'],
          'every row of b, late included, is still readable through the parent');

-- ==================== (C) written from America/New_York, west of the grid: retain() from Pacific/Honolulu ====================
set timezone = 'Pacific/Honolulu';
select ok((select hi::timestamptz from pgpm.archive_ledger where parent_table = 't346.w'::regclass) > :'w_hi'::timestamptz,
          'LIVENESS: read in Pacific/Honolulu, w''s legacy hi lies past the monolith''s hi');
select ok(not pgpm._archive_fully_covered('t346.w', :'w_mono'), 'from Pacific/Honolulu w''s monolith is not covered');
select pgpm.retain('t346.w');
select ok(to_regclass('t346.' || :'w_mono') is not null, 'retain() from Pacific/Honolulu keeps w''s partly archived monolith');
select is((select array_agg(body order by ts) from t346.w), array['early1', 'early2', 'late'],
          'every row of w, late included, is still readable through the parent');
select is((select count(*)::int from t346.calls), 0, 'and nothing was handed to the strategy yet');

-- ==================== (D) the remedy: the archive step re-archives each from its lo ====================
set timezone = 'America/New_York';
select is((select count(*)::int from unnest(array['t346.a', 't346.b', 't346.w']::regclass[]) p where pgpm._archive_step(p) = 1),
          3, 'LIVENESS: from America/New_York one archive step per parent recorded one chunk');
select is((select string_agg(c.parent::text || ':' || (c.p_lo::timestamptz = m.lo::timestamptz) || ':'
                             || (c.p_hi::timestamptz = m.hi::timestamptz), ',' order by c.parent::text)
             from t346.calls c join t346.mono m on m.parent = c.parent and m.child_name = c.p_child),
          't346.a:true:true,t346.b:true:true,t346.w:true:true',
          'each monolith was handed to the strategy whole, from its own lo, not from its legacy chunk''s hi');
select is((select string_agg(parent_table::text || ':' || rows, ',' order by parent_table::text) from pgpm.log
            where action = 'archive_coverage_reset' and method like '%names no instant by itself%'),
          't346.a:1,t346.b:1,t346.w:1', 'and each legacy chunk was discarded, logged archive_coverage_reset');
select is((select string_agg(distinct x.parent::text || ':' || x.body, ',') from t346.archived x
            where x.parent::text in ('t346.a', 't346.b', 't346.w') and x.body = 'late'),
          't346.a:late,t346.b:late,t346.w:late', 'late, which the legacy chunks left, is archived for every parent');
select ok(pgpm._archive_fully_covered('t346.a', :'a_mono') and pgpm._archive_fully_covered('t346.b', :'b_mono')
          and pgpm._archive_fully_covered('t346.w', :'w_mono'),
          'LIVENESS: from America/New_York every monolith is covered now');
select sum(pgpm.retain(p)) from unnest(array['t346.a', 't346.b', 't346.w']::regclass[]) p;
select is((select string_agg(m.parent::text, ',' order by m.parent::text) from t346.mono m
            where exists (select 1 from pgpm.log l where l.parent_table = m.parent and l.action = 'retain_drop' and l.hi = m.hi)),
          't346.a,t346.b,t346.w', 'retain() then drops all three monoliths, every row archived');

-- ==================== (E) the archive step's orphan discard, from Pacific/Kiritimati ====================
set timezone = 'Pacific/Kiritimati';
select ok((select hi::timestamptz from pgpm.archive_ledger where parent_table = 't346.d'::regclass and child_name = 'd_orph')
            < :'d_lo'::timestamptz,
          'LIVENESS: read in Pacific/Kiritimati, d_orph''s legacy hi ends before the monolith');
select is(pgpm._archive_step('t346.d'), 0, 'LIVENESS: the archive step ran, with no partition to hand the strategy');
select is((select string_agg(child_name, ',') from pgpm.archive_ledger where parent_table = 't346.d'::regclass),
          'd_far', 'from Pacific/Kiritimati the step discards d_orph, which it cannot place, and keeps d_far');
select ok(exists (select 1 from pgpm.log where parent_table = 't346.d'::regclass and action = 'archive_coverage_reset'
                   and method like '%for t346.d_orph,%'),
          'the discard is logged archive_coverage_reset, naming d_orph');

-- ==================== (G) the whole-partition script, from UTC ====================
set timezone = 'UTC';
select ok((select hi::timestamptz from pgpm.archive_ledger where parent_table = 't346.f'::regclass) > :'f_hi'::timestamptz,
          'LIVENESS: read in UTC, f''s legacy hi (written from Asia/Tokyo) lies past the monolith''s hi');
select ok(pgpm_archive_next_partition_whole('t346.f') like :'f_mono' || '%',
          'LIVENESS: the script archived f''s monolith');
select is((select p_lo::timestamptz from t346.calls where parent = 't346.f'::regclass),
          :'f_lo'::timestamptz, 'the script handed the strategy f''s monolith from its own lo');
select ok(exists (select 1 from pgpm.log where parent_table = 't346.f'::regclass and action = 'archive_coverage_reset'
                   and method like '%names no instant by itself%'),
          'and discarded the legacy chunk first, logged archive_coverage_reset');
select is((select array_agg(distinct body order by body) from t346.archived where parent = 't346.f'::regclass),
          array['early1', 'early2', 'late'], 'every row of f is archived');
select pgpm.retain('t346.f');
select ok(exists (select 1 from pgpm.log where parent_table = 't346.f'::regclass and action = 'retain_drop' and hi = :'f_hi'),
          'LIVENESS: retain() then drops f''s monolith');
select ok(pgpm._native_named('time', pgpm._ts_text(now())) and pgpm._native_named('time', pgpm._ts_text('0044-03-15 00:00:00+00 BC'))
          and pgpm._native_named('time', 'infinity') and pgpm._native_named('id', '15000')
          and not pgpm._native_named('time', '2026-10-15 06:00:00') and not pgpm._native_named('time', '10/15/2026 06:00:00 UTC'),
          'GUARD: every bound pgpm writes names its instant, BC and infinity included, and the legacy shapes do not');

select * from finish();
