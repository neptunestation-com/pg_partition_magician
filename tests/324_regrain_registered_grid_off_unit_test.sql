-- Issue #1117 and #1139 bullet 1: a time grid an older install registered off its control column's unit or
-- clock is refused at regrain before anything is copied, the upgrade says so, and the remedy each names is
-- said with the one-way door it has.
--
-- transmute holds a time grid's anchor and step to what the control column keeps (#1039 for a timestamp(p)
-- key, #769 for a date), but an install before those registered what it was given: a timestamptz(0) key
-- anchored 0.4 s off the second, a date key anchored at 12:00 UTC. _regrain_step_shape asked the unit rule
-- of the regrain TARGET only, "the anchor is the registered one, which transmute already held to it", so a
-- regrain of such a grid was accepted, prepared and copied, and every swap then failed (a fine range that a
-- date reads as empty, or a row outside the whole-second bounds ATTACH attached), leaving the copies, the
-- capture trigger and the TRUNCATE refusal on the source until regrain_cancel. Now the registered anchor and
-- step are asked too, at every entry point (set_regrain, regrain_step, regrain(), the tick's auto-regrain),
-- and re-running install.sql (the upgrade) logs each such grid once as warn_grid_off_unit with its remedy.
-- The registered ZONE is asked too (per-PR verification V-01): a naive (date, timestamp) key that an install
-- before #504 recorded in the converting session's zone sits at that zone's midnight, off the column's own
-- clock, so a fixed target (days, hours) is refused there while a whole-month one round-trips and is not.
-- And the remedy (per-PR verification P1-02, the text #1039's encoded-unit refusal shares): untransmute only
-- hands a table back while every row is in its monolith, so each message says what to do past that.
--
-- The older installs' registrations are planted in pgpm.config by hand, the state each left (the issue's
-- reproductions load the real older install; bench/regrain_registered_grid_off_unit.sh runs this file).
--   d324  date key, anchor planted at 12:00 UTC                    -> refused, flagged
--   t324  timestamptz(0) key, anchor planted 0.4 s off the second  -> refused, flagged (its column renamed)
--   s324  timestamptz(0) key, step planted at 1.5 s                -> refused, flagged (the step clause alone)
--   c324  date key, midnight anchor                                -> the same regrain completes (LIVENESS)
--   k324  timestamptz(0) key, whole-second anchor                  -> the same regrain completes (LIVENESS)
--   u324  unconstrained timestamptz, anchor 0.4 s (transmute accepts it today: the column keeps microseconds)
--                                                                  -> accepted, not flagged
--   z324  date key, 3-month step, zone planted America/New_York    -> a day refused, a month accepted, flagged
--   w324  naive timestamp key, zone planted Europe/London          -> an hour refused, flagged
--   e324  date key, zone planted Etc/UTC (UTC by another name)     -> the same day regrain completes, not flagged
--   y324  uuidv7 key, anchor planted 0.5 ms off, a row past its monolith
--                                                                  -> #1039's refusal names the door; untransmute
--                                                                     refuses it, as the message now says it can
-- The monoliths are frozen on an instrumented clock (a shim now() ahead of pg_catalog in search_path,
-- tests/311's technique). install.sql is read with \ir, relative to this file; the psql variable `install`
-- overrides the path.
\if :{?install}
\else
\set install ../pgpm_core/install.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
create schema clk324;
create table clk324.clock (t timestamptz);
insert into clk324.clock values ('2024-10-15 00:00:00+00');
create function clk324.now() returns timestamptz language sql stable as $$ select t from clk324.clock $$;
set search_path = clk324, pg_catalog, public;
select plan(36);

-- ============ six time grids, each with a frozen monolith over [2024-08-01, 2024-11-01) ============
create table public.d324 (id bigint, dt date not null, primary key (id, dt));
insert into public.d324 select g, date '2024-08-01' + (g % 60) from generate_series(1, 120) g;
create table public.c324 (id bigint, dt date not null, primary key (id, dt));
insert into public.c324 select g, date '2024-08-01' + (g % 50) from generate_series(1, 70) g;
create table public.t324 (id bigint, ts timestamptz(0) not null, primary key (id, ts));
insert into public.t324 select g, timestamptz '2024-08-01 00:00:00+00' + (g % 60) * interval '1 day' + interval '7 seconds'
  from generate_series(1, 90) g;
create table public.k324 (id bigint, ts timestamptz(0) not null, primary key (id, ts));
insert into public.k324 select g, timestamptz '2024-08-01 00:00:00+00' + (g % 40) * interval '1 day' + interval '7 seconds'
  from generate_series(1, 50) g;
create table public.s324 (id bigint, ts timestamptz(0) not null, primary key (id, ts));
insert into public.s324 select g, timestamptz '2024-08-01 00:00:00+00' + (g % 30) * interval '1 day'
  from generate_series(1, 40) g;
create table public.z324 (id bigint, dt date not null, primary key (id, dt));
insert into public.z324 select g, date '2024-08-01' + (g % 45) from generate_series(1, 55) g;
create table public.w324 (id bigint, ts timestamp not null, primary key (id, ts));
insert into public.w324 select g, timestamp '2024-08-01 00:00:00' + (g % 35) * interval '1 day' from generate_series(1, 45) g;
create table public.e324 (id bigint, dt date not null, primary key (id, dt));
insert into public.e324 select g, date '2024-08-01' + (g % 25) from generate_series(1, 33) g;
create table public.y324 (id bigint, k uuid not null, primary key (id, k));
insert into public.y324 select g, pgpm._ts_to_uuid(timestamptz '2024-08-01' + make_interval(hours => g * 11))
  from generate_series(1, 60) g;
create table public.u324 (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.u324 select g, timestamptz '2024-08-01 00:00:00+00' + (g % 20) * interval '1 day'
  from generate_series(1, 30) g;
call pgpm.transmute('public.d324', 'dt', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.c324', 'dt', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.t324', 'ts', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.k324', 'ts', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.s324', 'ts', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.u324', 'ts', interval '1 month', p_obtain => 1, p_anchor => '2000-01-01 00:00:00.4+00');
call pgpm.transmute('public.z324', 'dt', interval '3 months', p_obtain => 1);
call pgpm.transmute('public.w324', 'ts', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.e324', 'dt', interval '1 month', p_obtain => 1);
call pgpm.transmute('public.y324', 'k', interval '1 month', p_obtain => 2);
-- a row past y324's monolith, in its newest forward partition: the state that makes untransmute a one-way door
insert into public.y324
  select 9001, pgpm._ts_to_uuid(p.lo::timestamptz + interval '4 days') from pgpm.part p
   where p.parent_table = 'public.y324'::regclass and p.attached
     and p.child_oid <> (select monolith_oid from pgpm.config where parent_table = 'public.y324'::regclass)
   order by p.lo::timestamptz desc limit 1;
update clk324.clock set t = '2025-03-15 00:00:00+00';
-- the older installs' registrations (transmute refuses each of these today)
update pgpm.config set partition_anchor = '2000-01-01 12:00:00+00' where parent_table = 'public.d324'::regclass;
update pgpm.config set partition_anchor = '2000-01-01 00:00:00.4+00' where parent_table = 'public.t324'::regclass;
update pgpm.config set partition_step = '00:00:01.5' where parent_table = 'public.s324'::regclass;
-- an install before #504 recorded the converting session's zone for a naive key (Etc/UTC is UTC by another name)
update pgpm.config set partition_tz = 'America/New_York' where parent_table = 'public.z324'::regclass;
update pgpm.config set partition_tz = 'Europe/London' where parent_table = 'public.w324'::regclass;
update pgpm.config set partition_tz = 'Etc/UTC' where parent_table = 'public.e324'::regclass;
-- an install before _uuidv7_unit_contract accepted an anchor half a millisecond off
update pgpm.config set partition_anchor = '2000-01-01 00:00:00.0005+00' where parent_table = 'public.y324'::regclass;

create function pg_temp.attempt(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return 'completed';
exception when others then return sqlstate || ' ' || sqlerrm; end; $f$;
-- the copies a run left, the capture trigger on any child, and the cursor: what a refusal must not leave
create function pg_temp.run_marks(p_parent regclass) returns text language sql as $f$
  select (select count(*) from pgpm.part where parent_table = p_parent and not attached)::text || ' copies/'
      || (select count(*) from pg_trigger t join pg_inherits i on i.inhrelid = t.tgrelid
           where i.inhparent = p_parent and t.tgname = 'pgpm_regrain_capture')::text || ' captures/'
      || coalesce((select regrain_cursor from pgpm.config where parent_table = p_parent), 'no cursor')
$f$;

select child_name as d_mono from pgpm.part where parent_table = 'public.d324'::regclass and lo = '2024-08-01 00:00:00+00' \gset
select child_name as c_mono from pgpm.part where parent_table = 'public.c324'::regclass and lo = '2024-08-01 00:00:00+00' \gset
select child_name as t_mono from pgpm.part where parent_table = 'public.t324'::regclass and lo = '2024-08-01 00:00:00+00' \gset
select child_name as k_mono from pgpm.part where parent_table = 'public.k324'::regclass and lo = '2024-08-01 00:00:00+00' \gset
select child_name as s_mono from pgpm.part where parent_table = 'public.s324'::regclass and lo = '2024-08-01 00:00:00+00' \gset
select child_name as z_mono from pgpm.part where parent_table = 'public.z324'::regclass and lo = '2024-07-01 00:00:00+00' \gset
select child_name as e_mono from pgpm.part where parent_table = 'public.e324'::regclass and lo = '2024-08-01 00:00:00+00' \gset

select is((select string_agg(c.parent_table::text || '=' || c.partition_anchor || '/' || c.partition_step, ', '
                             order by c.parent_table::text)
             from pgpm.config c where c.parent_table::text in ('c324', 'd324', 'k324', 's324', 't324', 'u324')),
  'c324=2000-01-01 00:00:00+00/1 mon, d324=2000-01-01 12:00:00+00/1 mon, k324=2000-01-01 00:00:00+00/1 mon, '
  || 's324=2000-01-01 00:00:00+00/00:00:01.5, t324=2000-01-01 00:00:00.4+00/1 mon, u324=2000-01-01 00:00:00.4+00/1 mon',
  'LIVENESS: the six grids are registered as planted: d324 at noon, t324 0.4 s off, s324 at 1.5 s, u324 0.4 s off on its own');
select is((select string_agg(c.parent_table::text || '=' || c.partition_tz || '/' || c.partition_anchor || '/' || c.partition_step, ', '
                             order by c.parent_table::text)
             from pgpm.config c where c.parent_table::text in ('e324', 'w324', 'y324', 'z324')),
  'e324=Etc/UTC/2000-01-01 00:00:00+00/1 mon, w324=Europe/London/2000-01-01 00:00:00+00/1 mon, '
  || 'y324=UTC/2000-01-01 00:00:00.0005+00/1 mon, z324=America/New_York/2000-01-01 00:00:00+00/3 mons',
  'LIVENESS: z324, w324 and e324 carry the planted zones with an on-unit anchor and step, y324 its half-millisecond anchor');
select ok(:'d_mono' = 'd324_p2024_08_to_2024_11' and :'t_mono' = 't324_p2024_08_to_2024_11' and :'s_mono' = 's324_p2024_08_to_2024_11'
          and (select coarse_frozen from pgpm.progress('public.d324')) > 0
          and (select coarse_frozen from pgpm.progress('public.t324')) > 0
          and (select coarse_frozen from pgpm.progress('public.s324')) > 0,
  'LIVENESS: d324, t324 and s324 each have a frozen coarse monolith [2024-08-01, 2024-11-01) for a regrain to pick');

-- ============ the liveness of the run itself: the same regrain on an on-unit grid completes ============
select is(pg_temp.attempt(format('select pgpm.regrain(%L, %L, %L)', 'public.c324', :'c_mono', '1 day')), 'completed',
  'LIVENESS: c324 (a date key, midnight anchor) regrains its monolith to 1 day');
select is(pg_temp.attempt(format('select pgpm.regrain(%L, %L, %L)', 'public.k324', :'k_mono', '1 day')), 'completed',
  'LIVENESS: k324 (a timestamptz(0) key, whole-second anchor) regrains its monolith to 1 day');
select is((select string_agg(format('%s@%s', p.child_name, (select count(*) from public.k324 r where r.tableoid = p.child_oid)), ',' order by p.lo)
             from pgpm.part p where p.parent_table = 'public.k324'::regclass and p.lo in ('2024-08-01 00:00:00+00', '2024-08-02 00:00:00+00')),
  'k324_p2024_08_01@1,k324_p2024_08_02@2',
  'LIVENESS: k324''s fine cells hold their rows (one on 08-01, two on 08-02), so the completed run moved data');

-- ============ #1117: the registered anchor off the unit is refused at every entry point ============
select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.d324', '1 day'),
  'pg_partition_magician: cannot regrain d324 -- its grid is not on its control column dt''s unit: the column is date, which keeps whole days only, and the registered partition_anchor 2000-01-01 12:00:00+00 and partition_step 1 mon%pgpm.untransmute%whole multiples of 1 day (an anchor at 00:00 UTC)',
  'set_regrain refuses a date grid registered at noon, naming the anchor and the remedy');
select is((select regrain_to from pgpm.config where parent_table = 'public.d324'::regclass), null,
  'the refused set_regrain stored no target on d324');
select throws_like(format('select pgpm.regrain_step(%L, %L, %L)', 'public.d324', :'d_mono', '1 day'),
  'pg_partition_magician: cannot regrain d324 -- its grid is not on its control column dt''s unit%',
  'regrain_step refuses the noon-anchored date grid before it prepares');
select throws_like(format('select pgpm.regrain(%L, %L, %L)', 'public.d324', :'d_mono', '1 day'),
  'pg_partition_magician: cannot regrain d324 -- its grid is not on its control column dt''s unit%',
  'regrain() refuses it too, where it used to fail at an empty-range ATTACH after copying');
select is(pg_temp.run_marks('public.d324'), '0 copies/0 captures/no cursor',
  'nothing was copied for d324: no copy, no capture trigger, no cursor');

select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.t324', '1 day'),
  'pg_partition_magician: cannot regrain t324 -- its grid is not on its control column ts''s unit: the column is timestamp(0) with time zone, which keeps whole seconds only, and the registered partition_anchor 2000-01-01 00:00:00.4+00 and partition_step 1 mon%whole multiples of 1 second',
  'set_regrain refuses a timestamptz(0) grid anchored 0.4 s off the second, though the target is whole seconds');
select throws_like(format('select pgpm.regrain(%L, %L, %L)', 'public.t324', :'t_mono', '1 day'),
  'pg_partition_magician: cannot regrain t324 -- its grid is not on its control column ts''s unit%',
  'regrain() refuses the off-second grid');
select is(pg_temp.run_marks('public.t324'), '0 copies/0 captures/no cursor',
  'nothing was copied for t324');
-- a target an older install stored: the tick's auto-regrain is refused the same way, and logs it
update pgpm.config set regrain_to = '1 day', paused = false where parent_table = 'public.t324'::regclass;
call pgpm.maintain('public.t324');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.t324'::regclass and action = 'skip_regrain'
                    and method like '%cannot regrain t324 -- its grid is not on its control column ts''s unit%'),
  'the tick''s auto-regrain of t324 logs skip_regrain with the refusal');
select is(pg_temp.run_marks('public.t324'), '0 copies/0 captures/no cursor',
  'and the tick copied nothing either');
update pgpm.config set regrain_to = null, paused = true where parent_table = 'public.t324'::regclass;

-- ============ and the registered step, the anchor being on the unit ============
select throws_like(format('select pgpm.regrain_step(%L, %L, %L)', 'public.s324', :'s_mono', '1 day'),
  'pg_partition_magician: cannot regrain s324 -- its grid is not on its control column ts''s unit%partition_anchor 2000-01-01 00:00:00+00 and partition_step 00:00:01.5%',
  'regrain_step refuses a timestamptz(0) grid registered with a 1.5 s step, its anchor on the second');
select is(pg_temp.run_marks('public.s324'), '0 copies/0 captures/no cursor',
  'nothing was copied for s324');

-- ============ the rule is the column's unit, not "any fractional anchor" ============
select lives_ok($$ select pgpm.set_regrain('public.u324', '1 day') $$,
  'set_regrain accepts the same 0.4 s anchor on an unconstrained timestamptz key, which keeps microseconds');
select is((select regrain_to from pgpm.config where parent_table = 'public.u324'::regclass), '1 day',
  'and stores u324''s target');
select lives_ok($$ select pgpm.set_regrain('public.u324', null) $$, 'u324''s target cleared again');

-- ============ the registered zone of a naive key (V-01) ============
select is(pg_temp.attempt(format('select pgpm.regrain(%L, %L, %L)', 'public.e324', :'e_mono', '1 day')), 'completed',
  'LIVENESS: e324 (a date key recorded in Etc/UTC, a zero-offset zone) regrains its monolith to 1 day');
select throws_like(format('select pgpm.regrain_step(%L, %L, %L)', 'public.z324', :'z_mono', '1 day'),
  'pg_partition_magician: cannot regrain z324 toward 1 day -- its control column dt is date, which carries no zone, but its grid is recorded in partition_tz America/New_York rather than UTC%A whole number of months is not refused.%',
  'regrain_step refuses a day on a date grid recorded in America/New_York, naming the zone');
select is(pg_temp.run_marks('public.z324'), '0 copies/0 captures/no cursor',
  'nothing was copied for z324');
select lives_ok($$ select pgpm.set_regrain('public.z324', '1 month') $$,
  'set_regrain accepts a whole month on the same grid: a calendar step round-trips through the zone');
select lives_ok($$ select pgpm.set_regrain('public.z324', null) $$, 'z324''s target cleared again');
select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.w324', '1 hour'),
  'pg_partition_magician: cannot regrain w324 toward 1 hour -- its control column ts is timestamp without time zone, which carries no zone, but its grid is recorded in partition_tz Europe/London rather than UTC%',
  'set_regrain refuses an hour on a naive timestamp grid recorded in Europe/London');

-- ============ the remedy names its one-way door (P1-02) ============
select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.d324', '1 day'),
  '%Re-convert the table: while every row is still in its original monolith, pgpm.untransmute(''d324'') hands it back and it can be transmuted again with an anchor and a step that are whole multiples of 1 day (an anchor at 00:00 UTC); once a row lives past the monolith (a forward partition holds one, or a regrain has split it), untransmute refuses it as a one-way door and pgpm has no in-place repair, so create a new table like it, copy its rows in, swap the two tables'' names and transmute the new one with an anchor and a step%',
  'the off-unit refusal names untransmute only while every row is in the monolith, and the copy past it');
select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.y324', '1 day'),
  'pg_partition_magician: cannot regrain y324 -- its grid is not on its control column k''s encoded unit%Re-convert the table: while every row is still in its original monolith, pgpm.untransmute(''y324'') hands it back%whole milliseconds; once a row lives past the monolith%untransmute refuses it as a one-way door%create a new table like it, copy its rows in%',
  '#1039''s encoded-unit refusal says the same of y324');
select ok(exists (select 1 from public.y324 r where r.id = 9001
                    and r.tableoid <> (select monolith_oid from pgpm.config where parent_table = 'public.y324'::regclass)),
  'LIVENESS: y324''s row 9001 lives past its monolith');
select throws_like($$ select pgpm.untransmute('public.y324') $$, '%one-way door%',
  'and untransmute does refuse y324, the case the message now names');

-- ============ #1139 bullet 1: the upgrade flags each off-unit grid, once, with its remedy ============
alter table public.t324 rename column ts to "ts at";   -- followed by the partition key's attnum
select is((select count(*)::int from pgpm.log where action = 'warn_grid_off_unit'), 0,
  'LIVENESS: no grid was flagged before the upgrade');
reset search_path;
\ir :install
set client_min_messages = warning;
set search_path = clk324, pg_catalog, public;
select is((select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.log where action = 'warn_grid_off_unit'),
  'd324,s324,t324,w324,z324',
  'the upgrade logs warn_grid_off_unit for d324, s324, t324, w324 and z324, and for none of c324, e324, k324, u324');
select ok((select bool_and(method like '%while every row is still in its original monolith, pgpm.untransmute(''' || parent_table::text
                                       || ''') hands it back%one-way door%create a new table like it, copy its rows in%')
             from pgpm.log where action = 'warn_grid_off_unit'),
  'each warn_grid_off_unit row names the reconversion as its remedy, with its one-way door');
select ok(exists (select 1 from pgpm.log where action = 'warn_grid_off_unit' and parent_table = 'public.t324'::regclass
                    and method like '%control column "ts at"''s clock%2000-01-01 00:00:00.4+00%whole multiples of 1 second%')
          and exists (select 1 from pgpm.log where action = 'warn_grid_off_unit' and parent_table = 'public.d324'::regclass
                    and method like '%column is date%2000-01-01 12:00:00+00%1 day (an anchor at 00:00 UTC)%')
          and exists (select 1 from pgpm.log where action = 'warn_grid_off_unit' and parent_table = 'public.z324'::regclass
                    and method like '%column is date, which carries no zone, but the grid is recorded in partition_tz America/New_York rather than UTC%'),
  't324''s row names its renamed column and its anchor, d324''s its noon anchor and the 00:00 UTC remedy, z324''s its zone');
reset search_path;
\ir :install
set client_min_messages = warning;
set search_path = clk324, pg_catalog, public;
select is((select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.log where action = 'warn_grid_off_unit'),
  'd324,s324,t324,w324,z324',
  'a second run of install.sql finds the same five grids and does not log them again');

select * from finish();
