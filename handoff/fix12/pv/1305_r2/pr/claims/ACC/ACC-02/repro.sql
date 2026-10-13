-- V-01 (claims verifier, PR #1305 / #1264): pgpm._native_bound_key pins TimeZone and DateStyle but not
-- timezone_abbreviations, so a legacy retired bound that names its zone by ABBREVIATION (a pre-#500 render under
-- DateStyle SQL, '01/01/2026 03:00:00 IST', or a pre-#977 strategy's covered_hi kept verbatim) still names a
-- different instant in different sessions. 'IST' is Israel (+02) under the Default set and India (+05:30) under
-- the India set an operator in India runs with. The PR's helper promises "read the same from every session";
-- tests/317 promises the same answer from any session.
--
-- Fixture: a UTC grid; one retired chunk [p0.lo - 4h, p0.lo + 1h) whose lo is canonical text and whose hi was
-- rendered by a pre-#500 writer in Asia/Jerusalem under 'SQL, MDY' (January: IST = +02). It overlaps p0 by an
-- hour. From pg_cron's default session p0 is held; from an operator session with timezone_abbreviations =
-- 'India' the same hi reads 3.5 hours earlier, before p0's lo, and p0 is not held: archived over the retired
-- range.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(6);

create schema v01;
create table v01.t (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into v01.t (ts) select timestamptz '2026-01-05 00:00:00+00' + g * interval '1 hour' from generate_series(1, 90) g;
call pgpm.transmute('v01.t', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select pgpm.set_archive_fn('v01.t', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);

select child_name as p0, lo as p0_lo from pgpm.part where parent_table = 'v01.t'::regclass and attached
 order by lo::timestamptz limit 1 \gset
select pgpm._ts_text(:'p0_lo'::timestamptz - interval '4 hours') as c_lo \gset
-- the writer's render: a pre-#500 session in Asia/Jerusalem under DateStyle SQL, MDY
set timezone = 'Asia/Jerusalem';
set datestyle = 'SQL, MDY';
select (:'p0_lo'::timestamptz + interval '1 hour')::text as c_hi \gset
reset datestyle;
set timezone = 'UTC';
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid)
values ('v01.t', :'c_lo', :'c_hi', 'gone_v01', 'obj/v01', now(), 4290000098);

select ok(:'c_hi' ~ ' IST$' and pgpm._native_order_key(:'c_hi') is null,
  'LIVENESS: the retired chunk''s hi names its zone by the abbreviation IST (a pre-#500 SQL-style render) and has no order key');
select is(:'c_hi'::timestamptz, :'p0_lo'::timestamptz + interval '1 hour',
  'GUARD: under the Default abbreviations the hi is the instant its writer meant, an hour into p0');
select is((select string_agg(child_name::text, ',') from pgpm._over_retired_chunks('v01.t')), :'p0',
  'LIVENESS: from pg_cron''s default session p0 is held over the retired chunk');

set timezone = 'Asia/Kolkata';
set timezone_abbreviations = 'India';
select ok(:'c_hi'::timestamptz < :'p0_lo'::timestamptz,
  'LIVENESS: with the India abbreviations the same hi reads before p0''s lo');
select is(current_setting('DateStyle'), 'ISO, MDY', 'GUARD: the operator session keeps the default DateStyle');
select is((select string_agg(child_name::text, ',') from pgpm._over_retired_chunks('v01.t')), :'p0',
  'from an operator session with timezone_abbreviations = India the same call holds p0 (it does not: the abbreviation is read in the caller''s set)');
reset timezone_abbreviations;
set timezone = 'UTC';

select * from finish();
