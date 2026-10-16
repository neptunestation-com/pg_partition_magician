-- pgpm._over_retired_chunks gives the same answer from every session (issue #1264), reads a retired chunk's bound
-- that names no instant at its widest (#1336), and reads a partition's own bound that names no zone on the grid's
-- clock.
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
-- same partitions over the same chunks from every session's TimeZone, DateStyle and abbreviation set. A bound with
-- an offset is the instant it names. A RETIRED chunk's bound that names no instant by itself was written in a
-- session nothing recorded, so it is read at its widest (#1336; tests/347 holds the rest of that contract): its
-- wall time under MDY and under DMY, a lo at UTC+14 and a hi at UTC-12, whatever zone the text names. A
-- PARTITION's own bound with no offset (pgpm writes none, an operator's hand might) is wall time in the grid's own
-- zone, config.partition_tz; a DateStyle-shaped one reads as ISO, MDY, the style _ts_text writes every bound in; a
-- zone abbreviation (a pre-#500 render under DateStyle SQL ends in one) reads in the Default set (part I).
--
-- THE FIXTURE. The grid is registered in Asia/Tokyo (+09). Five retired chunks, every one of them read differently
-- by some session below, and each check names the partitions and the chunks:
--   gone_a  [p0.lo - 6h, p0.lo - 3h)  hi offset-less: ends below p0 on Tokyo's clock, and 18 hours into it at
--                                     UTC-12, so it holds p0
--   gone_b  [p0.lo - 4h, p0.lo + 3h)  hi offset-less: reaches into p0 on Tokyo's clock; not from Pacific/Kiritimati
--   gone_c  [p1.lo + 2h, p1.lo + 5h)  lo offset-less: inside p1 on Tokyo's clock; reaches into p0 at UTC+14, and
--                                     is empty (lo past hi) from UTC
--   gone_d  [11/03/2026, 11/04/2026)  both offset-less and DateStyle-shaped: 3 November (inside p1) as MDY,
--                                     11 March (inside p0) as DMY, so at its widest it spans both
--   gone_e  [p2.lo + 9h, p2.lo + 15h) both with an offset (+00): the same instant in every session
-- Expected: p0 over gone_a, gone_b, gone_d and gone_c; p1 over gone_d and gone_c; p2 over gone_e.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'Asia/Tokyo';
select plan(30);

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

\set expected 't_p2026_01_to_2026_11: [2025-12-31 18:00:00+09, 2025-12-31 21:00:00) recorded for gone_a, whose relation no longer exists, at obj/a; [2025-12-31 20:00:00+09, 2026-01-01 03:00:00) recorded for gone_b, whose relation no longer exists, at obj/b; [11/03/2026 00:00:00, 11/04/2026 00:00:00) recorded for gone_d, whose relation no longer exists, at obj/d; [2026-11-01 02:00:00, 2026-11-01 05:00:00+09) recorded for gone_c, whose relation no longer exists, at obj/c\nt_p2026_11: [11/03/2026 00:00:00, 11/04/2026 00:00:00) recorded for gone_d, whose relation no longer exists, at obj/d; [2026-11-01 02:00:00, 2026-11-01 05:00:00+09) recorded for gone_c, whose relation no longer exists, at obj/c\nt_p2026_12: [2026-12-01 00:00:00+00, 2026-12-01 06:00:00+00) recorded for gone_e, whose relation no longer exists, at obj/e'

-- GUARD: the fixture is the one described above (the grid, and its three partitions' bounds)
select is((select partition_tz from pgpm.config where parent_table = 't334.t'::regclass), 'Asia/Tokyo',
          'GUARD: the grid is registered in Asia/Tokyo, a wall clock nine hours east of UTC');
select is((select string_agg(format('%s [%s, %s)', child_name, lo, hi), '; ' order by lo::timestamptz)
             from pgpm.part where parent_table = 't334.t'::regclass and attached),
          't_p2026_01_to_2026_11 [2026-01-01 00:00:00+09, 2026-11-01 00:00:00+09); '
            || 't_p2026_11 [2026-11-01 00:00:00+09, 2026-12-01 00:00:00+09); '
            || 't_p2026_12 [2026-12-01 00:00:00+09, 2027-01-01 00:00:00+09)',
          'GUARD: three attached partitions, p0 from January, p1 November, p2 December');

-- A. From a session on the grid's own zone and the default DateStyle, where gone_a ends below p0.
select ok('2025-12-31 21:00:00'::timestamptz < '2026-01-01 00:00:00+09'::timestamptz,
          'LIVENESS: read in Asia/Tokyo, the grid''s own zone, gone_a ends below p0');
select is(t334.held(), :'expected',
          'from Asia/Tokyo, ISO: p0 over gone_a, gone_b, gone_d and gone_c, p1 over gone_d and gone_c, p2 over gone_e');

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

-- G. A UTC grid read from Tokyo: gone_u's hi, read on Tokyo's clock, ends at 18:00 UTC on 31 December, below the
-- first partition's lo; at its widest it reaches 15:00 UTC on 1 January, inside it.
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
          'from Asia/Tokyo the UTC grid''s first partition is held over gone_u, read at its widest');
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

-- I. A partition's own bounds stay on the grid's clock (#1264's rule, which the widening above does not touch): a
-- fourth grid, in Asia/Tokyo, whose pgpm.part rows an operator's hand rewrote into the three shapes a session reads
-- differently, over three retired chunks that all carry their offset:
--   w_p0.lo  '12/31/2025 17:00:00 IST'  a pre-#500 SQL render by an Asia/Jerusalem session of p0's lo; India's IST
--                                       (+05:30) puts it 3.5 hours earlier, over gone_w3
--   w_p1.lo  '2026-11-01 00:00:00'      offset-less: 1 November in Tokyo; in UTC nine hours later, past gone_w1
--   w_p2.lo  '12/01/2026 00:00:00 JST'  MDY-shaped: 1 December; as DMY 12 January, over gone_w2 and gone_w1
-- Expected from every session: w_p0 over gone_w2, w_p1 over gone_w1; gone_w3 nowhere.
set timezone = 'Asia/Tokyo';
create table t334.w (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into t334.w (ts) select timestamptz '2026-01-05 00:00:00+00' + g * interval '1 hour' from generate_series(1, 90) g;
call pgpm.transmute('t334.w', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select pgpm.set_archive_fn('t334.w', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
select is((select string_agg(format('%s [%s, %s)', child_name, lo, hi), '; ' order by child_name)
             from pgpm.part where parent_table = 't334.w'::regclass and attached),
          'w_p2026_01_to_2026_11 [2026-01-01 00:00:00+09, 2026-11-01 00:00:00+09); '
            || 'w_p2026_11 [2026-11-01 00:00:00+09, 2026-12-01 00:00:00+09); '
            || 'w_p2026_12 [2026-12-01 00:00:00+09, 2027-01-01 00:00:00+09)',
          'GUARD: the fourth grid has the first grid''s three partitions, before the hand rewrite');
update pgpm.part set lo = '12/31/2025 17:00:00 IST' where parent_table = 't334.w'::regclass and child_name = 'w_p2026_01_to_2026_11';
update pgpm.part set lo = '2026-11-01 00:00:00' where parent_table = 't334.w'::regclass and child_name = 'w_p2026_11';
update pgpm.part set lo = '12/01/2026 00:00:00 JST' where parent_table = 't334.w'::regclass and child_name = 'w_p2026_12';
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid) values
  ('t334.w', '2026-11-01 03:00:00+09', '2026-11-01 05:00:00+09', 'gone_w1', 'obj/w1', now(), 4290000111),
  ('t334.w', '2026-06-01 00:00:00+09', '2026-06-02 00:00:00+09', 'gone_w2', 'obj/w2', now(), 4290000112),
  ('t334.w', '2025-12-31 21:00:00+09', '2025-12-31 23:00:00+09', 'gone_w3', 'obj/w3', now(), 4290000113);
\set held_w 'w_p2026_01_to_2026_11: [2026-06-01 00:00:00+09, 2026-06-02 00:00:00+09) recorded for gone_w2, whose relation no longer exists, at obj/w2\nw_p2026_11: [2026-11-01 03:00:00+09, 2026-11-01 05:00:00+09) recorded for gone_w1, whose relation no longer exists, at obj/w1'
-- a call that raises (a shape the session's DateStyle cannot parse) is an answer too, and a wrong one
create function t334.held_w() returns text language plpgsql as $$
begin
  return (select coalesce(string_agg(format('%s: %s', o.child_name, o.chunks), E'\n' order by o.child_name), '')
            from pgpm._over_retired_chunks('t334.w') o);
exception when others then
  return 'raised: ' || sqlerrm;
end $$;
select is(t334.held_w(), :'held_w', 'from Asia/Tokyo: w_p0 over gone_w2, w_p1 over gone_w1, gone_w3 nowhere');
set timezone = 'UTC';
select ok('2026-11-01 00:00:00'::timestamptz >= '2026-11-01 05:00:00+09'::timestamptz,
          'LIVENESS: read in UTC, w_p1''s lo lies past gone_w1');
select is(t334.held_w(), :'held_w', 'from UTC the call holds the same partitions of the fourth grid');
set timezone = 'Asia/Kolkata';
set timezone_abbreviations = 'India';
select ok('12/31/2025 17:00:00 IST'::timestamptz < '2025-12-31 23:00:00+09'::timestamptz,
          'LIVENESS: on the India abbreviations, w_p0''s lo reads 3.5 hours earlier, below gone_w3''s hi');
set datestyle = 'SQL, DMY';
select ok('12/01/2026 00:00:00 JST'::timestamptz < '2026-06-01 00:00:00+09'::timestamptz,
          'LIVENESS: under DMY, w_p2''s lo reads as 12 January, below gone_w2');
select is(t334.held_w(), :'held_w',
          'from Asia/Kolkata on the India abbreviations under SQL, DMY the call holds the same partitions');
reset datestyle;
reset timezone_abbreviations;
set timezone = 'UTC';

select * from finish();
