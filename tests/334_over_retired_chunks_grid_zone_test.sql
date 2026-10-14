-- pgpm._over_retired_chunks reads a bound that names no zone as the grid's wall clock, not the caller's
-- (issue #1264).
--
-- THE DEFECT. _over_retired_chunks finds the attached partitions over a retired chunk's range (#1141), which the
-- archive step skips and retain() leaves out of its batch. It compared the bounds with ::timestamptz in the
-- CALLER's session, and a retired ledger row an older install wrote can carry a bound with no offset: before #977
-- a strategy's covered_hi was stored verbatim, and no upgrade rewrites those rows. Such text names a different
-- instant in every zone, so the same call held a partition from pg_cron's UTC session and not from an operator's
-- Asia/Kolkata one (a hand _archive_step or retain()), which then archived it over the retired range. The same
-- held for a bound shaped by a pre-#500 session's DateStyle ('11/03/2026'), read as March under DMY and as
-- November under MDY.
--
-- THE CONTRACT (tests/317 states it; this file holds it for the bounds that name no zone). The call returns the
-- same partitions over the same chunks from every session's TimeZone and DateStyle. A bound with an offset is the
-- instant it names; one with no offset is wall time in the grid's own zone, config.partition_tz (the zone the
-- grid's cells are computed and named in, and the one _col_to_native reads a naive column's wall time in); a
-- DateStyle-shaped one reads as ISO, MDY, the style _ts_text writes every bound in; a zone abbreviation (a
-- pre-#500 render under DateStyle SQL ends in one) reads in the Default set, whatever set the caller runs with.
--
-- THE FIXTURE. The grid is registered in Asia/Tokyo (+09), so its wall clock is not UTC's and a fix that reads
-- offset-less text as UTC fails here too. Five retired chunks, every one of them read differently by some session
-- below, and each check names the partitions and the chunks:
--   gone_a  [p0.lo - 6h, p0.lo - 3h)  hi offset-less: ends below p0 on Tokyo's clock; held by any zone to its west
--   gone_b  [p0.lo - 4h, p0.lo + 3h)  hi offset-less: reaches into p0 on Tokyo's clock; not from Pacific/Kiritimati
--   gone_c  [p1.lo + 2h, p1.lo + 5h)  lo offset-less: inside p1 on Tokyo's clock; reaches into p0 from Kiritimati,
--                                     and is empty (lo past hi) from UTC
--   gone_d  [11/03/2026, 11/04/2026)  both offset-less and DateStyle-shaped: 3 November (inside p1) as MDY,
--                                     11 March (inside p0) as DMY
--   gone_e  [p2.lo + 9h, p2.lo + 15h) both with an offset (+00): the same instant in every session
-- Expected: p0 over gone_b alone, p1 over gone_c and gone_d, p2 over gone_e; gone_a nowhere.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'Asia/Tokyo';
select plan(22);

create schema t334;

create table t334.t (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into t334.t (ts) select timestamptz '2026-01-05 00:00:00+00' + g * interval '1 hour' from generate_series(1, 90) g;
call pgpm.transmute('t334.t', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select pgpm.set_archive_fn('t334.t', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);

-- what the call holds, one line per partition
create function t334.held() returns text language sql as $$
  select coalesce(string_agg(format('%s: %s', o.child_name, o.chunks), E'\n' order by o.child_name), '')
    from pgpm._over_retired_chunks('t334.t') o;
$$;

insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid) values
  ('t334.t', '2025-12-31 18:00:00+09', '2025-12-31 21:00:00',    'gone_a', 'obj/a', now(), 4290000101),
  ('t334.t', '2025-12-31 20:00:00+09', '2026-01-01 03:00:00',    'gone_b', 'obj/b', now(), 4290000102),
  ('t334.t', '2026-11-01 02:00:00',    '2026-11-01 05:00:00+09', 'gone_c', 'obj/c', now(), 4290000103),
  ('t334.t', '11/03/2026 00:00:00',    '11/04/2026 00:00:00',    'gone_d', 'obj/d', now(), 4290000104),
  ('t334.t', '2026-12-01 00:00:00+00', '2026-12-01 06:00:00+00', 'gone_e', 'obj/e', now(), 4290000105);

\set expected 't_p2026_01_to_2026_11: [2025-12-31 20:00:00+09, 2026-01-01 03:00:00) recorded for gone_b, whose relation no longer exists, at obj/b\nt_p2026_11: [2026-11-01 02:00:00, 2026-11-01 05:00:00+09) recorded for gone_c, whose relation no longer exists, at obj/c; [11/03/2026 00:00:00, 11/04/2026 00:00:00) recorded for gone_d, whose relation no longer exists, at obj/d\nt_p2026_12: [2026-12-01 00:00:00+00, 2026-12-01 06:00:00+00) recorded for gone_e, whose relation no longer exists, at obj/e'

-- GUARD: the fixture is the one described above (the grid, and its three partitions' bounds)
select is((select partition_tz from pgpm.config where parent_table = 't334.t'::regclass), 'Asia/Tokyo',
          'GUARD: the grid is registered in Asia/Tokyo, a wall clock nine hours east of UTC');
select is((select string_agg(format('%s [%s, %s)', child_name, lo, hi), '; ' order by lo::timestamptz)
             from pgpm.part where parent_table = 't334.t'::regclass and attached),
          't_p2026_01_to_2026_11 [2026-01-01 00:00:00+09, 2026-11-01 00:00:00+09); '
            || 't_p2026_11 [2026-11-01 00:00:00+09, 2026-12-01 00:00:00+09); '
            || 't_p2026_12 [2026-12-01 00:00:00+09, 2027-01-01 00:00:00+09)',
          'GUARD: three attached partitions, p0 from January, p1 November, p2 December');

-- A. From a session on the grid's own zone and the default DateStyle (what the expectation was derived on).
select is(t334.held(), :'expected',
          'from Asia/Tokyo, ISO: p0 over gone_b, p1 over gone_c and gone_d, p2 over gone_e, gone_a nowhere');

-- B. UTC, pg_cron's usual zone. Read there, gone_a's hi ends six hours INTO p0 and gone_c's lo lies past its hi.
set timezone = 'UTC';
select ok('2025-12-31 21:00:00'::timestamptz > '2026-01-01 00:00:00+09'::timestamptz
          and '2026-11-01 02:00:00'::timestamptz > '2026-11-01 05:00:00+09'::timestamptz,
          'LIVENESS: read in UTC, gone_a reaches into p0 and gone_c is empty');
select is(t334.held(), :'expected', 'from UTC the call holds the same partitions over the same chunks');

-- C. Asia/Kolkata (+05:30) under SQL, DMY: gone_a's hi ends half an hour into p0, and gone_d reads as March.
set timezone = 'Asia/Kolkata';
set datestyle = 'SQL, DMY';
select ok('2025-12-31 21:00:00'::timestamptz > '2026-01-01 00:00:00+09'::timestamptz
          and '11/03/2026 00:00:00'::timestamptz < '2026-11-01 00:00:00+09'::timestamptz,
          'LIVENESS: read in Asia/Kolkata under DMY, gone_a reaches into p0 and gone_d lies in March, inside p0');
select is(t334.held(), :'expected',
          'from Asia/Kolkata under SQL, DMY the call holds the same partitions over the same chunks');
reset datestyle;

-- D. Pacific/Kiritimati (+14): gone_b's hi ends two hours before p0, and gone_c's lo three hours before p1.
set timezone = 'Pacific/Kiritimati';
select ok('2026-01-01 03:00:00'::timestamptz < '2026-01-01 00:00:00+09'::timestamptz
          and '2026-11-01 02:00:00'::timestamptz < '2026-11-01 00:00:00+09'::timestamptz,
          'LIVENESS: read in Pacific/Kiritimati, gone_b ends before p0 and gone_c starts inside p0');
select is(t334.held(), :'expected',
          'from Pacific/Kiritimati the call holds the same partitions over the same chunks');

-- E. America/Los_Angeles under German (DMY): every offset-less bound lands a day or more later.
set timezone = 'America/Los_Angeles';
set datestyle = 'German';
select ok('2025-12-31 21:00:00'::timestamptz > '2026-01-01 00:00:00+09'::timestamptz
          and '11/03/2026 00:00:00'::timestamptz < '2026-11-01 00:00:00+09'::timestamptz,
          'LIVENESS: read in America/Los_Angeles under German, gone_a reaches into p0 and gone_d lies in March');
select is(t334.held(), :'expected',
          'from America/Los_Angeles under German the call holds the same partitions over the same chunks');
reset datestyle;

-- F. The call leaves the caller's settings as it found them.
select is(current_setting('TimeZone') || ' / ' || current_setting('DateStyle'), 'America/Los_Angeles / ISO, MDY',
          'the call leaves the caller''s TimeZone and DateStyle as they were');
set datestyle = 'SQL, DMY';
select is((select count(*) from pgpm._over_retired_chunks('t334.t'))::int
            || ' / ' || current_setting('TimeZone') || ' / ' || current_setting('DateStyle'),
          '3 / America/Los_Angeles / SQL, DMY',
          'after a call under SQL, DMY in America/Los_Angeles the session is still on both');
reset datestyle;
set timezone = 'Asia/Tokyo';

-- G. The grid's own zone, not UTC. Moved (with the bounds rewritten to UTC wall-clock text, which a UTC grid's
-- older install would have written), the same chunks must be read on the new grid's clock: the answer follows
-- partition_tz. gone_b's hi read on Tokyo's clock would end at 18:00 UTC on 31 December, below p0's lo.
create table t334.u (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
set timezone = 'UTC';
insert into t334.u (ts) select timestamptz '2026-01-05 00:00:00+00' + g * interval '1 hour' from generate_series(1, 90) g;
call pgpm.transmute('t334.u', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select pgpm.set_archive_fn('t334.u', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid) values
  ('t334.u', '2025-12-31 20:00:00+00', '2026-01-01 03:00:00', 'gone_u', 'obj/u', now(), 4290000106);
select is((select partition_tz from pgpm.config where parent_table = 't334.u'::regclass), 'UTC',
          'GUARD: the second grid is registered in UTC');
set timezone = 'Asia/Tokyo';
select ok('2026-01-01 03:00:00'::timestamptz < '2026-01-01 00:00:00+00'::timestamptz,
          'LIVENESS: read in Asia/Tokyo, gone_u''s hi ends before the UTC grid''s first partition');
select is((select string_agg(o.child_name::text || ': ' || o.chunks, E'\n') from pgpm._over_retired_chunks('t334.u') o),
          'u_p2026_01_to_2026_11: [2025-12-31 20:00:00+00, 2026-01-01 03:00:00) recorded for gone_u, whose relation no longer exists, at obj/u',
          'from Asia/Tokyo the UTC grid''s first partition is held over gone_u, read on the UTC grid''s clock');
set timezone = 'UTC';

-- H. A zone abbreviation, read in the Default set whatever the caller's (PR #1305's V-01). A pre-#500 install
-- rendered a bound in its session's DateStyle, and under SQL a render ends in the zone's abbreviation: a writer in
-- Asia/Jerusalem wrote one hour into this UTC grid's first partition as '01/01/2026 03:00:00 IST'. IST is Israel's
-- +02 in the Default set and India's +05:30 in the India set an operator in India may run with, where the same text
-- ends two and a half hours BEFORE that partition's lo.
create table t334.v (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into t334.v (ts) select timestamptz '2026-01-05 00:00:00+00' + g * interval '1 hour' from generate_series(1, 90) g;
call pgpm.transmute('t334.v', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select pgpm.set_archive_fn('t334.v', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid) values
  ('t334.v', '2025-12-31 20:00:00+00', '01/01/2026 03:00:00 IST', 'gone_v', 'obj/v', now(), 4290000107);
\set held_v 'v_p2026_01_to_2026_11: [2025-12-31 20:00:00+00, 01/01/2026 03:00:00 IST) recorded for gone_v, whose relation no longer exists, at obj/v'
select is((select lo from pgpm.part where parent_table = 't334.v'::regclass and child_name = 'v_p2026_01_to_2026_11'),
          '2026-01-01 00:00:00+00', 'GUARD: the third grid''s first partition starts at midnight UTC on 1 January');
set timezone = 'Asia/Jerusalem';
set datestyle = 'SQL, MDY';
select is((timestamptz '2026-01-01 01:00:00+00')::text, '01/01/2026 03:00:00 IST',
          'GUARD: the hi is what a session in Asia/Jerusalem under SQL, MDY renders for an hour into that partition');
reset datestyle;
set timezone = 'UTC';
select is((select string_agg(o.child_name::text || ': ' || o.chunks, E'\n') from pgpm._over_retired_chunks('t334.v') o),
          :'held_v', 'from a UTC session on the Default abbreviations the first partition is held over gone_v');
set timezone = 'Asia/Kolkata';
set timezone_abbreviations = 'India';
select ok('01/01/2026 03:00:00 IST'::timestamptz < '2026-01-01 00:00:00+00'::timestamptz,
          'LIVENESS: read with the India abbreviations, gone_v''s hi ends before the first partition''s lo');
select is((select string_agg(o.child_name::text || ': ' || o.chunks, E'\n') from pgpm._over_retired_chunks('t334.v') o),
          :'held_v', 'from Asia/Kolkata on the India abbreviations the call holds the same partition over gone_v');
select is(current_setting('timezone_abbreviations'), 'India',
          'the call leaves the caller''s timezone_abbreviations as they were');
reset timezone_abbreviations;
set timezone = 'UTC';

select * from finish();
