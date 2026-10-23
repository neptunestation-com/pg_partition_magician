-- A retired chunk whose bound names no instant by itself holds every partition its text could reach, from every
-- session (#1336, the sibling of bullet 8 PR #1351 left).
--
-- THE DEFECT. pgpm._over_retired_chunks finds the attached partitions over a retired chunk's range (#1141): the
-- archive step skips them, retain() leaves them out of its batch and scripts/archive_partition_whole.sql leaves
-- them alone, because a partition re-created over the range would archive its first chunk to the retired chunk's
-- key, over the only copy of the dropped rows. A retired row an older install wrote can carry a bound with no
-- offset: before #977 a strategy's covered_hi was stored as written, after a check in whatever session ran the
-- archive step, and nothing recorded that session's zone. #1264 read such a bound on the grid's clock. A hi a
-- session WEST of the grid wrote then reads hours early, below its own lo, and the partition over the chunk is
-- not held: the archive step hands it to the strategy, which PUTs over the retired chunk's object before the
-- ledger's (parent_table, lo) refuses the row, every tick.
--
-- THE CONTRACT. Such a bound is read at its widest: a lo at the earliest instant its text can name, a hi at the
-- latest, as wall time under either day-month order, at any offset a session can take, to 168 hours west of UTC
-- and 169 east (#1363; tests/354 holds the extremes). Never narrower, and the same from every session. A partition
-- only the widening holds is held until the operator writes the bound with its offset, the remedy the skip row
-- names (part E types it).
--
-- THE FIXTURE. A UTC grid with hand-made hour partitions in December 2025 and pgpm's own from 6 January 03:00Z:
--   gone_hi  [8 Dec 12:00Z, '2025-12-08 08:00:00')  hi is New York's wall time for 13:00Z; at its widest (168 hours
--                                   west) it ends at 15 Dec 08:00Z, so it holds t_redo [8 Dec 12, 13) and
--                                   h07 [15 Dec 07, 08), not h08 [15 Dec 08, 09)
--   gone_lo  ['2025-12-22 10:30:00', 22 Dec 02:00Z)  lo is Tokyo's wall time for 01:30Z; at its widest (169 hours
--                                   east) it starts at 15 Dec 09:30Z, so it holds h09 [15 Dec 09, 10), not h08
-- Expected: t_redo and h07 over gone_hi, h09 over gone_lo; h08 and pgpm's partitions held by nothing. Part G
-- holds that a bound the session cannot parse, or nothing parses, never raises out of the call.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(34);

create schema t347;
create table t347.t (id bigint generated always as identity, ts timestamptz not null, payload text not null,
                     primary key (id, ts));
insert into t347.t (ts, payload)
  select timestamptz '2026-01-06 03:00:00+00' + g * interval '10 minutes', 'live' || g from generate_series(0, 11) g;
-- the object store: one body per key, a PUT replaces it; a PUT over an object that exists is counted on a sequence,
-- which a rollback does not undo, as an object store's PUT is not undone
create table t347.objects (key text primary key, body text);
create sequence t347.overwrites;
create function t347.strat(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v_body text; v_n bigint; v_key text := p_parent::text || '/' || p_lo; v_r pgpm.archive_result;
begin
  execute format('select string_agg(payload, '','' order by payload), count(*) from %s where ts >= %L and ts < %L',
                 p_parent, p_lo, p_hi) into v_body, v_n;
  if exists (select 1 from t347.objects where key = v_key) then perform nextval('t347.overwrites'); end if;
  insert into t347.objects values (v_key, coalesce(v_body, '')) on conflict (key) do update set body = excluded.body;
  v_r.covered_hi := p_hi; v_r.rows_archived := v_n; v_r.s3_key := v_key;
  return v_r;
end $$;
call pgpm.transmute('t347.t', 'ts', interval '1 hour', p_obtain => 1, p_paused => true);
select pgpm.set_archive_fn('t347.t', 't347.strat(regclass,name,text,text)'::regprocedure);
select pgpm.set_retain('t347.t', '1 day');
update pgpm.config set archive_batch = null, retain_batch = null where parent_table = 't347.t'::regclass;

-- the dropped hours' records, and their objects, the only copy of their rows
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, rows_archived, retired_at, child_oid) values
  ('t347.t', '2025-12-08 12:00:00+00', '2025-12-08 08:00:00', 'gone_hi', 't347.t/2025-12-08 12:00:00+00', 2, now(), 4290000301),
  ('t347.t', '2025-12-22 10:30:00', '2025-12-22 02:00:00+00', 'gone_lo', 't347.t/2025-12-22 10:30:00', 1, now(), 4290000302);
insert into t347.objects values ('t347.t/2025-12-08 12:00:00+00', 'old1,old2'), ('t347.t/2025-12-22 10:30:00', 'old3');
-- the operator's hours, by plain DDL, adopted
create table t347.t_redo partition of t347.t for values from ('2025-12-08 12:00:00+00') to ('2025-12-08 13:00:00+00');
create table t347.h07 partition of t347.t for values from ('2025-12-15 07:00:00+00') to ('2025-12-15 08:00:00+00');
create table t347.h08 partition of t347.t for values from ('2025-12-15 08:00:00+00') to ('2025-12-15 09:00:00+00');
create table t347.h09 partition of t347.t for values from ('2025-12-15 09:00:00+00') to ('2025-12-15 10:00:00+00');
insert into t347.t (ts, payload) values
  ('2025-12-08 12:10:00+00', 'late1'), ('2025-12-08 12:20:00+00', 'late2'), ('2025-12-08 12:30:00+00', 'late3'),
  ('2025-12-15 07:10:00+00', 'h07a'), ('2025-12-15 08:10:00+00', 'h08a'), ('2025-12-15 08:20:00+00', 'h08b'),
  ('2025-12-15 09:10:00+00', 'h09a');
select pgpm.adopt_partition('t347.t', p) from unnest(array['t347.t_redo', 't347.h07', 't347.h08', 't347.h09']::regclass[]) p;

-- what the call holds, one line per partition: its chunks, then the lo of each chunk held at its widest
create function t347.held() returns text language sql as $$
  select coalesce(string_agg(format('%s: %s | %s', o.child_name, o.chunks, coalesce(to_jsonb(o) ->> 'unnamed', 'none')), E'\n' order by o.child_name), '')
    from pgpm._over_retired_chunks('t347.t') o;
$$;
\set gone_hi '[2025-12-08 12:00:00+00, 2025-12-08 08:00:00) recorded for gone_hi, whose relation no longer exists, at t347.t/2025-12-08 12:00:00+00 | ''2025-12-08 12:00:00+00'''
\set gone_lo '[2025-12-22 10:30:00, 2025-12-22 02:00:00+00) recorded for gone_lo, whose relation no longer exists, at t347.t/2025-12-22 10:30:00 | ''2025-12-22 10:30:00'''
select format('h07: %s', :'gone_hi') || E'\n' || format('h09: %s', :'gone_lo') || E'\n' || format('t_redo: %s', :'gone_hi')
  as expected \gset

select is((select string_agg(format('%s [%s, %s)', child_name, lo, hi), '; ' order by lo::timestamptz)
             from pgpm.part where parent_table = 't347.t'::regclass and attached and lo::timestamptz < '2026-01-06'),
          't_redo [2025-12-08 12:00:00+00, 2025-12-08 13:00:00+00); h07 [2025-12-15 07:00:00+00, 2025-12-15 08:00:00+00); '
            || 'h08 [2025-12-15 08:00:00+00, 2025-12-15 09:00:00+00); h09 [2025-12-15 09:00:00+00, 2025-12-15 10:00:00+00)',
          'GUARD: four adopted hours on 8 and 15 December, and pgpm''s own partitions from 6 January');
select is((select partition_tz from pgpm.config where parent_table = 't347.t'::regclass), 'UTC',
          'GUARD: the grid is registered in UTC');

-- A. The same partitions over the same chunks from every session, each of which reads the bounds another way.
select ok('2025-12-08 08:00:00'::timestamptz < '2025-12-08 12:00:00+00'::timestamptz
          and '2025-12-22 10:30:00'::timestamptz > '2025-12-22 02:00:00+00'::timestamptz,
          'LIVENESS: read in UTC, the grid''s own zone, gone_hi ends below its lo and gone_lo starts past its hi');
select is(t347.held(), :'expected', 'from UTC: t_redo and h07 over gone_hi, h09 over gone_lo, h08 over nothing');
set timezone = 'America/New_York';
select ok('2025-12-08 08:00:00'::timestamptz = '2025-12-08 13:00:00+00'::timestamptz,
          'LIVENESS: read in New York, gone_hi ends at 13:00Z, before h07');
select is(t347.held(), :'expected', 'from America/New_York the call holds the same partitions over the same chunks');
set timezone = 'Asia/Tokyo';
select ok('2025-12-22 10:30:00'::timestamptz = '2025-12-22 01:30:00+00'::timestamptz,
          'LIVENESS: read in Tokyo, gone_lo starts at 01:30Z, past h09');
select is(t347.held(), :'expected', 'from Asia/Tokyo the call holds the same partitions over the same chunks');
set timezone = 'Pacific/Kiritimati';
set datestyle = 'SQL, DMY';
select ok('2025-12-08 08:00:00'::timestamptz < '2025-12-08 12:00:00+00'::timestamptz,
          'LIVENESS: read in Pacific/Kiritimati, gone_hi ends below its lo');
select is(t347.held(), :'expected',
          'from Pacific/Kiritimati under SQL, DMY the call holds the same partitions over the same chunks');
select is(current_setting('TimeZone') || ' / ' || current_setting('DateStyle'), 'Pacific/Kiritimati / SQL, DMY',
          'the call leaves the caller''s TimeZone and DateStyle as they were');
reset datestyle;
set timezone = 'UTC';

-- B. The archive step: the held hours are skipped, h08 is archived, and no PUT lands over a retired chunk's object.
select pgpm._enforce_write_blocks('t347.t');
select ok((select bool_and(pgpm._is_write_blocked('t347.t', c)) from unnest(array['t_redo', 'h07', 'h08', 'h09']::name[]) c),
          'LIVENESS: the four hours are past retention and write-blocked, every one an archive candidate');
select pgpm._archive_step('t347.t');
select is((select is_called from t347.overwrites), false,
          'B: the strategy never PUT over an object it had written, so the retired chunks'' objects are untouched');
select is((select string_agg(format('%s=%s', key, body), '; ' order by key) from t347.objects),
          't347.t/2025-12-08 12:00:00+00=old1,old2; t347.t/2025-12-15 08:00:00+00=h08a,h08b; t347.t/2025-12-22 10:30:00=old3',
          'B: the step archived h08 alone, and both retired objects still hold the dropped rows');
select is((select string_agg(lo, ', ' order by lo) from pgpm.log
            where parent_table = 't347.t'::regclass and action = 'skip_archive_retired_range'),
          '2025-12-08 12:00:00+00, 2025-12-15 07:00:00+00, 2025-12-15 09:00:00+00',
          'B: the skip is logged for t_redo, h07 and h09, and not for h08');
select ok((select method from pgpm.log where parent_table = 't347.t'::regclass and action = 'skip_archive_retired_range'
             and lo = '2025-12-15 07:00:00+00')
          like '%The chunk(s) at lo ''2025-12-08 12:00:00+00'' carry a bound that names no instant by itself%'
               || 'update pgpm.archive\_ledger set hi = ''<instant>+00'' where parent\_table = ''t347.t''::regclass and lo = <that lo>%',
          'B: h07''s skip row names the chunk held at its widest and the remedy');

-- D. The operator script leaves the held hours alone too (scripts/archive_partition_whole.sql, through the same call).
\i /repo/scripts/archive_partition_whole.sql
create function pg_temp.whole(p_parent regclass) returns text language plpgsql as $$
begin
  return pgpm_archive_next_partition_whole(p_parent);
exception when others then
  return 'raised: ' || sqlerrm;
end $$;
select is(pg_temp.whole('t347.t'), 'nothing eligible left to archive for t347.t',
          'D: the operator script finds nothing to archive: the three held hours are not eligible');

-- C. retain() leaves the held hours out of its batch and drops the covered one.
select is(pgpm.retain('t347.t'), 1, 'LIVENESS: C: retain() dropped one partition');
select is((select string_agg(child_name::text, ', ' order by lo::timestamptz) from pgpm.part
            where parent_table = 't347.t'::regclass and attached and lo::timestamptz < '2026-01-06'),
          't_redo, h07, h09', 'C: retain() dropped h08, and kept t_redo, h07 and h09');
select is((select string_agg(payload, ',' order by payload) from t347.t where ts < '2026-01-06'),
          'h07a,h09a,late1,late2,late3', 'C: the held hours keep their rows');

-- E. The remedy, typed: the operator writes each bound with the offset of the instant it names (New York's 08:00 is
-- 13:00Z, Tokyo's 10:30 is 01:30Z). gone_hi still holds t_redo, the partition really over it; h07 and h09 are let go.
update pgpm.archive_ledger set hi = '2025-12-08 13:00:00+00'
 where parent_table = 't347.t'::regclass and lo = '2025-12-08 12:00:00+00';
update pgpm.archive_ledger set lo = '2025-12-22 01:30:00+00'
 where parent_table = 't347.t'::regclass and lo = '2025-12-22 10:30:00';
select is(t347.held(),
          't_redo: [2025-12-08 12:00:00+00, 2025-12-08 13:00:00+00) recorded for gone_hi, whose relation no longer exists, at t347.t/2025-12-08 12:00:00+00 | none',
          'E: with both bounds written with their offsets, only t_redo is held, and over a chunk read as recorded');
select pgpm._archive_step('t347.t');
select is((select string_agg(format('%s=%s', key, body), '; ' order by key) from t347.objects),
          't347.t/2025-12-08 12:00:00+00=old1,old2; t347.t/2025-12-15 07:00:00+00=h07a; t347.t/2025-12-15 08:00:00+00=h08a,h08b; '
            || 't347.t/2025-12-15 09:00:00+00=h09a; t347.t/2025-12-22 10:30:00=old3',
          'E: the next step archives h07 and h09, and still not t_redo');
select is((select is_called from t347.overwrites), false, 'E: and no PUT landed over an object already written');
select is(pgpm.retain('t347.t'), 2, 'LIVENESS: E: retain() dropped two partitions');
select is((select string_agg(child_name::text, ', ' order by lo::timestamptz) from pgpm.part
            where parent_table = 't347.t'::regclass and attached and lo::timestamptz < '2026-01-06'),
          't_redo', 'E: retain() dropped h07 and h09 and kept t_redo, still over the retired chunk');

-- F. The widening was bounded throughout: h08, which neither chunk could reach in any zone, and pgpm's own
-- partitions from 6 January were never skipped as held, and the remedy logged no new skip.
select is((select string_agg(lo, ', ' order by lo) from pgpm.log
            where parent_table = 't347.t'::regclass and action = 'skip_archive_retired_range'),
          '2025-12-08 12:00:00+00, 2025-12-15 07:00:00+00, 2025-12-15 09:00:00+00',
          'F: the skip rows are still exactly the three of part B');

-- G. A bound the session cannot parse never raises out of the call (#1351's P1-02). A second UTC grid, with three
-- hand-made hours in September and October 2025, over two retired chunks:
--   gone_dmy    ['15/09/2025 00:00:00 UTC', '16/09/2025 00:00:00 UTC')  a pre-#500 render under SQL, DMY, which the
--               ISO, MDY parse refuses (month 15); read as DMY it is 15 September, so at its widest it ends on
--               23 September and holds u_sep15 and not u_oct18
--   gone_epoch  ['2025-10-20 00:00:00+00', '1767574800')  a hi in another encoding (epoch seconds), which no DateStyle
--               parses: it could end anywhere, so it holds every partition from 20 October on, pgpm's own included
create table t347.u (id bigint generated always as identity, ts timestamptz not null, payload text not null,
                     primary key (id, ts));
insert into t347.u (ts, payload)
  select timestamptz '2026-01-06 03:00:00+00' + g * interval '10 minutes', 'live' || g from generate_series(0, 5) g;
call pgpm.transmute('t347.u', 'ts', interval '1 hour', p_obtain => 1, p_paused => true);
select pgpm.set_archive_fn('t347.u', 't347.strat(regclass,name,text,text)'::regprocedure);
select pgpm.set_retain('t347.u', '1 day');
update pgpm.config set archive_batch = null, retain_batch = null where parent_table = 't347.u'::regclass;
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, rows_archived, retired_at, child_oid) values
  ('t347.u', '15/09/2025 00:00:00 UTC', '16/09/2025 00:00:00 UTC', 'gone_dmy', 't347.u/15/09/2025 00:00:00 UTC', 1, now(), 4290000303),
  ('t347.u', '2025-10-20 00:00:00+00', '1767574800', 'gone_epoch', 't347.u/2025-10-20 00:00:00+00', 1, now(), 4290000304);
create table t347.u_sep15 partition of t347.u for values from ('2025-09-15 12:00:00+00') to ('2025-09-15 13:00:00+00');
create table t347.u_oct18 partition of t347.u for values from ('2025-10-18 00:00:00+00') to ('2025-10-18 01:00:00+00');
create table t347.u_oct21 partition of t347.u for values from ('2025-10-21 00:00:00+00') to ('2025-10-21 01:00:00+00');
insert into t347.u (ts, payload) values ('2025-09-15 12:10:00+00', 'u15a'), ('2025-10-18 00:10:00+00', 'u18a'),
                                        ('2025-10-18 00:20:00+00', 'u18b'), ('2025-10-21 00:10:00+00', 'u21a');
select pgpm.adopt_partition('t347.u', p) from unnest(array['t347.u_sep15', 't347.u_oct18', 't347.u_oct21']::regclass[]) p;
create function t347.parses(p_text text, p_style text) returns boolean language plpgsql set datestyle = 'ISO, MDY' as $$
begin
  perform set_config('DateStyle', p_style, true);
  perform p_text::timestamptz;
  return true;
exception when data_exception then
  return false;
end $$;
-- a call that raises is an answer too, and a wrong one
create function t347.held_u() returns text language plpgsql as $$
begin
  return (select coalesce(string_agg(o.child_name::text, ', ' order by o.child_name), '')
            from pgpm._over_retired_chunks('t347.u') o);
exception when others then
  return 'raised: ' || sqlerrm;
end $$;
create function t347.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ran';
exception when others then
  return 'raised: ' || sqlerrm;
end $$;
select ok(not t347.parses('15/09/2025 00:00:00 UTC', 'ISO, MDY') and t347.parses('15/09/2025 00:00:00 UTC', 'ISO, DMY')
          and not t347.parses('1767574800', 'ISO, MDY') and not t347.parses('1767574800', 'ISO, DMY'),
          'LIVENESS: G: gone_dmy''s bounds parse only as DMY, and gone_epoch''s hi under neither order');
select ok((select count(*) from pgpm.part where parent_table = 't347.u'::regclass and attached
            and child_name not in ('u_sep15', 'u_oct18', 'u_oct21')) >= 2,
          'LIVENESS: G: the grid has partitions of pgpm''s own besides the three hand-made hours');
with mine as materialized (select child_name, lo from pgpm.part where parent_table = 't347.u'::regclass and attached)
select string_agg(child_name::text, ', ' order by child_name) as held_u_expected from mine
 where child_name = 'u_sep15' or (child_name <> 'u_oct18' and lo::timestamptz >= '2025-10-20') \gset
select is(t347.held_u(), :'held_u_expected',
          'G: the call holds u_sep15 over gone_dmy and every partition from 20 October on over gone_epoch, not u_oct18');
select pgpm._enforce_write_blocks('t347.u');
select is(t347.try($$select pgpm._archive_step('t347.u')$$), 'ran', 'G: the archive step does not raise');
select is((select string_agg(format('%s=%s', key, body), '; ' order by key) from t347.objects where key like 't347.u/%'),
          't347.u/2025-10-18 00:00:00+00=u18a,u18b', 'G: and it archived u_oct18 alone');
select is(t347.try($$select pgpm.retain('t347.u')$$), 'ran', 'G: retain() does not raise');
select is((select string_agg(child_name::text, ', ' order by child_name) from pgpm.part
            where parent_table = 't347.u'::regclass and attached and child_name in ('u_sep15', 'u_oct18', 'u_oct21')),
          'u_oct21, u_sep15', 'G: retain() dropped u_oct18 and kept the two held hours');
select ok((select method from pgpm.log where parent_table = 't347.u'::regclass and action = 'skip_archive_retired_range'
             and lo = '2025-10-21 00:00:00+00')
          like '%The chunk(s) at lo ''2025-10-20 00:00:00+00'' carry a bound that names no instant by itself%',
          'G: u_oct21''s skip row names gone_epoch as held at its widest, with the remedy');

select * from finish();
