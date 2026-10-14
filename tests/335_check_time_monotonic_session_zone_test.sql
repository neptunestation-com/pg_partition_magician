-- check_time_monotonic's answer does not depend on the caller's TimeZone (issue #1265).
--
-- THE BUG. check_time_monotonic compared %I::timestamptz, so a naive `timestamp` column (or a text column
-- holding naive wall times) was cast in the CALLER's session zone before adjacent pairs were compared. A wall
-- time inside that zone's spring-forward gap reads an hour later: 02:30 on 2026-03-08 in America/New_York is
-- 03:30 EDT, past 03:15. The same column then reported 1.0 from a UTC session and 0.5 from New York, and a pair
-- that DOES decrease across the gap read as non-decreasing. docs/reference.md defines the result as the
-- fraction of adjacent pairs whose time is non-decreasing, the column's own values, with no word of a zone.
--
-- THE CONTRACT.
--   PART A  the issue's column, naive and rising with the id across New York's gap: 1.0 from UTC and from New
--           York alike.
--   PART B  the other direction, so the fixture cannot pass by reading everything as rising: four rows with one
--           pair that falls across the gap (03:15 then 02:30). From UTC and from New York alike, exactly two of
--           the three pairs are non-decreasing, and the count says which ones are not by its total.
--   PART C  the same for a text column holding naive wall times, which the cast reads the same way.
--   PART D  the cast is still a cast: a text column whose values carry explicit offsets is compared by instant,
--           not as text (its lexical order is the reverse of its instants), and a timestamptz column by instant.
--   PART E  the call leaves the caller's TimeZone as it found it, in autocommit and inside a transaction that
--           set it LOCAL.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(17);

-- ---------------------------------------------------------------- fixtures
create table public.mono335 (id bigint primary key, t timestamp not null);
insert into public.mono335 values
  (1, '2026-03-08 01:50:00'), (2, '2026-03-08 02:30:00'), (3, '2026-03-08 03:15:00');

-- asymmetric: three pairs, one falls (2 -> 3: 03:15 then 02:30), two rise
create table public.dip335 (id bigint primary key, t timestamp not null);
insert into public.dip335 values
  (1, '2026-03-08 01:00:00'), (2, '2026-03-08 03:15:00'), (3, '2026-03-08 02:30:00'), (4, '2026-03-08 04:00:00');

create table public.txt335 (id bigint primary key, t text not null);
insert into public.txt335 values
  (1, '2026-03-08 01:00:00'), (2, '2026-03-08 03:15:00'), (3, '2026-03-08 02:30:00'), (4, '2026-03-08 04:00:00');

-- instants 03:00Z, 07:00Z, 09:00Z: rising; as text they fall
create table public.off335 (id bigint primary key, t text not null);
insert into public.off335 values
  (1, '2026-03-08 03:00:00+00'), (2, '2026-03-08 02:00:00-05'), (3, '2026-03-08 01:00:00-08');

create table public.tz335 (id bigint primary key, t timestamptz not null);
insert into public.tz335 values
  (1, '2026-03-08 06:50:00+00'), (2, '2026-03-08 07:10:00+00'), (3, '2026-03-08 06:55:00+00');

set timezone = 'America/New_York';
select ok((timestamp '2026-03-08 02:30:00')::timestamptz > (timestamp '2026-03-08 03:15:00')::timestamptz,
  'LIVENESS: in America/New_York 02:30 on 2026-03-08 is inside the spring-forward gap and casts past 03:15');

-- ---------------------------------------------------------------- PART A
set timezone = 'UTC';
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.mono335', 'id', 't')),
  '(2,2,1.0000)', 'A: from a UTC session the rising naive column reports both pairs non-decreasing');
set timezone = 'America/New_York';
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.mono335', 'id', 't')),
  '(2,2,1.0000)', 'A: from an America/New_York session the same column reports both pairs non-decreasing too');

-- ---------------------------------------------------------------- PART B
select is((select string_agg(id::text, ',' order by id) from public.dip335 d
            where t < (select t from public.dip335 p where p.id = d.id - 1)),
  '3', 'LIVENESS: dip335 falls at exactly one pair, into id 3');
set timezone = 'UTC';
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.dip335', 'id', 't')),
  '(3,2,0.6667)', 'B: from UTC, two of the three pairs of dip335 are non-decreasing');
set timezone = 'America/New_York';
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.dip335', 'id', 't')),
  '(3,2,0.6667)', 'B: from America/New_York, the pair that falls across the gap still reads as falling');

-- ---------------------------------------------------------------- PART C
set timezone = 'UTC';
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.txt335', 'id', 't')),
  '(3,2,0.6667)', 'C: from UTC, the text column of naive wall times has two non-decreasing pairs of three');
set timezone = 'America/New_York';
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.txt335', 'id', 't')),
  '(3,2,0.6667)', 'C: from America/New_York, the same text column reports the same');

-- ---------------------------------------------------------------- PART D
select ok((select t from public.off335 where id = 2) < (select t from public.off335 where id = 1)
          and (select t from public.off335 where id = 3) < (select t from public.off335 where id = 2),
  'LIVENESS: as text, off335 falls at every pair');
select ok((select t::timestamptz from public.off335 where id = 1) < (select t::timestamptz from public.off335 where id = 2)
          and (select t::timestamptz from public.off335 where id = 2) < (select t::timestamptz from public.off335 where id = 3),
  'LIVENESS: as instants, off335 rises at every pair');
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.off335', 'id', 't')),
  '(2,2,1.0000)', 'D: a text column with explicit offsets is compared by instant, not as text');
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.tz335', 'id', 't')),
  '(2,1,0.5000)', 'D: a timestamptz column is compared by instant (one rise, one fall)');
set timezone = 'Asia/Kolkata';
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.tz335', 'id', 't')),
  '(2,1,0.5000)', 'D: and the same from another zone');

-- ---------------------------------------------------------------- PART E
set timezone = 'America/New_York';
select is((select fraction from pgpm.check_time_monotonic('public.tz335', 'id', 't')), 0.5000::numeric,
  'LIVENESS: the call before the check below ran and read its column');
select is(current_setting('TimeZone'), 'America/New_York',
  'E: after the call the caller''s session TimeZone is still America/New_York');
begin;
set local timezone = 'Europe/Berlin';
select is((select fraction from pgpm.check_time_monotonic('public.dip335', 'id', 't')), 0.6667::numeric,
  'E: inside a transaction that set its zone LOCAL the call reports the same fraction');
select is(current_setting('TimeZone'), 'Europe/Berlin',
  'E: and leaves the transaction''s LOCAL zone in place');
commit;

select * from finish();
