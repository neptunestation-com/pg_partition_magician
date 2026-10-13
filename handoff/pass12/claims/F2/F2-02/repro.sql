-- F2-02: check_time_monotonic casts the time column to timestamptz in the SESSION's zone before comparing,
-- so a naive timestamp column whose values are non-decreasing in id order is reported as decreasing when a
-- pair straddles a spring-forward gap of the caller's zone: '02:30' (a wall time New York skipped on
-- 2026-03-08) reads as 03:30 EDT, after '03:15' EDT. The documented result is the fraction of adjacent pairs
-- whose time is non-decreasing; the column's own values are, and the answer changes with the session's zone.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(4);
create table public.mono (id bigint primary key, t timestamp not null);
insert into public.mono values (1, '2026-03-08 01:50:00'), (2, '2026-03-08 02:30:00'), (3, '2026-03-08 03:15:00');

select is((select string_agg(id::text || '=' || t::text, ',' order by id) from public.mono),
  '1=2026-03-08 01:50:00,2=2026-03-08 02:30:00,3=2026-03-08 03:15:00',
  'LIVENESS: three rows whose naive time increases with the id');
set timezone = 'UTC';
select is((select fraction from pgpm.check_time_monotonic('public.mono', 'id', 't')), 1.0000::numeric,
  'LIVENESS: from a UTC session both adjacent pairs are reported non-decreasing');
set timezone = 'America/New_York';
select ok((timestamp '2026-03-08 02:30:00')::timestamptz > (timestamp '2026-03-08 03:15:00')::timestamptz,
  'LIVENESS: in America/New_York 02:30 on 2026-03-08 is inside the spring-forward gap and casts past 03:15');
select is((select fraction from pgpm.check_time_monotonic('public.mono', 'id', 't')), 1.0000::numeric,
  'from an America/New_York session the same column is reported fully monotonic too');
select * from finish();
