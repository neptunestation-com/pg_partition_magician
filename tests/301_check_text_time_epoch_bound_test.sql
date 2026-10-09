-- check_text_time decodes against p_epoch as an instant, whatever the session's DateStyle and TimeZone
-- (issue #1081).
--
-- check_text_time spliced p_epoch into its dynamic query with %L: a bare text render of a timestamptz under
-- the session's DateStyle and TimeZone, which the executed query parsed back. Under 'SQL, DMY' in
-- Asia/Kolkata the Unix epoch rendered as '01/01/1970 05:30:00 IST', and the parser read IST as Israel's
-- +02, so every decoded instant came back 3.5 hours late; in Europe/Dublin ('01/01/1970 01:00:00 IST') one
-- hour early. Both the sample's plausibility count and the column's maximum moved with it: a maximum two
-- hours old was reported as newest_in_future. The epoch is now a bound parameter of the dynamic query.
--
-- Three tables, so each path has a fixture whose expected effect the defect cannot leave in place:
--   tt301a  the maximum path (cuid ms): the maximum two hours old must decode to its instant and not be in
--           the future, in every session (3.5 hours late it is 1.5 hours in the future).
--   tt301b  the sample path (cuid ms): four rows, three plausible. 23.5 hours ahead is plausible (the window
--           ends one day past now()) and falls out of it 3.5 hours late; 2015-01-01 00:30 UTC is plausible
--           (the floor is 2015-01-01 in the session's zone) and falls under it one hour early in Dublin;
--           2013 is never plausible. So the defect counts 2 in each zone, for a different row in each.
--   tt301c  a non-default epoch (seconds since 2014-05-13 16:53:20+00, KSUID's): the maximum decodes to its
--           instant, so the bound parameter is p_epoch itself and not only the default.
-- The expected instants are decoded once, in a UTC, ISO session, into a temp table, so no expected value
-- itself makes a text round trip through the sessions under test.
--
-- PostgreSQL 18 reads an abbreviation of the session's own zone before timezone_abbreviations, so there a
-- bare render round-trips in these zones and the defect does not show. The contract assertions run on every
-- version; the LIVENESS witnesses that the session really misreads a bare render are asserted below 18 and
-- skipped from 18 on. bench/check_text_time_contract.sh runs this file against the mutant
-- check_text_time_epoch_spliced (the %L splice put back) on the discriminate track's PostgreSQL 17.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
set datestyle = 'ISO, MDY';
select plan(14);

create table public.tt301a (id text collate "C" primary key);
insert into public.tt301a values
  ('c' || pgpm._radix_encode(1700000000000, 36, 8) || 'old0'),
  (pgpm._ts_to_text_time(now() - interval '2 hours', 'c', 8, 36, 'ms') || 'max0');

create table public.tt301b (id text collate "C" primary key, note text);
insert into public.tt301b values
  (pgpm._ts_to_text_time(now() - interval '10 days', 'c', 8, 36, 'ms') || 'b1', 'ten days ago'),
  (pgpm._ts_to_text_time(now() + interval '23 hours 30 minutes', 'c', 8, 36, 'ms') || 'b2', '23.5 hours ahead'),
  (pgpm._ts_to_text_time(timestamptz '2015-01-01 00:30:00+00', 'c', 8, 36, 'ms') || 'b3', 'half past 2015'),
  (pgpm._ts_to_text_time(timestamptz '2013-06-01 00:00:00+00', 'c', 8, 36, 'ms') || 'b4', '2013');

create table public.tt301c (id text collate "C" primary key);
insert into public.tt301c values
  (pgpm._ts_to_text_time(now() - interval '3 days', 'k', 8, 36, 's', null, 0, timestamptz '2014-05-13 16:53:20+00') || 'c1'),
  (pgpm._ts_to_text_time(now() - interval '2 hours', 'k', 8, 36, 's', null, 0, timestamptz '2014-05-13 16:53:20+00') || 'c2');

create temp table want301 as
  select 'a'::text as k, pgpm._text_time_to_ts((select max(id) from public.tt301a), 'c', 8, 36, 'ms') as ts
  union all
  select 'c', pgpm._text_time_to_ts((select max(id) from public.tt301c), 'k', 8, 36, 's', null, 0,
                                    timestamptz '2014-05-13 16:53:20+00');

-- 1-3: LIVENESS, from a UTC, ISO session (where a bare render round-trips): the fixture is what it says.
select ok((select ts from want301 where k = 'a') between now() - interval '2 hours 5 minutes' and now() - interval '1 hour 59 minutes'
          and (select ts from want301 where k = 'c') between now() - interval '2 hours 5 minutes' and now() - interval '1 hour 59 minutes',
  'LIVENESS: both maxima decode to about two hours ago');
select results_eq(
  $$ select (select newest_decoded from pgpm.check_text_time('public.tt301a', 'id', 'c', 8, 36, 'ms')),
            (select newest_in_future from pgpm.check_text_time('public.tt301a', 'id', 'c', 8, 36, 'ms')),
            (select newest_decoded from pgpm.check_text_time('public.tt301c', 'id', 'k', 8, 36, 's', 1000, null, 0,
                                                             timestamptz '2014-05-13 16:53:20+00')) $$,
  $$ select (select ts from want301 where k = 'a'), false, (select ts from want301 where k = 'c') $$,
  'LIVENESS: from a UTC, ISO session both maxima are those instants, and neither is in the future');
select results_eq(
  $$ select sampled, plausible from pgpm.check_text_time('public.tt301b', 'id', 'c', 8, 36, 'ms') $$,
  $$ values (4::bigint, 3::bigint) $$,
  'LIVENESS: from a UTC, ISO session tt301b samples four rows, three of them plausible');

-- 4-8: Asia/Kolkata under 'SQL, DMY'
set timezone = 'Asia/Kolkata';
set datestyle = 'SQL, DMY';
select case when current_setting('server_version_num')::int < 180000
  then ok((timestamptz '1970-01-01 00:00:00+00')::text::timestamptz <> timestamptz '1970-01-01 00:00:00+00'
          and (timestamptz '2014-05-13 16:53:20+00')::text::timestamptz <> timestamptz '2014-05-13 16:53:20+00',
          'LIVENESS: in Asia/Kolkata under SQL, DMY a bare render of either epoch reads back as another instant')
  else skip('PostgreSQL 18 reads the session zone''s own abbreviations first, so a bare render round-trips here', 1)
end;
select is((select newest_decoded from pgpm.check_text_time('public.tt301a', 'id', 'c', 8, 36, 'ms')),
          (select ts from want301 where k = 'a'),
  'from an Asia/Kolkata, SQL DMY session the maximum is the same instant');
select is((select newest_in_future from pgpm.check_text_time('public.tt301a', 'id', 'c', 8, 36, 'ms')), false,
  'and a maximum two hours old is not reported as in the future');
select results_eq(
  $$ select sampled, plausible from pgpm.check_text_time('public.tt301b', 'id', 'c', 8, 36, 'ms') $$,
  $$ values (4::bigint, 3::bigint) $$,
  'from an Asia/Kolkata, SQL DMY session the row 23.5 hours ahead is still plausible: three of four');
select is((select newest_decoded from pgpm.check_text_time('public.tt301c', 'id', 'k', 8, 36, 's', 1000, null, 0,
                                                           timestamptz '2014-05-13 16:53:20+00')),
          (select ts from want301 where k = 'c'),
  'from an Asia/Kolkata, SQL DMY session a maximum against the 2014 epoch is the same instant');

-- 9-12: Europe/Dublin under 'SQL, DMY'
set timezone = 'Europe/Dublin';
select case when current_setting('server_version_num')::int < 180000
  then ok((timestamptz '1970-01-01 00:00:00+00')::text::timestamptz <> timestamptz '1970-01-01 00:00:00+00',
          'LIVENESS: in Europe/Dublin under SQL, DMY a bare render of the Unix epoch reads back as another instant')
  else skip('PostgreSQL 18 reads the session zone''s own abbreviations first, so a bare render round-trips here', 1)
end;
select is((select newest_decoded from pgpm.check_text_time('public.tt301a', 'id', 'c', 8, 36, 'ms')),
          (select ts from want301 where k = 'a'),
  'from a Europe/Dublin, SQL DMY session the maximum is the same instant');
select results_eq(
  $$ select sampled, plausible from pgpm.check_text_time('public.tt301b', 'id', 'c', 8, 36, 'ms') $$,
  $$ values (4::bigint, 3::bigint) $$,
  'from a Europe/Dublin, SQL DMY session half past midnight on 2015-01-01 is still plausible: three of four');
select is((select newest_decoded from pgpm.check_text_time('public.tt301c', 'id', 'k', 8, 36, 's', 1000, null, 0,
                                                           timestamptz '2014-05-13 16:53:20+00')),
          (select ts from want301 where k = 'c'),
  'from a Europe/Dublin, SQL DMY session a maximum against the 2014 epoch is the same instant');

-- 13-14: the fixture's plausible rows are the three named, in the reference session (identity, not a count)
set timezone = 'UTC';
set datestyle = 'ISO, MDY';
select results_eq(
  $$ select note from public.tt301b
      where pgpm._text_time_to_ts(id, 'c', 8, 36, 'ms') between timestamptz '2015-01-01' and now() + interval '1 day'
      order by note $$,
  $$ values ('23.5 hours ahead'), ('half past 2015'), ('ten days ago') $$,
  'LIVENESS: the three plausible rows of tt301b are the ones 23.5 hours ahead, half past 2015 and ten days ago');
select is((select note from public.tt301b
            where pgpm._text_time_to_ts(id, 'c', 8, 36, 'ms') < timestamptz '2015-01-01'),
          '2013',
  'LIVENESS: and the one implausible row is the 2013 one');

select * from finish();
