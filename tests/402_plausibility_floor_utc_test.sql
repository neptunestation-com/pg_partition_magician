-- check_uuidv7 and check_text_time judge plausibility against 2015-01-01 UTC, whatever the session's TimeZone
-- (issue #1144, bullet 2).
--
-- Both functions counted a decoded value as plausible when it fell between timestamptz '2015-01-01' and one
-- day past now(). The literal carries no offset, so PostgreSQL read it in the session's TimeZone: midnight UTC
-- from a UTC session, 05:00 UTC from America/New_York, 15:00 UTC on 2014-12-31 from Asia/Tokyo. The same rows
-- were then plausible from one session and not from another, and transmute, which refuses a uuidv7 or
-- text_time column whose plausible fraction is under 0.5, refused or converted the same table depending on
-- the zone of the session that called it. The floor is now the instant 2015-01-01 00:00 UTC.
--
-- Two sampled tables, one per function, with the same five instants, so the defect cannot leave the count in
-- place in either direction:
--   ny1, ny2  2015-01-01 03:00 and 03:30 UTC: plausible. Under the defect New York's floor is 05:00 UTC and
--             both fall under it (a count of 1).
--   tk1       2014-12-31 20:00 UTC: not plausible. Under the defect Tokyo's floor is 15:00 UTC the day
--             before and it rises above it (a count of 4).
--   recent    ten days ago: always plausible.
--   y2013     2013-06-01: never plausible.
-- So the right count is 3 of 5 in every zone, the defect's is 1 from New York and 4 from Tokyo.
--
-- Two converted tables, one per kind, of three rows from the first hours of 2015 and one recent row. From a
-- UTC session all four are plausible; under the defect New York finds one in four, 0.25, and transmute
-- refuses. Each is converted from a New York session and must come out partitioned with its four rows.
-- The CALLs run at top level (a committing procedure cannot run inside lives_ok) with ON_ERROR_STOP off
-- around them, as tests/148's, so a refusal is read as the table left plain rather than ending the file.
--
-- bench/check_text_time_contract.sh runs this file against the mutants check_uuidv7_floor_session_zone and
-- check_text_time_floor_session_zone (the unzoned literal put back), so it is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(16);

-- the five instants, named, decoded once in a UTC session
create temp table at402 (note text primary key, ts timestamptz not null);
insert into at402 values
  ('ny1', timestamptz '2015-01-01 03:00:00+00'),
  ('ny2', timestamptz '2015-01-01 03:30:00+00'),
  ('tk1', timestamptz '2014-12-31 20:00:00+00'),
  ('recent', now() - interval '10 days'),
  ('y2013', timestamptz '2013-06-01 00:00:00+00');

-- a uuidv7 at an instant, made unique by its last hex digit
create table public.pf402u (id uuid primary key, note text);
insert into public.pf402u
  select overlay(pgpm._ts_to_uuid(ts)::text placing to_hex(row_number() over (order by note)::int) from 36)::uuid,
         note
    from at402;

create table public.pf402t (id text collate "C" primary key, note text);
insert into public.pf402t
  select pgpm._ts_to_text_time(ts, 'c', 8, 36, 'ms') || 'p' || note, note from at402;

-- the two tables transmute converts: three rows from the first hours of 2015 and one recent
create table public.pf402cu (id uuid primary key, body text);
insert into public.pf402cu
  select pgpm._ts_to_uuid(t), 'x'
    from unnest(array[timestamptz '2015-01-01 03:00:00+00', timestamptz '2015-01-01 03:10:00+00',
                      timestamptz '2015-01-01 03:20:00+00', date_trunc('second', now()) - interval '10 days']) t;
create table public.pf402ct (id text collate "C" primary key, body text);
insert into public.pf402ct
  select pgpm._ts_to_text_time(t, 'c', 8, 36, 'ms') || 'conv', 'x'
    from unnest(array[timestamptz '2015-01-01 03:00:00+00', timestamptz '2015-01-01 03:10:00+00',
                      timestamptz '2015-01-01 03:20:00+00', date_trunc('second', now()) - interval '10 days']) t;
create temp table rows402 as
  select 'pf402cu'::text as t, string_agg(id::text, ',' order by id::text) as ids from public.pf402cu
  union all
  select 'pf402ct', string_agg(id, ',' order by id) from public.pf402ct;

-- 1-2: LIVENESS: the sampled rows decode to the instants they were built from, so the fixture is what it says
select results_eq(
  $$ select note from public.pf402u u join at402 a using (note) where pgpm._uuid_to_ts(u.id) = date_trunc('milliseconds', a.ts)
      order by note $$,
  $$ values ('ny1'), ('ny2'), ('recent'), ('tk1'), ('y2013') $$,
  'LIVENESS: every uuid decodes to its own instant');
select results_eq(
  $$ select note from public.pf402t t join at402 a using (note)
      where pgpm._text_time_to_ts(t.id, 'c', 8, 36, 'ms') = date_trunc('milliseconds', a.ts)
      order by note $$,
  $$ values ('ny1'), ('ny2'), ('recent'), ('tk1'), ('y2013') $$,
  'LIVENESS: every text_time value decodes to its own instant');

-- 3-4: from UTC, three of five: ny1, ny2 and recent
select results_eq(
  $$ select sampled, plausible from pgpm.check_uuidv7('public.pf402u', 'id') $$,
  $$ values (5::bigint, 3::bigint) $$,
  'from a UTC session check_uuidv7 finds three of five plausible');
select results_eq(
  $$ select sampled, plausible from pgpm.check_text_time('public.pf402t', 'id', 'c', 8, 36, 'ms') $$,
  $$ values (5::bigint, 3::bigint) $$,
  'from a UTC session check_text_time finds three of five plausible');

-- 5-7: America/New_York
set timezone = 'America/New_York';
select ok((select bool_and(ts > timestamptz '2015-01-01 00:00:00+00' and ts < timestamptz '2015-01-01')
             from at402 where note in ('ny1', 'ny2')),
  'LIVENESS: from New York ny1 and ny2 lie between 2015-01-01 UTC and 2015-01-01 read in the session''s zone');
select results_eq(
  $$ select sampled, plausible from pgpm.check_uuidv7('public.pf402u', 'id') $$,
  $$ values (5::bigint, 3::bigint) $$,
  'from a New York session check_uuidv7 still finds three of five plausible');
select results_eq(
  $$ select sampled, plausible from pgpm.check_text_time('public.pf402t', 'id', 'c', 8, 36, 'ms') $$,
  $$ values (5::bigint, 3::bigint) $$,
  'from a New York session check_text_time still finds three of five plausible');

-- 8-10: Asia/Tokyo
set timezone = 'Asia/Tokyo';
select ok((select ts < timestamptz '2015-01-01 00:00:00+00' and ts > timestamptz '2015-01-01' from at402 where note = 'tk1'),
  'LIVENESS: from Tokyo tk1 lies between 2015-01-01 read in the session''s zone and 2015-01-01 UTC');
select results_eq(
  $$ select sampled, plausible from pgpm.check_uuidv7('public.pf402u', 'id') $$,
  $$ values (5::bigint, 3::bigint) $$,
  'from a Tokyo session check_uuidv7 still finds three of five plausible');
select results_eq(
  $$ select sampled, plausible from pgpm.check_text_time('public.pf402t', 'id', 'c', 8, 36, 'ms') $$,
  $$ values (5::bigint, 3::bigint) $$,
  'from a Tokyo session check_text_time still finds three of five plausible');

-- 11-12: LIVENESS, from UTC: both converted tables sample as wholly plausible before they are converted
set timezone = 'UTC';
select is((select fraction from pgpm.check_uuidv7('public.pf402cu', 'id')), 1.0000::numeric,
  'LIVENESS: from a UTC session pf402cu samples at 1.0');
select is((select fraction from pgpm.check_text_time('public.pf402ct', 'id', 'c', 8, 36, 'ms')), 1.0000::numeric,
  'LIVENESS: from a UTC session pf402ct samples at 1.0');

-- 13-16: transmute from New York converts both, rows intact
set timezone = 'America/New_York';
\set ON_ERROR_STOP 0
call pgpm.transmute('public.pf402cu', 'id', interval '1 month', p_paused => true);
call pgpm.transmute('public.pf402ct', 'id', interval '1 month', p_tt_prefix => 'c', p_tt_width => 8,
                    p_tt_radix => 36, p_tt_unit => 'ms', p_paused => true);
\set ON_ERROR_STOP 1
select is((select relkind::text from pg_class where oid = 'public.pf402cu'::regclass), 'p',
  'transmute from a New York session converts the uuidv7 table');
select is((select string_agg(id::text, ',' order by id::text) from public.pf402cu),
          (select ids from rows402 where t = 'pf402cu'),
  'with its four rows');
select is((select relkind::text from pg_class where oid = 'public.pf402ct'::regclass), 'p',
  'transmute from a New York session converts the text_time table');
select is((select string_agg(id, ',' order by id) from public.pf402ct),
          (select ids from rows402 where t = 'pf402ct'),
  'with its four rows');

select * from finish();
