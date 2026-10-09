-- The retain horizon is never later than now() minus the retain's time part, through a fall-back hour too
-- (issue #627).
--
-- THE BUG. _retain_boundary, and its twin in regrain_step, computed the horizon as
--   ((now() at time zone partition_tz) - retain) at time zone partition_tz
-- the wall clock in partition_tz, minus retain, converted back to an instant. PostgreSQL resolves an
-- ambiguous wall time (the repeated hour of a fall-back) to its LATER instant. At 05:30Z on 2026-11-01, which
-- is 01:30 EDT in America/New_York, the FIRST pass through the repeated hour, retain '0' (documented: "zero
-- keeps only the partition taking writes") gave 06:30Z, an hour past now(); on an hourly grid that floors to
-- 06:00Z, and retain() judged the partition taking writes, [05:00Z, 06:00Z), aged (hi <= horizon) and dropped
-- it with its rows. retain '30 minutes' gave 06:00Z there too. regrain_step discarded the same sub-range as
-- aged at the swap, and a table whose frontier runs ahead of the clock (uuidv7) lost its rows that way.
--
-- THE RULE. A retain's CALENDAR part (months and days: date_trunc('day', retain)) is calendar arithmetic on
-- the wall clock in partition_tz (#455), so '1 day' is the same wall time yesterday, 23 or 25 hours across a
-- transition. Its TIME part (hours, minutes, seconds) is fixed-length and is subtracted from the instant. With
-- no calendar part there is no wall-clock round trip at all. A wall time a day or more back that is itself
-- ambiguous resolves to its later instant, PostgreSQL's rule, which is in the past either way.
--
-- THE CONTRACT, by identity, on an instrumented clock (a clk.now() shim ahead of pg_catalog in search_path,
-- which the horizon's unqualified now() resolves to):
--   PART A  the issue's own case: retain '0', hourly, at 01:30 EDT on the first pass. retain() drops the aged
--           row and keeps both rows of the partition taking writes, and the table still takes a write.
--   PART B  five clocks (the first and the second pass through the repeated hour, a spring-forward morning, a
--           plain day, and the morning after the fall-back) x four retains ('0', '30 minutes', '1 day',
--           '1 day 30 minutes') x two grids (hourly, daily): the horizon is exactly the rule's value, never
--           later than now() minus the time part, and retain() keeps exactly the two rows at and above it.
--   PART C  regrain_step's horizon, the twin: a uuidv7 table whose frontier runs ahead of the clock regrains
--           its monolith at 01:30 EDT on the first pass with retain '0'; only the sub-range below the hour
--           taking writes is skipped as aged, and the rows of that hour survive the swap.
--
-- ASYMMETRIC FIXTURES. Every table holds three rows: one just below the expected horizon (dropped) and two
-- at and above it (kept), so a horizon an hour late, an hour early or a step off cannot keep the same set.
create extension if not exists pgtap;
set client_min_messages = warning;

create schema clk;
create function clk.now() returns timestamptz language sql stable
  as $$ select current_setting('clk.now')::timestamptz $$;
set search_path = clk, pg_catalog, public;

select plan(140);

-- ==================== PART A: the issue's case ====================
set timezone = 'America/New_York';      -- transmute records the session's zone as partition_tz
set clk.now = '2026-11-01 04:30:00+00';
create table a311 (id int, ts timestamptz not null, tag text, primary key (id, ts));
call pgpm.transmute('a311', 'ts', interval '1 hour', p_obtain => 4, p_retain => interval '0');
insert into a311 values (1, '2026-11-01 04:10:00+00', 'aged'),
                        (2, '2026-11-01 05:10:00+00', 'live1'),
                        (3, '2026-11-01 05:25:00+00', 'live2');
set clk.now = '2026-11-01 05:30:00+00';
set timezone = 'UTC';

select is(now(), '2026-11-01 05:30:00+00'::timestamptz,
  'LIVENESS: the clk.now() shim is what an unqualified now() resolves to');
select is(to_char(now() at time zone 'America/New_York', 'HH24:MI') || ' '
          || to_char((now() at time zone 'America/New_York') - (now() at time zone 'UTC'), 'HH24:MI'),
          '01:30 -04:00',
  'LIVENESS: the clock reads 01:30 EDT (offset -04), the first pass through the repeated hour');
select is(('2026-11-01 01:30:00'::timestamp at time zone 'America/New_York'), '2026-11-01 06:30:00+00'::timestamptz,
  'LIVENESS: that wall time converts back to 06:30Z, an hour past now(): the premise of the defect');
select is((select partition_tz || ' ' || retain from pgpm.config where parent_table = 'a311'::regclass),
  'America/New_York 00:00:00', 'fixture: partition_tz America/New_York, retain 0');
select is((select array_agg(tag order by id) from a311 where tableoid = 'a311_p2026_11_01_05'::regclass),
  array['live1', 'live2'], 'fixture: the live rows sit in a311_p2026_11_01_05 = [05:00Z, 06:00Z), the partition taking writes');

select is((select pgpm._retain_boundary(c) from pgpm.config c where parent_table = 'a311'::regclass)::timestamptz,
  '2026-11-01 05:00:00+00'::timestamptz, 'A: the horizon is the floor of the hour taking writes, 05:00Z');
select cmp_ok(pgpm.retain('a311'), '>=', 1, 'LIVENESS: retain() ran and dropped something');
select is((select array_agg(tag order by id) from a311), array['live1', 'live2'],
  'A: retain 0 drops the aged row and keeps exactly the two rows of the partition taking writes');
select ok(to_regclass('a311_p2026_11_01_05') is not null and to_regclass('a311_p2026_11_01_04') is null,
  'A: a311_p2026_11_01_05 (taking writes) still exists and a311_p2026_11_01_04 (aged) is gone');
select lives_ok($$ insert into a311 values (4, '2026-11-01 05:29:00+00', 'written after') $$,
  'A: the table still takes a write at now()');

-- ==================== PART B: the matrix ====================
-- clk, now, retain, step, and the rule's raw horizon, worked by hand in America/New_York:
--   A  05:30Z Nov 1 = 01:30 EDT (first pass)   B  06:30Z Nov 1 = 01:30 EST (second pass)
--   C  07:30Z Mar 8 = 03:30 EDT (an hour after spring-forward)   D  16:30Z Oct 15 = 12:30 EDT (a plain day)
--   E  06:30Z Nov 2 = 01:30 EST (the day after; '1 day' back reads the AMBIGUOUS 01:30 of Nov 1, and resolves
--      to its later instant, 06:30Z, PostgreSQL's rule; the earlier one, 05:30Z, would be just as past)
-- '1 day' at B is 25 hours back (Oct 31 01:30 EDT) and at C 23 hours back (Mar 7 03:30 EST): calendar days.
create temp table m311 (k text primary key, clk timestamptz, retain interval, step interval, raw timestamptz);
insert into m311
select c.k || '_' || r.k || '_' || s.k, c.clk, r.retain, s.step, x.raw
  from (values ('a', '2026-11-01 05:30:00+00'::timestamptz), ('b', '2026-11-01 06:30:00+00'),
               ('c', '2026-03-08 07:30:00+00'), ('d', '2026-10-15 16:30:00+00'),
               ('e', '2026-11-02 06:30:00+00')) c(k, clk)
 cross join (values ('r0', interval '0'), ('r30m', interval '30 minutes'), ('r1d', interval '1 day'),
                    ('r1d30m', interval '1 day 30 minutes')) r(k, retain)
 cross join (values ('h', interval '1 hour'), ('d', interval '1 day')) s(k, step)
 join (values
   ('a', 'r0', '2026-11-01 05:30:00+00'::timestamptz), ('a', 'r30m', '2026-11-01 05:00:00+00'),
   ('a', 'r1d', '2026-10-31 05:30:00+00'), ('a', 'r1d30m', '2026-10-31 05:00:00+00'),
   ('b', 'r0', '2026-11-01 06:30:00+00'), ('b', 'r30m', '2026-11-01 06:00:00+00'),
   ('b', 'r1d', '2026-10-31 05:30:00+00'), ('b', 'r1d30m', '2026-10-31 05:00:00+00'),
   ('c', 'r0', '2026-03-08 07:30:00+00'), ('c', 'r30m', '2026-03-08 07:00:00+00'),
   ('c', 'r1d', '2026-03-07 08:30:00+00'), ('c', 'r1d30m', '2026-03-07 08:00:00+00'),
   ('d', 'r0', '2026-10-15 16:30:00+00'), ('d', 'r30m', '2026-10-15 16:00:00+00'),
   ('d', 'r1d', '2026-10-14 16:30:00+00'), ('d', 'r1d30m', '2026-10-14 16:00:00+00'),
   ('e', 'r0', '2026-11-02 06:30:00+00'), ('e', 'r30m', '2026-11-02 06:00:00+00'),
   ('e', 'r1d', '2026-11-01 06:30:00+00'), ('e', 'r1d30m', '2026-11-01 06:00:00+00')
 ) x(ck, rk, raw) on x.ck = c.k and x.rk = r.k;

-- The grid is a fixed lattice of whole steps from the anchor transmute records. Read it from a probe table
-- rather than assume it, then floor each raw horizon onto it with plain epoch arithmetic (no pgpm function).
set timezone = 'America/New_York';
set clk.now = '2026-10-01 12:00:00+00';
create table probe311h (ts timestamptz not null);
create table probe311d (ts timestamptz not null);
call pgpm.transmute('probe311h', 'ts', interval '1 hour', p_obtain => 1);
call pgpm.transmute('probe311d', 'ts', interval '1 day', p_obtain => 1);
create temp table anchor311 as
  select (select partition_anchor::timestamptz from pgpm.config where parent_table = 'probe311h'::regclass) as h,
         (select partition_anchor::timestamptz from pgpm.config where parent_table = 'probe311d'::regclass) as d;
alter table m311 add column bound timestamptz;
update m311 set bound = a.anc + make_interval(secs => floor(extract(epoch from (raw - a.anc)) / extract(epoch from step)) * extract(epoch from step))
  from (select h as anc, interval '1 hour' as st from anchor311 union all select d, interval '1 day' from anchor311) a
 where a.st = m311.step;
select is((select count(*)::int from m311 where bound is not null and raw is not null), 40,
  'fixture: 40 cases, each with its hand-worked horizon and its floor on the grid');

-- One table per case, transmuted empty at the clock of the aged row so the grid covers it, with a lookahead
-- that reaches past now(); then three rows: aged (a minute below the floor), edge (a minute above it), live
-- (a minute before now()).
select format('set clk.now = %L', bound - interval '1 minute'),
       format('create table %I (id int, ts timestamptz not null, tag text, primary key (id, ts))', 'm311_' || k),
       format('call pgpm.transmute(%L, %L, %L::interval, p_obtain => %s, p_retain => %L::interval)',
              'm311_' || k, 'ts', step,
              ceil(extract(epoch from (clk - bound)) / extract(epoch from step))::int + 2, retain),
       format('insert into %I values (1, %L, %L), (2, %L, %L), (3, %L, %L)', 'm311_' || k,
              bound - interval '1 minute', 'aged', bound + interval '1 minute', 'edge',
              clk - interval '1 minute', 'live')
  from m311 order by k \gexec

-- Retention runs at each case's clock, in a UTC session: the horizon is partition_tz's business.
set timezone = 'UTC';
create temp table r311 (k text primary key, boundary timestamptz, dropped int);
select format('set clk.now = %L', clk),
       format('insert into r311 select %L, (select pgpm._retain_boundary(c) from pgpm.config c where parent_table = %L::regclass)::timestamptz, pgpm.retain(%L)',
              k, 'm311_' || k, 'm311_' || k)
  from m311 order by k \gexec
set clk.now = '2026-11-01 05:30:00+00';

select is((select count(*)::int from r311 where dropped >= 1), 40,
  'LIVENESS: retain() dropped at least one partition in every one of the 40 cases');

select is(r.boundary, m.bound, format('B %s: the horizon is %s', m.k, m.bound))
  from m311 m left join r311 r using (k) order by m.k;

select ok(r.boundary <= m.clk - (m.retain - date_trunc('day', m.retain)),
          format('B %s: the horizon is not later than now() minus the time part', m.k))
  from m311 m left join r311 r using (k) order by m.k;

select format('select is((select array_agg(tag order by id) from %I), array[%L, %L], %L)',
              'm311_' || k, 'edge', 'live', format('B %s: retain() keeps exactly the edge and live rows', k))
  from m311 order by k \gexec

-- ==================== PART C: regrain_step's horizon ====================
-- A uuidv7 table's frontier is greatest(max(control), now()), so rows minted ahead of the clock let a monolith
-- that spans the hour taking writes be frozen and regrained. retain '0' on an hourly target grid at 01:30 EDT
-- on the first pass: the horizon is 05:00Z, so [04:00Z, 05:00Z) is the only sub-range skipped as aged.
set timezone = 'America/New_York';
set clk.now = '2026-11-01 05:20:00+00';
create table c311 (id uuid primary key, tag text);
insert into c311 values (pgpm._ts_to_uuid('2026-11-01 04:10:00+00'), 'aged'),
                        (pgpm._ts_to_uuid('2026-11-01 05:10:00+00'), 'live1'),
                        (pgpm._ts_to_uuid('2026-11-01 05:15:00+00'), 'live2'),
                        (pgpm._ts_to_uuid('2026-11-01 06:10:00+00'), 'ahead1');
call pgpm.transmute('c311', 'id', interval '1 hour', p_obtain => 2, p_retain => interval '0');
insert into c311 values (pgpm._ts_to_uuid('2026-11-01 07:10:00+00'), 'ahead2');
set clk.now = '2026-11-01 05:30:00+00';
set timezone = 'UTC';

select child_name as cmono from pgpm.part where parent_table = 'c311'::regclass and attached order by lo limit 1 \gset
select is(:'cmono'::text, 'c311_p2026_11_01_04_to_2026_11_01_07',
  'fixture: the monolith spans [04:00Z, 07:00Z), the hour taking writes included');
select is((select array_agg(tag order by id) from c311 where tableoid = :'cmono'::regclass),
  array['aged', 'live1', 'live2', 'ahead1'], 'fixture: the monolith holds aged, live1, live2 and ahead1');

-- ticks until the swap, each one's status kept, so a run that swaps early is read rather than dying on the
-- next tick's "not an attached managed partition"
create temp table ticks311 (n int primary key, status text);
do $$
declare v text; i int := 0;
begin
  loop
    i := i + 1;
    v := pgpm.regrain_step('c311', 'c311_p2026_11_01_04_to_2026_11_01_07', '1 hour');
    insert into ticks311 values (i, v);
    exit when v like 'swapped:%' or i >= 10;
  end loop;
end $$;
select ok(exists (select 1 from ticks311 where status like 'swapped:%'), 'LIVENESS: the regrain reached its swap');
select is((select array_agg(status order by n) from ticks311), array['prepared', 'copied:2', 'copied:1', 'swapped:2'],
  'C: prepared, then [04:00Z, 05:00Z) skipped as aged and the two rows of the hour taking writes copied, then ahead1, then the swap');
select is((select array_agg(lo::timestamptz order by lo::timestamptz) from pgpm.log
            where parent_table = 'c311'::regclass and action = 'regrain_aged'),
  array['2026-11-01 04:00:00+00'::timestamptz],
  'C: exactly one sub-range was skipped as aged, the one starting at 04:00Z');
select is((select array_agg(tag order by id) from c311), array['live1', 'live2', 'ahead1', 'ahead2'],
  'C: after the swap the aged row is gone and live1, live2, ahead1 and ahead2 remain');
select is((select array_agg(tag order by id) from c311 where tableoid = to_regclass('c311_p2026_11_01_05')),
  array['live1', 'live2'], 'C: the hour taking writes is its own partition, c311_p2026_11_01_05, holding live1 and live2');
select lives_ok($$ insert into c311 values (pgpm._ts_to_uuid('2026-11-01 05:29:00+00'), 'written after') $$,
  'C: the table still takes a write at now()');

select * from finish();
