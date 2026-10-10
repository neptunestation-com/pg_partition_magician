-- An interval retain is non-negative FIELD BY FIELD, not under interval comparison (issue #565).
--
-- #451 refused a negative retain by comparing it with zero: `p_retain::interval >= interval '0'`. PostgreSQL
-- compares intervals on a 30-day-month, 360-day-year normalisation, but the horizon the check protects is
-- CALENDAR arithmetic: _retain_boundary takes the value off the wall clock in partition_tz, where a year is
-- 365 or 366 days and a month 28 to 31. So '-1 year 360 days' compared EQUAL to zero and was accepted, yet
-- now - it is five or six days in the future; the first maintenance tick write-blocked and dropped every
-- partition up to that horizon, the one taking writes included, and the rows written today went with it.
--
-- A mixed-sign interval has no calendar-independent sign: '-1 mon 30 days' puts the horizon a day in the
-- future from a 31-day month and two days in the past from February. So the rule is on the FIELDS PostgreSQL
-- keeps (months, days, time), each of which moves the wall clock back or leaves it: none may be negative.
-- That refuses a mixed-sign value that happens to net positive ('1 mon -1 day') as well; nobody means that
-- as a retention policy, and a refusal costs nothing at transmute or set_retain.
--
-- One function (_retain_nonnegative) is the rule for every entry point, so the three layers of #451 inherit
-- it; each is pinned here with the issue's own value:
--   (A) the rule itself, value by value, with a witness that every refused value passes the old comparison;
--   (B) transmute refuses before anything is committed, and the same call with a sane retain converts;
--   (C) set_retain refuses, including a value the would-drop guard alone accepts at the date this runs;
--   (D) a config.retain written by hand: the tick logs skip_write_block / skip_retain (exact actions) and
--       keeps every partition and every row, which is where pre-fix code shows the data loss.
--
-- WHICH ASSERTIONS DISCRIMINATE (the tests/83 caveat): the transmute in (B) runs inside throws_like's
-- function, so against pre-fix code it dies at phase 1's COMMIT with 2D000 and the message pin fails for
-- the right reason, but the untouched-table assertions after it pass pre-fix too; read them as the post-fix
-- contract. (D) is the proof: pre-fix, the tick drops the partition holding now().
create extension if not exists pgtap;
select plan(40);

-- ======================= (A) the rule, value by value =======================
-- Refused: at least one field negative. LIVENESS: every one of them passes the pre-#565 comparison, so a
-- green run here is the new rule refusing it, not the old one.
select ok(v >= interval '0', format('LIVENESS: %s passes the old interval comparison with zero', v))
  from unnest(array[interval '-1 year 360 days', interval '-1 mon 30 days', interval '1 mon -1 day',
                    interval '1 day -24 hours']) v;
select ok(not pgpm._retain_nonnegative('time', v::text), format('%s is refused: a field of it is negative', v))
  from unnest(array[interval '-1 year 360 days', interval '-1 mon 30 days', interval '1 mon -1 day',
                    interval '1 day -24 hours']) v;
-- the issue's value, concretely: its horizon is days in the future on the wall clock
select ok(((now() at time zone 'UTC') - interval '-1 year 360 days') > (now() at time zone 'UTC') + interval '4 days',
  'LIVENESS: now minus -1 year 360 days is more than four days in the FUTURE on the wall clock');
-- Still refused: the plainly negative values #451 was about.
select ok(not pgpm._retain_nonnegative('time', v), format('%s is still refused', v))
  from unnest(array['-1 day', '-00:00:01', '-1 year -1 mon']) v;
-- Accepted: every field non-negative, zero included (it keeps exactly the partition taking writes).
select ok(pgpm._retain_nonnegative('time', v), format('%s is accepted', v))
  from unnest(array['0', '1 year', '90 days', '36:00:00', '1 year 2 mons 3 days 04:05:06']) v;
-- id retain is a count, untouched by this
select ok(pgpm._retain_nonnegative('id', '0') and not pgpm._retain_nonnegative('id', '-1'),
  'id retain: 0 accepted, -1 refused, as before');

-- ======================= (B) transmute refuses up front =======================
create table public.rs131t (id bigint generated always as identity, ts timestamptz not null, payload text,
  primary key (id, ts));
insert into public.rs131t (ts, payload) values
  (now() - interval '5 days 1 hour', 'd5b'), (now() - interval '5 days', 'd5'), (now() - interval '3 days', 'd3');

select throws_like(
  $$ call pgpm.transmute('public.rs131t', 'ts', interval '1 day', p_retain => interval '-1 year 360 days', p_paused => false, p_obtain => 10) $$,
  '%p_retain cannot be negative%', 'transmute refuses -1 year 360 days with the pgpm message');
select is((select relkind::text from pg_class where oid = 'public.rs131t'::regclass), 'r',
  'the table is untouched');
select is((select count(*)::int from pgpm.config where parent_table = 'public.rs131t'::regclass), 0,
  'the table was not registered');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.rs131t'::regclass), 0,
  'no claim was recorded');

-- LIVENESS and positive control: the identical call with a sane retain converts.
call pgpm.transmute('public.rs131t', 'ts', interval '1 day', p_retain => interval '1 year', p_paused => false, p_obtain => 10);
select is((select relkind::text from pg_class where oid = 'public.rs131t'::regclass), 'p',
  'the same call with retain 1 year converts the table');
insert into public.rs131t (ts, payload) values (now() - interval '1 hour', 'h1'), (now(), 'written now');

select child_name as t_write from pgpm.part
  where parent_table = 'public.rs131t'::regclass and attached
    and not pgpm._native_gt('time', lo, now()::text) and pgpm._native_gt('time', hi, now()::text) \gset
select ok(:'t_write' is not null, 'fixture: a partition holds now(): ' || :'t_write');

-- ======================= (C) set_retain refuses =======================
select throws_like(
  $$ select pgpm.set_retain('public.rs131t', '-1 year 360 days') $$,
  '%p_retain cannot be negative%', 'set_retain refuses -1 year 360 days');
-- '-1 mon 30 days' is the value whose sign depends on the month: on many dates its horizon floors onto
-- the write partition's own floor, where the would-drop guard alone sees nothing newly eligible.
select throws_like(
  $$ select pgpm.set_retain('public.rs131t', '-1 mon 30 days') $$,
  '%p_retain cannot be negative%', 'set_retain refuses -1 mon 30 days, whatever month it is');
select is((select retain from pgpm.config where parent_table = 'public.rs131t'::regclass), '1 year',
  'the refused calls left config.retain untouched');
-- LIVENESS: set_retain itself works on this table
select lives_ok($$ select pgpm.set_retain('public.rs131t', '2 years') $$,
  'set_retain accepts 2 years on the same table');
select is((select retain from pgpm.config where parent_table = 'public.rs131t'::regclass), '2 years',
  'and config.retain says so');

-- ======================= (D) defence in depth: a config.retain written by hand =======================
create table pg_temp.before131 as
  select child_name, lo from pgpm.part where parent_table = 'public.rs131t'::regclass and attached;

-- LIVENESS: the value, were a horizon computed from it the #451 way, lands past the hi of the partition
-- holding now(), so every partition up to and including that one would be drop-eligible.
select ok(
  pgpm._native_gt('time',
    pgpm._grid_floor('time', '1 day', '2000-01-01 00:00:00+00',
      pgpm._ts_text(((now() at time zone 'UTC') - interval '-1 year 360 days') at time zone 'UTC'), 'UTC'),
    (select hi from pgpm.part where parent_table = 'public.rs131t'::regclass and child_name = :'t_write')),
  'LIVENESS: that horizon is past the hi of the partition taking writes');

update pgpm.config set retain = '-1 year 360 days' where parent_table = 'public.rs131t'::regclass;   -- THE HAND EDIT

select throws_like(
  $$ select pgpm._retain_boundary(c) from pgpm.config c where c.parent_table = 'public.rs131t'::regclass $$,
  '%config.retain -1 year 360 days on %rs131t is negative%',
  '_retain_boundary refuses to compute a horizon from it');

call pgpm.maintain('public.rs131t') \gset
select ok(:'p_status' like 'archived=0 dropped=0%write_block_deferred%retain_deferred%',
  'the tick deferred both the write-block and the retain step: ' || :'p_status');
select is(
  (select count(*)::int from pgpm.log
    where parent_table = 'public.rs131t'::regclass and action = 'skip_write_block' and method like '%is negative%'),
  1, 'skip_write_block was logged once, carrying the refusal');
select is(
  (select count(*)::int from pgpm.log
    where parent_table = 'public.rs131t'::regclass and action = 'skip_retain' and method like '%is negative%'),
  1, 'skip_retain was logged once, carrying the refusal');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.rs131t'::regclass and action = 'retain_drop'),
  0, 'nothing was dropped');
select is(
  (select array_agg(child_name order by lo::timestamptz) from pgpm.part
    where parent_table = 'public.rs131t'::regclass and attached),
  (select array_agg(child_name order by lo::timestamptz) from pg_temp.before131),
  'every partition attached before the tick is attached after it, by name');
select ok(to_regclass(format('public.%I', :'t_write')) is not null,
  'the partition holding now() still exists');
select is((select array_agg(payload order by ts) from public.rs131t),
  array['d5b', 'd5', 'd3', 'h1', 'written now'],
  'every row is still there, the ones written an hour ago and just now included');

-- POSITIVE CONTROL: the same table and tick with a sane value logs no further skip.
update pgpm.config set retain = '1 year' where parent_table = 'public.rs131t'::regclass;
call pgpm.maintain('public.rs131t') \gset
select ok(:'p_status' like 'archived=0 dropped=0%' and :'p_status' not like '%deferred%',
  'with retain 1 year the tick defers nothing: ' || :'p_status');
select is(
  (select count(*)::int from pgpm.log
    where parent_table = 'public.rs131t'::regclass and action in ('skip_write_block', 'skip_retain')),
  2, 'no further skip was logged: the two from the refused tick are the only ones');

select * from finish();
