-- A retired chunk's bound reaches every offset a PostgreSQL session can take, so the partition re-created over it is
-- held whatever zone wrote the bound; and what a session that far out renders, pgpm reads back (#1363).
--
-- THE DEFECT. pgpm._over_retired_chunks holds the attached partitions over a retired chunk's range (#1141): the
-- archive step skips them, because a partition over the range would archive its first chunk to the retired
-- chunk's key, over the only copy of the dropped rows. A retired row an older install wrote can carry a bound with
-- no offset (before #977 a strategy's covered_hi was stored as written, in a session whose zone nothing
-- recorded), and pgpm._native_bound_reach reads such a bound at its widest (#1336). It widened only to the zones
-- tzdata names today, a hi by 12 hours and a lo by 14. A session goes further: PostgreSQL's POSIX TimeZone parser
-- takes an offset to 167:59:60 either side ('XYZ167:59:60' is UTC-168), a DST name with no offset of its own is an
-- hour east of standard ('XYZ-167:59:60DEF' is UTC+169 in summer), an interval or a number of hours reaches just
-- under 168, and tzdata's LMT reaches -15:56:08 (Asia/Manila before 1845) and +15:13:42 (America/Metlakatla before
-- 1867). A hi such a session wrote west of UTC-12 read as ending below its own lo, a lo written east of UTC+14 as
-- starting past its own hi, the partition over the chunk was not held, and the archive step PUT it over the
-- retired object. And such a session renders an instant with an offset timestamptz input refuses past 15:59:59
-- ('2025-12-19 10:00:00-20'): pgpm._ts_text wrote it into the ledger from an archive step run there, and
-- pgpm._native_named took it for a castable bound, so later archive steps of the parent raised.
--
-- THE CONTRACT. A bound with no offset reaches 168 hours west of its wall time for a hi and 169 east for a lo:
-- every offset a session can take, and no further (parts A to D; the GUARD lines pin the limit on the server
-- running the file). pgpm renders an instant whose offset in the caller's zone is 16 hours or more in UTC (part E),
-- and a bound carrying such an offset is read as the instant it names, never cast (part F).
--
-- THE FIXTURE (parts A to D). A UTC grid, pgpm's own partitions from 6 January 2026, and six retired one-hour
-- chunks, each with a partition re-created over it by plain DDL and adopted; each chunk's offset-less bound is
-- rendered below by a session at the offset named:
--   w_posix  [3 Nov 2025 00:00Z, hi)   hi written at 'XYZ167:59:60' (UTC-168)            held: p_w_posix
--   e_dst    [lo, 1 Jul 2025 01:00Z)   lo written at 'XYZ-167:59:60DEF' (UTC+169, July)  held: p_e_dst
--   e_posix  [lo, 17 Nov 2025 01:00Z)  lo written at 'XYZ-167:59:60' (UTC+168)           held: p_e_posix
--   e_int    [lo, 1 Dec 2025 01:00Z)   lo written at INTERVAL '167:59:59'                 held: p_e_int
--   w_lmt    [6 Jan 1800 00:00Z, hi)   hi written in Asia/Manila (LMT -15:56:08)          held: p_w_lmt
--   e_lmt    [lo, 20 Jan 1800 01:00Z)  lo written in America/Metlakatla (LMT +15:13:42)   held: p_e_lmt
-- and three partitions over nothing, archived: b_w_posix (the hour after w_posix, exactly where its widest hi
-- ends), b_e_dst (the hour before e_dst, exactly where its widest lo starts) and h_free.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(34);

create schema t354;
-- the offset, in seconds east of UTC, a session in p_zone has at p_at; 'refused' when SET refuses the zone. The SET
-- clause scopes the zone this sets to the call.
create function t354.offset_at(p_zone text, p_at timestamptz) returns text language plpgsql set timezone = 'UTC' as $$
begin
  perform set_config('TimeZone', p_zone, true);
  return extract(timezone from p_at)::bigint::text;
exception when others then
  return 'refused';
end $$;
-- p_at as a session in p_zone renders it, offset-less: the shape of a pre-#977 covered_hi
create function t354.wall(p_zone text, p_at timestamptz) returns text language plpgsql set timezone = 'UTC' as $$
begin
  perform set_config('TimeZone', p_zone, true);
  return to_char(p_at, 'YYYY-MM-DD HH24:MI:SS');
end $$;
-- a call that raises is an answer too
create function t354.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ran';
exception when others then
  return 'raised: ' || sqlerrm;
end $$;

-- PostgreSQL's limit, both signs and every spelling: 168 hours west and 169 east are reachable, nothing past them is
select is(t354.offset_at('XYZ167:59:60', '2025-11-03') || ' / ' || t354.offset_at('XYZ-167:59:60', '2025-11-03'),
          '-604800 / 604800', 'GUARD: a POSIX zone takes a session to 168 hours west or east of UTC');
select is(t354.offset_at('XYZ-167:59:60DEF', '2025-07-01') || ' / ' || t354.offset_at('XYZ-167:59:60DEF', '2025-12-01')
            || ' / ' || t354.offset_at('XYZ167:59:60DEF', '2025-07-01') || ' / ' || t354.offset_at('XYZ0DEF167:59:60', '2025-07-01')
            || ' / ' || t354.offset_at('XYZ0DEF-167:59:60', '2025-07-01'),
          '608400 / 604800 / -601200 / -604800 / 604800',
          'GUARD: a DST name with no offset of its own is an hour east of standard, to 169 hours east; one with its own '
          || 'offset reaches 168 either side');
select is(t354.offset_at('XYZ168', '2025-11-03') || ' / ' || t354.offset_at('XYZ-168', '2025-11-03') || ' / '
            || t354.offset_at('XYZ167:59:61', '2025-11-03') || ' / ' || t354.offset_at('XYZ167:60', '2025-11-03')
            || ' / ' || t354.offset_at('XYZ0DEF-168', '2025-07-01') || ' / ' || t354.offset_at('XYZ0DEF168', '2025-07-01'),
          'refused / refused / refused / refused / refused / refused', 'GUARD: and no POSIX spelling takes it further');
select is(t354.offset_at('INTERVAL ''167:59:59''', '2025-11-03') || ' / ' || t354.offset_at('INTERVAL ''-167:59:59''', '2025-11-03')
            || ' / ' || t354.offset_at('INTERVAL ''168:00:00''', '2025-11-03') || ' / ' || t354.offset_at('-168', '2025-11-03')
            || ' / ' || t354.offset_at('168', '2025-11-03'),
          '604799 / -604799 / refused / refused / refused',
          'GUARD: an interval reaches a second short of 168 hours, and an interval or a number of hours no further');
select is(t354.offset_at('Asia/Manila', '1800-01-06') || ' / ' || t354.offset_at('America/Metlakatla', '1800-01-20'),
          '-57368 / 54822', 'GUARD: tzdata''s LMT puts Manila at -15:56:08 and Metlakatla at +15:13:42, past -12 and +14');

create table t354.t (id bigint generated always as identity, ts timestamptz not null, payload text not null,
                     primary key (id, ts));
insert into t354.t (ts, payload)
  select timestamptz '2026-01-06 03:00:00+00' + g * interval '10 minutes', 'live' || g from generate_series(0, 11) g;
-- the object store: one body per key, a PUT replaces it; a PUT over an object that exists is counted on a sequence,
-- which a rollback does not undo, as an object store's PUT is not undone
create table t354.objects (key text primary key, body text);
create sequence t354.overwrites;
create function t354.strat(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v_body text; v_n bigint; v_key text := p_parent::text || '/' || p_lo; v_r pgpm.archive_result;
begin
  execute format('select string_agg(payload, '','' order by payload), count(*) from %s where ts >= %L and ts < %L',
                 p_parent, p_lo, p_hi) into v_body, v_n;
  if exists (select 1 from t354.objects where key = v_key) then perform nextval('t354.overwrites'); end if;
  insert into t354.objects values (v_key, coalesce(v_body, '')) on conflict (key) do update set body = excluded.body;
  v_r.covered_hi := p_hi; v_r.rows_archived := v_n; v_r.s3_key := v_key;
  return v_r;
end $$;
call pgpm.transmute('t354.t', 'ts', interval '1 hour', p_obtain => 1, p_paused => true);
select pgpm.set_archive_fn('t354.t', 't354.strat(regclass,name,text,text)'::regprocedure);
select pgpm.set_retain('t354.t', '1 day');
update pgpm.config set archive_batch = null, retain_batch = null where parent_table = 't354.t'::regclass;

-- the retired chunks, each offset-less bound as a session at its offset rendered it, and their objects
select t354.wall('XYZ167:59:60', '2025-11-03 01:00:00+00') as w_posix_hi,
       t354.wall('XYZ-167:59:60DEF', '2025-07-01 00:00:00+00') as e_dst_lo,
       t354.wall('XYZ-167:59:60', '2025-11-17 00:00:00+00') as e_posix_lo,
       t354.wall('INTERVAL ''167:59:59''', '2025-12-01 00:00:00+00') as e_int_lo,
       t354.wall('Asia/Manila', '1800-01-06 01:00:00+00') as w_lmt_hi,
       t354.wall('America/Metlakatla', '1800-01-20 00:00:00+00') as e_lmt_lo \gset
select is(format('%s | %s | %s | %s | %s | %s', :'w_posix_hi', :'e_dst_lo', :'e_posix_lo', :'e_int_lo', :'w_lmt_hi', :'e_lmt_lo'),
          '2025-10-27 01:00:00 | 2025-07-08 01:00:00 | 2025-11-24 00:00:00 | 2025-12-07 23:59:59 | 1800-01-05 09:03:52 | '
            || '1800-01-20 15:13:42',
          'GUARD: each bound is its instant as a session at that offset renders it, offset-less');
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, rows_archived, retired_at, child_oid) values
  ('t354.t', '2025-11-03 00:00:00+00', :'w_posix_hi', 'w_posix', 't354.t/2025-11-03 00:00:00+00', 2, now(), 4290035401),
  ('t354.t', :'e_dst_lo', '2025-07-01 01:00:00+00', 'e_dst', 't354.t/2025-07-01 00:00:00+00', 2, now(), 4290035406),
  ('t354.t', :'e_posix_lo', '2025-11-17 01:00:00+00', 'e_posix', 't354.t/2025-11-17 00:00:00+00', 1, now(), 4290035402),
  ('t354.t', :'e_int_lo', '2025-12-01 01:00:00+00', 'e_int', 't354.t/2025-12-01 00:00:00+00', 1, now(), 4290035403),
  ('t354.t', '1800-01-06 00:00:00+00', :'w_lmt_hi', 'w_lmt', 't354.t/1800-01-06 00:00:00+00', 1, now(), 4290035404),
  ('t354.t', :'e_lmt_lo', '1800-01-20 01:00:00+00', 'e_lmt', 't354.t/1800-01-20 00:00:00+00', 2, now(), 4290035405);
insert into t354.objects values
  ('t354.t/2025-11-03 00:00:00+00', 'old_w1,old_w2'), ('t354.t/2025-07-01 00:00:00+00', 'old_d1,old_d2'),
  ('t354.t/2025-11-17 00:00:00+00', 'old_e1'), ('t354.t/2025-12-01 00:00:00+00', 'old_i1'),
  ('t354.t/1800-01-06 00:00:00+00', 'old_m1'), ('t354.t/1800-01-20 00:00:00+00', 'old_k1,old_k2');
-- the operator's hours, by plain DDL, adopted
create table t354.p_w_posix partition of t354.t for values from ('2025-11-03 00:00:00+00') to ('2025-11-03 01:00:00+00');
create table t354.b_w_posix partition of t354.t for values from ('2025-11-03 01:00:00+00') to ('2025-11-03 02:00:00+00');
create table t354.b_e_dst partition of t354.t for values from ('2025-06-30 23:00:00+00') to ('2025-07-01 00:00:00+00');
create table t354.p_e_dst partition of t354.t for values from ('2025-07-01 00:00:00+00') to ('2025-07-01 01:00:00+00');
create table t354.p_e_posix partition of t354.t for values from ('2025-11-17 00:00:00+00') to ('2025-11-17 01:00:00+00');
create table t354.p_e_int partition of t354.t for values from ('2025-12-01 00:00:00+00') to ('2025-12-01 01:00:00+00');
create table t354.h_free partition of t354.t for values from ('2025-12-20 00:00:00+00') to ('2025-12-20 01:00:00+00');
create table t354.p_w_lmt partition of t354.t for values from ('1800-01-06 00:00:00+00') to ('1800-01-06 01:00:00+00');
create table t354.p_e_lmt partition of t354.t for values from ('1800-01-20 00:00:00+00') to ('1800-01-20 01:00:00+00');
insert into t354.t (ts, payload) values
  ('2025-11-03 00:10:00+00', 'pw1'), ('2025-11-03 00:20:00+00', 'pw2'),
  ('2025-11-03 01:10:00+00', 'bw1'), ('2025-11-03 01:20:00+00', 'bw2'),
  ('2025-06-30 23:10:00+00', 'bd1'),
  ('2025-07-01 00:10:00+00', 'pd1'), ('2025-07-01 00:20:00+00', 'pd2'),
  ('2025-11-17 00:10:00+00', 'pe1'),
  ('2025-12-01 00:10:00+00', 'pi1'), ('2025-12-01 00:20:00+00', 'pi2'), ('2025-12-01 00:30:00+00', 'pi3'),
  ('2025-12-20 00:10:00+00', 'hf1'), ('2025-12-20 00:20:00+00', 'hf2'), ('2025-12-20 00:30:00+00', 'hf3'),
  ('1800-01-06 00:10:00+00', 'pm1'),
  ('1800-01-20 00:10:00+00', 'pk1'), ('1800-01-20 00:20:00+00', 'pk2');
select pgpm.adopt_partition('t354.t', p)
  from unnest(array['t354.p_w_posix', 't354.b_w_posix', 't354.b_e_dst', 't354.p_e_dst', 't354.p_e_posix', 't354.p_e_int',
                    't354.h_free', 't354.p_w_lmt', 't354.p_e_lmt']::regclass[]) p;

-- which partitions the call holds, and over which chunks, by name
create function t354.held(p_parent regclass) returns text language sql as $$
  select coalesce(string_agg(format('%s: %s', o.child_name, (select string_agg(l.child_name::text, ',' order by l.child_name)
                                                              from pgpm.archive_ledger l
                                                             where l.parent_table = p_parent
                                                               and position(quote_ident(l.child_name) || ',' in o.chunks) > 0)),
                             '; ' order by o.child_name), '')
    from pgpm._over_retired_chunks(p_parent) o;
$$;
\set expected 'p_e_dst: e_dst; p_e_int: e_int; p_e_lmt: e_lmt; p_e_posix: e_posix; p_w_lmt: w_lmt; p_w_posix: w_posix'

-- A. Each partition re-created over a chunk is held over that chunk, and the hour either side of the widest reach
-- is not.
select ok(:'w_posix_hi'::timestamp + interval '12 hours' < '2025-11-03 00:00:00'
          and :'w_lmt_hi'::timestamp + interval '12 hours' < '1800-01-06 00:00:00'
          and :'e_dst_lo'::timestamp - interval '168 hours' >= '2025-07-01 01:00:00'
          and :'e_posix_lo'::timestamp - interval '14 hours' >= '2025-11-17 01:00:00'
          and :'e_int_lo'::timestamp - interval '14 hours' >= '2025-12-01 01:00:00'
          and :'e_lmt_lo'::timestamp - interval '14 hours' >= '1800-01-20 01:00:00',
          'LIVENESS: placed at UTC-12 or UTC+14 (e_dst at UTC+168), every chunk lies wholly outside the partition '
          || 're-created over it');
select is(t354.held('t354.t'), :'expected',
          'from UTC each re-created partition is held over its own chunk, and b_w_posix, b_e_dst and h_free over none');
set timezone = 'XYZ167:59:60';
set datestyle = 'SQL, DMY';
select is(t354.held('t354.t'), :'expected', 'from a session at UTC-168 under SQL, DMY the call holds the same partitions');
reset datestyle;
set timezone = 'Asia/Manila';
select is(t354.held('t354.t'), :'expected', 'from Asia/Manila the call holds the same partitions');
set timezone = 'UTC';

-- B. The archive step: the held hours are skipped, the free ones archived, and no PUT lands over a retired object.
select pgpm._enforce_write_blocks('t354.t');
select ok((select bool_and(pgpm._is_write_blocked('t354.t', c))
             from unnest(array['p_w_posix', 'b_w_posix', 'b_e_dst', 'p_e_dst', 'p_e_posix', 'p_e_int', 'h_free', 'p_w_lmt',
                               'p_e_lmt']::name[]) c),
          'LIVENESS: the nine hours are past retention and write-blocked, every one an archive candidate');
select pgpm._archive_step('t354.t');
select is((select string_agg(format('%s=%s', key, body), '; ' order by key) from t354.objects
            where key in ('t354.t/2025-11-03 01:00:00+00', 't354.t/2025-06-30 23:00:00+00', 't354.t/2025-12-20 00:00:00+00')),
          't354.t/2025-06-30 23:00:00+00=bd1; t354.t/2025-11-03 01:00:00+00=bw1,bw2; t354.t/2025-12-20 00:00:00+00=hf1,hf2,hf3',
          'LIVENESS: the step ran and archived b_e_dst, b_w_posix and h_free, the hours at and past the widest reach');
select is((select is_called from t354.overwrites), false,
          'B: the strategy never PUT over an object already written');
select is((select string_agg(format('%s=%s', key, body), '; ' order by key) from t354.objects
            where key in ('t354.t/2025-11-03 00:00:00+00', 't354.t/2025-07-01 00:00:00+00', 't354.t/2025-11-17 00:00:00+00',
                          't354.t/2025-12-01 00:00:00+00', 't354.t/1800-01-06 00:00:00+00', 't354.t/1800-01-20 00:00:00+00')),
          't354.t/1800-01-06 00:00:00+00=old_m1; t354.t/1800-01-20 00:00:00+00=old_k1,old_k2; '
            || 't354.t/2025-07-01 00:00:00+00=old_d1,old_d2; t354.t/2025-11-03 00:00:00+00=old_w1,old_w2; '
            || 't354.t/2025-11-17 00:00:00+00=old_e1; t354.t/2025-12-01 00:00:00+00=old_i1',
          'B: every retired chunk''s object still holds the dropped rows');
select is((select string_agg(lo, ', ' order by lo) from pgpm.log
            where parent_table = 't354.t'::regclass and action = 'skip_archive_retired_range'),
          '1800-01-06 00:00:00+00, 1800-01-20 00:00:00+00, 2025-07-01 00:00:00+00, 2025-11-03 00:00:00+00, '
            || '2025-11-17 00:00:00+00, 2025-12-01 00:00:00+00',
          'B: the skip is logged for the six re-created hours, and for no other');
select ok((select method from pgpm.log where parent_table = 't354.t'::regclass and action = 'skip_archive_retired_range'
             and lo = '2025-11-03 00:00:00+00')
          like '%The chunk(s) at lo ''2025-11-03 00:00:00+00'' carry a bound that names no instant by itself%'
               || 'at any offset a session can take (to 168 hours west of UTC and 169 east)%',
          'B: p_w_posix''s skip row names its chunk as held at its widest, and how wide that is');

-- C. retain() drops the archived hours and leaves the held ones, with their rows.
select is(pgpm.retain('t354.t'), 3, 'LIVENESS: C: retain() dropped three partitions');
select is((select string_agg(child_name::text, ', ' order by child_name) from pgpm.part
            where parent_table = 't354.t'::regclass and attached and lo::timestamptz < '2026-01-01'),
          'p_e_dst, p_e_int, p_e_lmt, p_e_posix, p_w_lmt, p_w_posix',
          'C: retain() dropped b_w_posix, b_e_dst and h_free and kept the six held hours');
select is((select string_agg(payload, ',' order by payload) from t354.t where ts < '2026-01-01'),
          'pd1,pd2,pe1,pi1,pi2,pi3,pk1,pk2,pm1,pw1,pw2', 'C: the held hours keep their rows');

-- D. The remedy the skip row names, typed: w_posix's hi written with its offset holds p_w_posix still, over the
-- chunk read as recorded.
update pgpm.archive_ledger set hi = '2025-11-03 01:00:00+00'
 where parent_table = 't354.t'::regclass and lo = '2025-11-03 00:00:00+00';
select is(t354.held('t354.t'), :'expected', 'D: with w_posix''s hi written with its offset, the call holds the same partitions');
select is((select o.unnamed from pgpm._over_retired_chunks('t354.t') o where o.child_name = 'p_w_posix'), null,
          'D: and p_w_posix is held over a chunk whose bounds both name their instant');

-- E. What pgpm writes from a session that far out reads back in every session. pgpm._ts_text renders in the caller's
-- zone; at 'XYZ20' (UTC-20) that offset is one timestamptz input refuses ('-20'). A second grid, archived by the
-- no-op strategy one chunk per step: u0 from a session at UTC-20, then u3 from UTC.
create table t354.u (id bigint generated always as identity, ts timestamptz not null, payload text not null,
                     primary key (id, ts));
insert into t354.u (ts, payload)
  select timestamptz '2026-01-06 03:00:00+00' + g * interval '10 minutes', 'live' || g from generate_series(0, 5) g;
call pgpm.transmute('t354.u', 'ts', interval '1 hour', p_obtain => 1, p_paused => true);
select pgpm.set_archive_fn('t354.u', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
select pgpm.set_retain('t354.u', '1 day');
update pgpm.config set archive_batch = 1, retain_batch = null where parent_table = 't354.u'::regclass;
create table t354.u0 partition of t354.u for values from ('2025-12-26 00:00:00+00') to ('2025-12-26 01:00:00+00');
create table t354.u3 partition of t354.u for values from ('2025-12-26 03:00:00+00') to ('2025-12-26 04:00:00+00');
insert into t354.u (ts, payload) values ('2025-12-26 00:10:00+00', 'u0a'), ('2025-12-26 03:10:00+00', 'u3a'),
                                        ('2025-12-26 03:20:00+00', 'u3b');
select pgpm.adopt_partition('t354.u', p) from unnest(array['t354.u0', 't354.u3']::regclass[]) p;
select pgpm._enforce_write_blocks('t354.u');
set timezone = 'XYZ20';
select is(t354.try($$select ('2025-12-26 01:00:00+00'::timestamptz)::text::timestamptz$$),
          'raised: time zone displacement out of range: "2025-12-25 05:00:00-20"',
          'LIVENESS: E: at UTC-20 a timestamptz renders with an offset its own input refuses');
select is(pgpm._ts_text('2025-12-26 01:00:00+00') || ' / ' || pgpm._ts_text('1800-01-06 00:00:00+00') || ' / '
            || pgpm._ts_text('infinity'),
          '2025-12-26 01:00:00+00 / 1800-01-06 00:00:00+00 / infinity',
          'E: pgpm._ts_text renders such an instant in UTC');
set timezone = 'Asia/Manila';
select is(pgpm._ts_text('1800-01-06 00:00:00+00'), '1800-01-05 08:03:52-15:56:08',
          'E: and an offset input reads, Manila''s LMT, in the caller''s zone as before');
set timezone = 'XYZ20';
select is(pgpm._archive_step('t354.u'), 1, 'LIVENESS: E: the archive step at UTC-20 recorded one chunk');
set timezone = 'UTC';
select is((select format('%s [%s, %s)', child_name, lo, hi) from pgpm.archive_ledger where parent_table = 't354.u'::regclass),
          'u0 [2025-12-26 00:00:00+00, 2025-12-26 01:00:00+00)',
          'E: the chunk it recorded is u0''s, its bounds text every session reads');
select is(t354.try($$select pgpm._archive_step('t354.u')$$), 'ran', 'E: the next archive step, from UTC, runs');
select is(pgpm.retain('t354.u'), 2, 'LIVENESS: E: retain() dropped two partitions');
select is((select coalesce(string_agg(child_name::text, ', ' order by child_name), '') from pgpm.part
            where parent_table = 't354.u'::regclass and child_name in ('u0', 'u3')),
          '', 'E: retain() dropped u0 and u3, each archived from a different session');

-- F. A ledger bound carrying such an offset (an older install stored a strategy's covered_hi as a session at UTC-20
-- rendered it) is the instant it names: never cast, so the step runs, and never widened, so it holds only what its
-- range overlaps. A third grid: gone_x [20 Dec 05:00Z, 06:00Z) of a partition dropped by hand, its hi '-20'.
create table t354.w (id bigint generated always as identity, ts timestamptz not null, payload text not null,
                     primary key (id, ts));
insert into t354.w (ts, payload)
  select timestamptz '2026-01-06 03:00:00+00' + g * interval '10 minutes', 'live' || g from generate_series(0, 5) g;
call pgpm.transmute('t354.w', 'ts', interval '1 hour', p_obtain => 1, p_paused => true);
select pgpm.set_archive_fn('t354.w', 't354.strat(regclass,name,text,text)'::regprocedure);
select pgpm.set_retain('t354.w', '1 day');
update pgpm.config set archive_batch = null, retain_batch = null where parent_table = 't354.w'::regclass;
set timezone = 'XYZ20';
select ('2025-12-20 06:00:00+00'::timestamptz)::text as x_hi \gset
set timezone = 'UTC';
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, rows_archived, retired_at, child_oid) values
  ('t354.w', '2025-12-20 05:00:00+00', :'x_hi', 'gone_x', 't354.w/2025-12-20 05:00:00+00', 1, null, 4290035407);
insert into t354.objects values ('t354.w/2025-12-20 05:00:00+00', 'old_x1');
create table t354.w_over partition of t354.w for values from ('2025-12-20 05:00:00+00') to ('2025-12-20 06:00:00+00');
create table t354.w_after partition of t354.w for values from ('2025-12-20 06:00:00+00') to ('2025-12-20 07:00:00+00');
insert into t354.w (ts, payload) values ('2025-12-20 05:10:00+00', 'wo1'), ('2025-12-20 06:10:00+00', 'wa1'),
                                        ('2025-12-20 06:20:00+00', 'wa2');
select pgpm.adopt_partition('t354.w', p) from unnest(array['t354.w_over', 't354.w_after']::regclass[]) p;
select pgpm._enforce_write_blocks('t354.w');
select is(:'x_hi' || ' / ' || (select count(*) from pg_class where oid = 4290035407),
          '2025-12-19 10:00:00-20 / 0', 'GUARD: F: gone_x''s hi is a UTC-20 render, and its relation is gone');
select is(t354.try($$select pgpm._archive_step('t354.w')$$), 'ran', 'F: the archive step runs over gone_x''s hi');
select ok((select retired_at is not null from pgpm.archive_ledger where parent_table = 't354.w'::regclass and child_name = 'gone_x'),
          'F: and marks gone_x retired, its relation gone');
select is(t354.held('t354.w') || ' | ' || (select string_agg(format('%s=%s', key, body), '; ' order by key) from t354.objects
                                            where key like 't354.w/%'),
          'w_over: gone_x | t354.w/2025-12-20 05:00:00+00=old_x1; t354.w/2025-12-20 06:00:00+00=wa1,wa2',
          'F: w_over, the hour gone_x covers, is held and its object untouched; w_after, the hour after its hi, archived');

select is(current_setting('TimeZone') || ' / ' || current_setting('DateStyle'), 'UTC / ISO, MDY',
          'the calls leave the session''s TimeZone and DateStyle as they were');
select * from finish();
