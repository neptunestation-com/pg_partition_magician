-- P1-01: PR #1293's body, CHANGELOG, docs/reference.md and the comment above the function all say
-- pgpm.check_time_monotonic carries a function-level SET timezone = 'UTC' so the %I::timestamptz cast never
-- takes the caller's zone. On this tree the function has no SET clause: the cast still runs in the session's
-- TimeZone, so a naive timestamp column with a wall time inside New York's spring-forward gap (02:30 on
-- 2026-03-08 reads as 03:30 EDT) is reordered, and the documented fraction of non-decreasing pairs changes
-- with who runs it. Asymmetric fixture: four rows, three pairs, exactly one falls (03:15 then 02:30), so the
-- right answer is (3,2,0.6667) from every zone and the defect's answer (3,3,1.0000) cannot be reached by a
-- compensating error.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

create table public.dip_p1 (id bigint primary key, t timestamp not null);
insert into public.dip_p1 values
  (1, '2026-03-08 01:00:00'), (2, '2026-03-08 03:15:00'), (3, '2026-03-08 02:30:00'), (4, '2026-03-08 04:00:00');

select is((select string_agg(id::text, ',' order by id) from public.dip_p1 d
            where t < (select t from public.dip_p1 p where p.id = d.id - 1)),
  '3', 'LIVENESS: the naive column falls at exactly one pair, into id 3 (03:15 then 02:30)');

set timezone = 'UTC';
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.dip_p1', 'id', 't')),
  '(3,2,0.6667)', 'LIVENESS: from a UTC session two of the three pairs are reported non-decreasing');

set timezone = 'America/New_York';
select is(current_setting('TimeZone'), 'America/New_York', 'LIVENESS: the session zone is America/New_York');
select ok((timestamp '2026-03-08 02:30:00')::timestamptz > (timestamp '2026-03-08 03:15:00')::timestamptz,
  'LIVENESS: in America/New_York 02:30 on 2026-03-08 is inside the spring-forward gap and casts past 03:15');

-- defect checks
select ok(exists (select 1 from pg_proc p, unnest(p.proconfig) c
                   where p.oid = 'pgpm.check_time_monotonic'::regproc and lower(c) = 'timezone=utc'),
  'check_time_monotonic carries the SET timezone = UTC clause the PR body and the function comment promise');
select is((select (sampled, monotonic, fraction)::text from pgpm.check_time_monotonic('public.dip_p1', 'id', 't')),
  '(3,2,0.6667)', 'from an America/New_York session the pair that falls across the gap still reads as falling');
select is((select string_agg(id::text, ',' order by id) from (
             select id, lag(t) over (order by id) as prev, t from public.dip_p1) x where prev is not null and t >= prev),
  '2,4', 'GUARD: the rows whose pair is non-decreasing are ids 2 and 4 (the column itself, zone-free)');

select * from finish();
