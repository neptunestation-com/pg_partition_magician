-- Issue #674: set_regrain refuses a target step the grid cannot place, a month count mixed with a
-- duration, at call time and at every other regrain entry point.
--
-- set_regrain judged a target only through _grid_next (the #588 "moves the grid forward" test and the #341
-- width comparison), and _grid_next's calendar branch keeps the month count and drops the rest of the
-- interval. So '1 month 1 day', '1 month -40 days' (below zero by PostgreSQL's own interval ordering) and
-- '-1 month 40 days' all passed and were stored, while _grid_floor raises 'mixed month + duration interval
-- unsupported' on each of them: once a coarse child froze, every maintain tick's regrain_step failed and
-- logged skip_regrain, the every-tick wedge the call-time refusals exist for. transmute refuses the same
-- shape as a partition_step. The fix gives regrain the rules transmute's preflight applies to a
-- partition_step (_regrain_step_shape, called from _regrain_step_forward), which also refuses a step
-- finer than a day on a date column, transmute's #581 rule.
--
-- Every refusal is pinned to its message and paired with a liveness witness that the same entry point
-- accepts a valid step on the same table; the state a refused call must leave is an asymmetric one (a
-- VALID target already set, not null); and the ticks at the end run with a frozen coarse child present,
-- so "no skip_regrain" is paired with the regrain work those ticks did. bench/regrain_target_shape.sh
-- runs this file against the mutants regrain_step_mixed_month_duration and regrain_step_date_subday.
set timezone = 'UTC';
create extension if not exists pgtap;
select plan(19);

-- ============================ a monthly grid with a frozen coarse child ============================
-- A ULID text_time table (the fixture of the issue's verified reproduction and of tests/125): a time
-- grid whose frontier follows the data, so one write three months ahead freezes the monolith behind it.
create table public.mxs (id text collate "C" primary key, payload text);
insert into public.mxs
  select pgpm._ts_to_text_time(d, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') || substr(upper(md5(d::text)), 1, 16), 'day'
    from generate_series('2024-01-01 12:00+00'::timestamptz, '2024-06-30 12:00+00'::timestamptz, interval '1 day') d;
call pgpm.transmute('public.mxs', 'id', interval '1 month', p_paused => false,
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
insert into public.mxs values (
  pgpm._ts_to_text_time(date_trunc('month', now()) + interval '3 months 1 day', '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') || 'FFFFFFFFFFFFFFFF',
  'frontier');
select cmp_ok((select coarse_frozen from pgpm.progress('public.mxs')), '>', 0::bigint,
  'LIVENESS: there is a frozen coarse child for auto-regrain to select');
select throws_like(
  $$ select pgpm._grid_floor('time', '1 month 1 day', '2000-01-01 00:00:00+00', '2024-03-05 00:00:00+00', 'UTC') $$,
  '%mixed month + duration interval unsupported%',
  'LIVENESS: _grid_floor, which regrain_step calls with the target step, cannot place ''1 month 1 day''');
select ok(interval '1 month -40 days' < interval '0',
  'LIVENESS: ''1 month -40 days'' is below zero by PostgreSQL interval ordering');

select lives_ok($$ select pgpm.set_regrain('public.mxs', '1 day') $$,
  'LIVENESS: set_regrain accepts a valid finer fixed step (1 day)');
select throws_like($$ select pgpm.set_regrain('public.mxs', '1 month 1 day') $$,
  'pg_partition_magician: regrain target step 1 month 1 day for mxs mixes a month count with a duration%',
  'set_regrain refuses a month count mixed with a positive duration');
select throws_like($$ select pgpm.set_regrain('public.mxs', '1 month -40 days') $$,
  'pg_partition_magician: regrain target step 1 month -40 days for mxs mixes a month count with a duration%',
  'set_regrain refuses a month count mixed with a negative duration (below zero by interval ordering)');
select throws_like($$ select pgpm.set_regrain('public.mxs', '-1 month 40 days') $$,
  'pg_partition_magician: regrain target step -1 month 40 days for mxs mixes a month count with a duration%',
  'set_regrain refuses a negative month count mixed with a duration');
select is((select regrain_to from pgpm.config where parent_table = 'public.mxs'::regclass), '1 day',
  'the refused calls left the valid target in place');
select lives_ok($$ select pgpm.set_regrain('public.mxs', '1 year -11 months') $$,
  'LIVENESS: a pure calendar step written with two fields (1 year -11 months = 1 month) is still accepted');
select is((select regrain_to from pgpm.config where parent_table = 'public.mxs'::regclass), '1 year -11 months',
  'LIVENESS: and it is the target recorded');

-- the operator-driven entry points go through the same check
select throws_like(
  format($$ select pgpm.regrain_step('public.mxs', %L, '1 month 1 day') $$,
         (select child_name from pgpm.part where parent_table = 'public.mxs'::regclass and attached
           order by lo limit 1)),
  'pg_partition_magician: regrain target step 1 month 1 day for mxs mixes a month count with a duration%',
  'regrain_step refuses the mixed step before it reads or mutates anything');
select is((select count(*) from pgpm.part where parent_table = 'public.mxs'::regclass and not attached), 0::bigint,
  'the refusal minted no fine child');

-- the ticks, with a valid target recorded: they do regrain work and none wedges on the grid arithmetic
select lives_ok($$ select pgpm.set_regrain('public.mxs', '1 day') $$, 'fixture: the daily target again');
set client_min_messages = warning;
call pgpm.maintain('public.mxs');
call pgpm.maintain('public.mxs');
reset client_min_messages;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.mxs'::regclass and action = 'regrain_prepare'),
  'LIVENESS: the ticks reached regrain_step and prepared the frozen coarse child');
select is((select count(*) from pgpm.log where parent_table = 'public.mxs'::regclass and action = 'skip_regrain'), 0::bigint,
  'no tick logged skip_regrain');

-- ================ a date column: a step finer than a day is refused, as transmute refuses it ================
create table public.mxd (d date primary key, payload text);
insert into public.mxd select dd::date, 'd' from generate_series(date '2024-01-01', date '2024-03-31', interval '1 day') dd;
call pgpm.transmute('public.mxd', 'd', interval '1 month', p_obtain => 2);
select lives_ok($$ select pgpm.set_regrain('public.mxd', '1 day') $$,
  'LIVENESS: set_regrain accepts a whole-day step on a date column');
select throws_like($$ select pgpm.set_regrain('public.mxd', '12 hours') $$,
  'pg_partition_magician: regrain target step 12 hours for mxd is not a whole number of days, but its control column d is a date%',
  'set_regrain refuses a sub-day step on a date column');
select throws_like($$ select pgpm.set_regrain('public.mxd', '36 hours') $$,
  'pg_partition_magician: regrain target step 36 hours for mxd is not a whole number of days, but its control column d is a date%',
  'set_regrain refuses a step of more than a day that is not a whole number of days');
select is((select regrain_to from pgpm.config where parent_table = 'public.mxd'::regclass), '1 day',
  'the refused calls left the valid date target in place');

select * from finish();
