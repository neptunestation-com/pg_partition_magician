-- A time literal keeps its era (issue #733).
--
-- pgpm._time_literal rendered the wall time with to_char 'YYYY', which prints the year without its era, so
-- an instant before 1 AD came back as an AD year: 100 BC read back as 100 AD. Every bound pgpm writes for
-- the `time` kind goes through it (`for values from`, the monolith's bound CHECK, every `ctl >= lo` copy
-- predicate), so transmute on a table whose oldest row is 100 BC committed a NOT VALID pgpm_monolith_bound
-- with lo in 101 AD in phase 1, and phase 2's VALIDATE died on the table's own row with a raw 23514,
-- leaving the write-rejecting CHECK on the live table. The literal now carries ' BC' when its wall time is
-- before 1 AD, where PostgreSQL's own output puts it and where every DateStyle reads it.
--
-- Fixtures, asymmetric on purpose:
--   (A) the round trip: five instants on both sides of the era, rendered in three zones whose offsets for
--       those dates are local mean time (Asia/Kolkata +05:53:28, America/New_York -04:56:02), so two of
--       the fifteen wall times sit in the OTHER era from the instant's UTC reading (the last microsecond
--       of 1 BC is already 1 AD in Kolkata, and the first instant of 1 AD is still 1 BC in New York). Each
--       literal must read back as its own instant, as timestamptz, as timestamp and as date, from a session
--       in another DateStyle and zone as well.
--   (B) the issue's scenario: a timestamptz table holding one 100 BC row and two recent ones converts with
--       all three in the monolith, a bound that starts before 1 AD, nothing left behind, and the bound
--       still taking a BC write after the cutover.
--   (C) the same on a naive date column (read as wall time in UTC, #504).
-- bench/time_literal_era.sh runs this file against the mutant that drops the era again
-- (time_literal_drops_era), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(19);

set timezone = 'UTC';
set datestyle = 'ISO, MDY';

-- (A) the round trip
create temp table era_case as
  select v.ts::timestamptz as ts, z.tz
    from (values ('0100-06-01 00:00:00+00 BC'), ('0044-03-15 12:30:00.25+00 BC'),
                 ('0001-12-31 23:59:59.999999+00 BC'), ('0001-01-01 00:00:00+00'),
                 ('2026-03-15 12:34:56.789+00')) v(ts)
   cross join (values ('UTC'), ('Asia/Kolkata'), ('America/New_York')) z(tz);

select is((select count(*)::int from era_case where (ts at time zone tz) < timestamp '0001-01-01 00:00:00'), 9,
  'A LIVENESS: nine of the fifteen wall times are before 1 AD');
select is((select array_agg(tz || ' ' || (ts at time zone tz)::text order by tz)
             from era_case
            where (ts at time zone tz < timestamp '0001-01-01') <> (ts at time zone 'UTC' < timestamp '0001-01-01')),
  array['America/New_York 0001-12-31 19:03:58 BC', 'Asia/Kolkata 0001-01-01 05:53:27.999999'],
  'A LIVENESS: exactly two wall times are in the other era from their instant''s UTC reading');
select is((select array_agg(pgpm._time_literal(ts, tz) order by ts, tz) from era_case where tz <> 'UTC' and ts < '0001-01-01 00:00:00+00'
             and ts > '0002-01-01 00:00:00+00 BC'),
  array['0001-12-31 19:03:57.999999-04:56:02 BC', '0001-01-01 05:53:27.999999+05:53:28'],
  'A: the last microsecond of 1 BC renders as 1 AD in Kolkata and as 1 BC in New York, offsets kept');
select is((select array_agg(tz || ' ' || ts::text order by ts, tz) from era_case
            where pgpm._time_literal(ts, tz)::timestamptz is distinct from ts),
  null::text[],
  'A: every literal reads back as its own instant as timestamptz');
select is((select array_agg(ts::text order by ts) from era_case
            where tz = 'UTC' and pgpm._time_literal(ts, tz)::timestamp is distinct from (ts at time zone 'UTC')),
  null::text[],
  'A: every UTC literal reads back as its own wall time as timestamp (a naive column)');
select is((select array_agg(d::text order by d)
             from (values (date '0100-06-01 BC'), (date '0001-12-31 BC'), (date '0001-01-01')) v(d)
            where pgpm._time_literal(d::timestamp at time zone 'UTC', 'UTC')::date is distinct from d),
  null::text[],
  'A: a midnight literal reads back as its own date, on either side of the era');
select is((select array_agg(pgpm._time_literal(ts, 'UTC') order by ts) from era_case
            where tz = 'UTC' and ts < '0002-01-01 00:00:00+00'),
  array['0100-06-01 00:00:00+00:00 BC', '0044-03-15 12:30:00.25+00:00 BC', '0001-12-31 23:59:59.999999+00:00 BC',
        '0001-01-01 00:00:00+00:00'],
  'A: the era is written for a BC instant and only for one');

set datestyle = 'SQL, DMY';
set timezone = 'Pacific/Chatham';
select is((select array_agg(tz || ' ' || ts::text order by ts, tz) from era_case
            where pgpm._time_literal(ts, tz)::timestamptz is distinct from ts),
  null::text[],
  'A: and from a session in DateStyle SQL, DMY and zone Pacific/Chatham too');
set datestyle = 'ISO, MDY';
set timezone = 'UTC';

-- (B) the issue's scenario, timestamptz, yearly grid
create table public.era_tz (id bigint not null, at timestamptz not null, primary key (id, at));
insert into public.era_tz values (1, '0100-06-01 00:00:00+00 BC'), (2, now() - interval '1 day'),
                                 (3, now() - interval '2 hours');
select oid as era_tz_oid from pg_class where oid = 'public.era_tz'::regclass \gset
select is((select array_agg(id order by id) from public.era_tz where at < '0001-01-01 00:00:00+00'), array[1]::bigint[],
  'B LIVENESS: era_tz''s oldest row (id 1) is before 1 AD, and only it');
call pgpm.transmute('public.era_tz', 'at', interval '1 year', p_obtain => 1);
select is((select relkind::text from pg_class where oid = 'public.era_tz'::regclass), 'p', 'B: era_tz converted');
select is((select array_agg(id order by id) from public.era_tz where tableoid = :era_tz_oid), array[1, 2, 3]::bigint[],
  'B: rows 1, 2 and 3 are in the monolith, the BC one included');
select ok(not exists (select 1 from pg_constraint where conname = 'pgpm_monolith_bound'
                       and conrelid in ('public.era_tz'::regclass, :era_tz_oid::oid::regclass))
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.era_tz'::regclass),
  'B: no pgpm_monolith_bound and no claim are left behind');
select ok((select lo::timestamptz < '0001-01-01 00:00:00+00' and lo::timestamptz <= '0100-06-01 00:00:00+00 BC'
             from pgpm.part where parent_table = 'public.era_tz'::regclass and child_oid = :era_tz_oid),
  'B: the monolith''s recorded lo is before 1 AD, at or below the BC row');
select ok((select pg_get_expr(relpartbound, oid) like 'FOR VALUES FROM (''%BC'') TO (%'
             from pg_class where oid = :era_tz_oid),
  'B: the monolith''s partition bound starts in BC');
insert into public.era_tz values (4, '0100-12-01 00:00:00+00 BC');
select is((select array_agg(id order by id) from public.era_tz where tableoid = :era_tz_oid), array[1, 2, 3, 4]::bigint[],
  'B: a later BC write lands in the monolith too');

-- (C) naive date column, yearly grid
create table public.era_d (id bigint not null, d date not null, primary key (id, d));
insert into public.era_d values (1, date '0100-06-01 BC'), (2, current_date - 1);
select oid as era_d_oid from pg_class where oid = 'public.era_d'::regclass \gset
select is((select array_agg(id order by id) from public.era_d where d < date '0001-01-01'), array[1]::bigint[],
  'C LIVENESS: era_d''s oldest row (id 1) is before 1 AD, and only it');
call pgpm.transmute('public.era_d', 'd', interval '1 year', p_obtain => 1);
select is((select relkind::text from pg_class where oid = 'public.era_d'::regclass), 'p', 'C: era_d converted');
select is((select array_agg(id order by id) from public.era_d where tableoid = :era_d_oid), array[1, 2]::bigint[],
  'C: rows 1 and 2 are in the monolith, the BC one included');
select ok(not exists (select 1 from pg_constraint where conname = 'pgpm_monolith_bound'
                       and conrelid in ('public.era_d'::regclass, :era_d_oid::oid::regclass))
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.era_d'::regclass),
  'C: no pgpm_monolith_bound and no claim are left behind');

select * from finish();
