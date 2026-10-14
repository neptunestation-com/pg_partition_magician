-- A time-kind transmute refuses a -infinity OLDEST value before anything is committed (issue #769, bullet 2).
--
-- Only the newest value of a `time` control was checked for infinity; the #895 non-finite check on the oldest
-- value applied to `id` controls alone. A timestamptz, timestamp or date control whose oldest value is
-- -infinity therefore reached _grid_floor raw and the operator got "cannot convert infinity to integer" (a
-- calendar step) or "cannot subtract infinite timestamps" (a fixed one) instead of pgpm's refusal naming the
-- table, the column and the remedy. No grid boundary lies at or below -infinity, so no monolith lower bound
-- can hold such a row: the refusal is the contract, and the remedy it names (delete or correct the rows and
-- re-run) has to work as typed. A table whose EVERY value is -infinity has a -infinity newest value too, and
-- was refused as if its newest value were +infinity, with a remedy naming rows it does not hold; it now gets
-- the oldest-value refusal.
--
-- Fixtures, asymmetric on purpose (3, 2, 2, 1 and 2 rows), one per arm:
--   (A) timestamptz, -infinity under two finite rows, monthly step: refused, nothing committed; the operator
--       DELETES the row and the re-run converts, its two rows in the monolith from the March grid point;
--   (B) date, -infinity under one finite row, daily step: refused; the operator CORRECTS the row to a date and
--       the re-run converts, both rows in the monolith from the corrected date;
--   (C) timestamp (naive), -infinity under one finite row, fixed '7 days' step: refused;
--   (D) every value -infinity: refused by the oldest-value refusal, not the newest-value one;
--   (E) control: a +infinity newest value is still refused by its own refusal, alone and beside a -infinity.
-- Each refusal is pinned by its message (throws_like): a committing procedure that does NOT refuse dies at its
-- first COMMIT inside pgTAP with 2D000, which an unpinned assertion would accept. Each is paired with the state
-- a refusal must leave (still a plain table, no config, no bound, no claim, no pgpm.part row, its rows by
-- identity) and with a witness that the fixture holds the -infinity value. bench/transmute_negative_infinity_oldest.sh
-- runs this file against a mutant without the refusal (transmute_time_oldest_infinity_unchecked).
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(29);

-- what a refused call must leave, by the table's oid
create function pg_temp.t343_state(p_oid oid) returns text language sql as $$
  select concat_ws(' | ',
    (select relkind::text from pg_class where oid = p_oid),
    'config:' || exists (select 1 from pgpm.config where parent_table = p_oid::regclass),
    'bound:' || exists (select 1 from pg_constraint where conrelid = p_oid and conname = 'pgpm_monolith_bound'),
    'claim:' || exists (select 1 from pgpm.transmute_inflight where parent_table = p_oid::regclass),
    'part:' || exists (select 1 from pgpm.part where parent_table = p_oid::regclass))
$$;

-- (A) timestamptz: refused, then the remedy's DELETE
create table public.t343_tz (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.t343_tz values (1, '-infinity'), (2, '2025-03-10 08:00:00+00'), (3, '2025-07-20 12:00:00+00');
select oid as tz_oid from pg_class where oid = 'public.t343_tz'::regclass \gset
select is((select min(ts)::text from public.t343_tz), '-infinity', 'LIVENESS: (A) t343_tz''s oldest value is -infinity');
select is((select max(ts) from public.t343_tz), '2025-07-20 12:00:00+00'::timestamptz,
  'LIVENESS: (A) and its newest value is finite, so only an oldest-value refusal can fire');
select throws_like($$ call pgpm.transmute('public.t343_tz', 'ts', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician: t343_tz cannot be partitioned on a time grid using ts: its oldest value is -infinity, and no partition can hold it%Delete or correct the rows whose ts is -infinity and re-run.',
  'A: a -infinity oldest value on a timestamptz control is refused by pgpm, naming the table, the column and the remedy');
select is(pg_temp.t343_state(:tz_oid), 'r | config:false | bound:false | claim:false | part:false',
  'A: t343_tz is still a plain table, with no config, no bound, no claim and no pgpm.part row');
select is((select array_agg(id || '=' || ts::text order by id) from public.t343_tz),
  array['1=-infinity', '2=2025-03-10 08:00:00+00', '3=2025-07-20 12:00:00+00'], 'A: t343_tz still holds its three rows');
-- the remedy as the refusal types it: delete the rows whose ts is -infinity and re-run
delete from public.t343_tz where ts = '-infinity';
call pgpm.transmute('public.t343_tz', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.t343_tz'::regclass), 'p',
  'A: the re-run after the delete converted t343_tz');
select is((select lo::timestamptz from pgpm.part where child_oid = :tz_oid), '2025-03-01 00:00:00+00'::timestamptz,
  'A: its monolith (the original table) starts at the grid point below the oldest remaining row');
select is((select array_agg(id order by id) from public.t343_tz where tableoid = :tz_oid), array[2, 3]::bigint[],
  'A: rows 2 and 3 are in the monolith');

-- (B) date: refused, then the remedy's CORRECT
create table public.t343_d (id bigint, d date not null, primary key (id, d));
insert into public.t343_d values (1, '-infinity'), (2, '2025-05-06');
select oid as d_oid from pg_class where oid = 'public.t343_d'::regclass \gset
select is((select min(d)::text from public.t343_d), '-infinity', 'LIVENESS: (B) t343_d''s oldest value is -infinity');
select throws_like($$ call pgpm.transmute('public.t343_d', 'd', interval '1 day', p_obtain => 2) $$,
  'pg_partition_magician: t343_d cannot be partitioned on a time grid using d: its oldest value is -infinity, and no partition can hold it%Delete or correct the rows whose d is -infinity and re-run.',
  'B: a -infinity oldest value on a date control is refused by pgpm, naming the table, the column and the remedy');
select is(pg_temp.t343_state(:d_oid), 'r | config:false | bound:false | claim:false | part:false',
  'B: t343_d is still a plain table, with no config, no bound, no claim and no pgpm.part row');
select is((select array_agg(id || '=' || d::text order by id) from public.t343_d),
  array['1=-infinity', '2=2025-05-06'], 'B: t343_d still holds its two rows');
-- the remedy's other arm: correct the row and re-run
update public.t343_d set d = '2025-04-28' where d = '-infinity';
call pgpm.transmute('public.t343_d', 'd', interval '1 day', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.t343_d'::regclass), 'p',
  'B: the re-run after the correction converted t343_d');
select is((select lo::timestamptz from pgpm.part where child_oid = :d_oid), '2025-04-28 00:00:00+00'::timestamptz,
  'B: its monolith starts at the corrected date');
select is((select array_agg(id || '=' || d::text order by id) from public.t343_d where tableoid = :d_oid),
  array['1=2025-04-28', '2=2025-05-06'], 'B: the corrected row 1 and row 2 are in the monolith');

-- (C) timestamp without time zone, a fixed step
create table public.t343_ts (id bigint, ts timestamp not null, primary key (id, ts));
insert into public.t343_ts values (1, '-infinity'), (2, '2025-06-01 09:30:00');
select oid as ts_oid from pg_class where oid = 'public.t343_ts'::regclass \gset
select is((select min(ts)::text from public.t343_ts), '-infinity', 'LIVENESS: (C) t343_ts''s oldest value is -infinity');
select throws_like($$ call pgpm.transmute('public.t343_ts', 'ts', interval '7 days', p_obtain => 2) $$,
  'pg_partition_magician: t343_ts cannot be partitioned on a time grid using ts: its oldest value is -infinity, and no partition can hold it%Delete or correct the rows whose ts is -infinity and re-run.',
  'C: a -infinity oldest value on a timestamp control under a fixed step is refused by pgpm');
select is(pg_temp.t343_state(:ts_oid), 'r | config:false | bound:false | claim:false | part:false',
  'C: t343_ts is still a plain table, with no config, no bound, no claim and no pgpm.part row');
select is((select array_agg(id order by id) from public.t343_ts), array[1, 2]::bigint[], 'C: t343_ts still holds rows 1 and 2');

-- (D) every value -infinity: the newest value is -infinity too, and the refusal names the oldest
create table public.t343_all (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.t343_all values (1, '-infinity');
select oid as all_oid from pg_class where oid = 'public.t343_all'::regclass \gset
select is((select max(ts)::text from public.t343_all), '-infinity', 'LIVENESS: (D) t343_all''s newest value is -infinity');
select throws_like($$ call pgpm.transmute('public.t343_all', 'ts', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician: t343_all cannot be partitioned on a time grid using ts: its oldest value is -infinity%Delete or correct the rows whose ts is -infinity and re-run.',
  'D: a table whose every value is -infinity gets the oldest-value refusal, whose remedy names those rows');
select is(pg_temp.t343_state(:all_oid), 'r | config:false | bound:false | claim:false | part:false',
  'D: t343_all is still a plain table, with nothing committed');
select is((select array_agg(id order by id) from public.t343_all), array[1]::bigint[], 'D: t343_all still holds row 1');

-- (E) control: the +infinity newest value keeps its own refusal, alone and beside a -infinity oldest
create table public.t343_pinf (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.t343_pinf values (1, '2025-02-02 02:00:00+00'), (2, 'infinity');
select oid as pinf_oid from pg_class where oid = 'public.t343_pinf'::regclass \gset
select throws_like($$ call pgpm.transmute('public.t343_pinf', 'ts', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician: t343_pinf cannot be partitioned on a time grid using ts: its newest value is infinity%Delete or correct the rows whose ts is infinity and re-run.',
  'E: a +infinity newest value is still refused by the newest-value refusal');
select is(pg_temp.t343_state(:pinf_oid), 'r | config:false | bound:false | claim:false | part:false',
  'E: t343_pinf is still a plain table, with nothing committed');
create table public.t343_both (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.t343_both values (1, '-infinity'), (2, '2025-09-09 09:00:00+00'), (3, 'infinity');
select oid as both_oid from pg_class where oid = 'public.t343_both'::regclass \gset
select throws_like($$ call pgpm.transmute('public.t343_both', 'ts', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician: t343_both cannot be partitioned on a time grid using ts: its newest value is infinity%',
  'E: a table holding both infinities is refused up front, by the newest-value refusal it reaches first');
select is(pg_temp.t343_state(:both_oid), 'r | config:false | bound:false | claim:false | part:false',
  'E: t343_both is still a plain table, with nothing committed');

select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.config
            where parent_table::text like 't343\_%'),
  array['t343_d', 't343_tz'],
  'exactly the two corrected tables are registered, and none of the refused ones');
-- identity, not cardinality: one transmute row under EACH corrected table's name
select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.log
            where parent_table in ('public.t343_tz'::regclass, 'public.t343_d'::regclass) and action = 'transmute'),
  array['t343_d', 't343_tz'],
  'A, B: each corrected re-run logged its own transmute');

select * from finish();
