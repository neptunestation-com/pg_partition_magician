-- The zone pgpm records refuses pg_timezone_names' pseudo-entries (issue #1086, F14-06).
--
-- THE BUG. _canonical_tz looked a name up in pg_timezone_names and nothing else. That view lists every file
-- under the tzdata directory, and three of them are not zones: 'localtime' (on a --with-system-tzdata build,
-- a symlink to the host's /etc/localtime), 'posixrules' (the rules a POSIX TZ string borrows its DST dates
-- from, a link to whatever zone the tzdata package was built with) and 'Factory' (the "-00" placeholder for
-- a host whose zone was never set). set_partition_tz(t, 'localtime') was accepted and stored, so the grid's
-- zone became whatever the host of the day is set to, and a restore on another host moved every calendar
-- boundary with nothing recorded. A transmute under `set timezone = 'localtime'` recorded it the same way.
--
-- THE CONTRACT. Only a named zone that carries its own rules is ever recorded in config.partition_tz:
-- _canonical_tz returns null for the three pseudo-entries in any casing, so set_partition_tz and transmute
-- refuse them alike, and nothing is recorded; a real zone name still resolves to its canonical spelling.
--
-- ASYMMETRIC FIXTURE. public.tz_d is a day grid of 2 rows; public.tz_m holds 3 rows and is transmuted
-- from a refused session zone, so the one registration that must exist (tz_d) and the one that must not
-- (tz_m) cannot stand in for each other.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(25);

-- ==================== the pseudo-entries are there to be refused ====================
select ok(exists (select 1 from pg_timezone_names where name = 'localtime'),
  'LIVENESS: this server''s pg_timezone_names lists localtime');
select ok(exists (select 1 from pg_timezone_names where name = 'posixrules'),
  'LIVENESS: this server''s pg_timezone_names lists posixrules');
select ok(exists (select 1 from pg_timezone_names where name = 'Factory'),
  'LIVENESS: this server''s pg_timezone_names lists Factory');

-- ==================== _canonical_tz ====================
select is(pgpm._canonical_tz('localtime'), null, '_canonical_tz refuses localtime');
select is(pgpm._canonical_tz('LocalTime'), null, '_canonical_tz refuses localtime in any casing');
select is(pgpm._canonical_tz('posixrules'), null, '_canonical_tz refuses posixrules');
select is(pgpm._canonical_tz('Factory'), null, '_canonical_tz refuses Factory');
select is(pgpm._canonical_tz('factory'), null, '_canonical_tz refuses Factory in any casing');
-- positive controls: the refusal is about those three names, not about the lookup
select is(pgpm._canonical_tz('america/new_york'), 'America/New_York',
  'LIVENESS: a real zone still resolves to its canonical spelling');
select is(pgpm._canonical_tz('utc'), 'UTC', 'LIVENESS: and so does UTC');

-- ==================== set_partition_tz ====================
create table public.tz_d (ts timestamptz not null, v text);
insert into public.tz_d values (now() - interval '2 days', 'd1'), (now(), 'd2');
call pgpm.transmute('public.tz_d', 'ts', interval '1 day', p_obtain => 2);
select is((select partition_tz from pgpm.config where parent_table = 'public.tz_d'::regclass), 'UTC',
  'LIVENESS: the day grid is recorded in UTC');
-- a day grid takes any zone (its lattice is absolute), so a refusal below is about the name alone
select lives_ok($$ select pgpm.set_partition_tz('public.tz_d', 'Europe/London') $$,
  'LIVENESS: the day grid accepts a change to a named zone');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz_d'::regclass), 'Europe/London',
  'LIVENESS: and records it');

select throws_like($$ select pgpm.set_partition_tz('public.tz_d', 'localtime') $$,
  '%localtime is not a zone pgpm can record%',
  'set_partition_tz refuses localtime, which follows the host''s /etc/localtime');
select throws_like($$ select pgpm.set_partition_tz('public.tz_d', 'LOCALTIME') $$,
  '%LOCALTIME is not a zone pgpm can record%',
  'set_partition_tz refuses localtime in any casing');
select throws_like($$ select pgpm.set_partition_tz('public.tz_d', 'posixrules') $$,
  '%posixrules is not a zone pgpm can record%',
  'set_partition_tz refuses posixrules');
select throws_like($$ select pgpm.set_partition_tz('public.tz_d', 'Factory') $$,
  '%Factory is not a zone pgpm can record%',
  'set_partition_tz refuses Factory');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz_d'::regclass), 'Europe/London',
  'the recorded zone is still Europe/London: no refused call recorded anything');
select is(
  (select string_agg(method, ',' order by id) from pgpm.log
    where parent_table = 'public.tz_d'::regclass and action = 'set_partition_tz'),
  'UTC -> Europe/London',
  'exactly the accepted change was logged as set_partition_tz; the refused ones logged nothing');

-- ==================== transmute under a pseudo-entry session zone ====================
create table public.tz_m (ts timestamptz not null, v text);
insert into public.tz_m values (now() - interval '3 days', 'm1'), (now() - interval '1 day', 'm2'), (now(), 'm3');
set timezone = 'localtime';
select is(current_setting('TimeZone'), 'localtime', 'LIVENESS: the session accepted localtime as its zone');
select throws_like($$ call pgpm.transmute('public.tz_m', 'ts', interval '1 month') $$,
  '%TimeZone (localtime) is not a zone pgpm can record%',
  'transmute refuses to record localtime as the grid''s zone');
set timezone = 'Factory';
select throws_like($$ call pgpm.transmute('public.tz_m', 'ts', interval '1 month') $$,
  '%TimeZone (Factory) is not a zone pgpm can record%',
  'transmute refuses to record Factory as the grid''s zone');
set timezone = 'UTC';
select ok(not exists (select 1 from pgpm.config where parent_table = 'public.tz_m'::regclass),
  'the refused transmutes registered nothing');
select is((select relkind::text from pg_class where oid = 'public.tz_m'::regclass), 'r',
  'public.tz_m is still the plain table it was: the refusal came before its first commit');
select is((select string_agg(v, ',' order by v) from public.tz_m), 'm1,m2,m3',
  'and it still holds exactly its own rows');

select * from finish();
