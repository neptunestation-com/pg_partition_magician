-- from_hypertable refuses a hypertable whose working relation names would not fit whole (issue #552).
--
-- The module derives <rel>_pgpm_dest, <rel>_pgpm_delta, <rel>_pgpm_delta_fn and <rel>_pgpm_delta_trg from the
-- hypertable's name, and PostgreSQL cut each to 63 bytes without a word. From 55 bytes the destination and
-- the change-capture delta cut to the SAME name: from_hypertable_copy(p_track_changes => true) created the
-- delta, the destination skeleton's `drop table if exists` dropped it and took its name, and the capture
-- trigger on the LIVE source then inserted key-only rows into the destination, so every write to the
-- production hypertable failed on NOT NULL from the copy onward. The fix refuses, before any DDL, any name
-- the module would derive over 63 bytes, at every entry point that derives them: the preflight (and so the
-- copy), the cutover and the online drains. The longest suffix is 15 bytes, so 48 bytes is the budget.
--
-- Every refusal is pinned to its message (the copy and the cutover commit, so an unpinned throws_* would
-- also accept the 2D000 a non-refusing procedure dies with inside the wrapper), and paired with witnesses:
-- the 55-byte names really do cut to one name, the source really is live and keeps accepting writes, and a
-- 48-byte hypertable really migrates end to end with every working name whole. The 72 rows and the
-- one-row write are asymmetric so "nothing was lost" and "nothing was added" cannot cancel.
-- bench/hypertable_derived_names.sh runs this file against hypertable_derived_names_unchecked, the mutation
-- that removes the refusal, and is required to FAIL there. Autocommit, disposable-db.
select plan(18);

\set L55 sensor_readings_from_the_north_atlantic_buoy_network_x1
\set L49 sensor_readings_from_the_north_atlantic_buoy_xx49
\set L48 sensor_readings_from_the_north_atlantic_buoy_x48

select mk_keyed_hypertable(:'L55', 72, '1 day', '3 days');   -- UNIQUE (device_id, ts), device_id = 1..72
select is(octet_length(:'L55') || '|' || (select count(*) from public.:L55)
          || '|' || exists (select 1 from timescaledb_information.hypertables where hypertable_name = :'L55'),
  '55|72|true', 'LIVENESS: a 55-byte-named keyed hypertable with 72 rows');
select is(left(:'L55' || '_pgpm_dest', 63), left(:'L55' || '_pgpm_delta', 63),
  'LIVENESS: its destination and delta names cut to the same 63 bytes');

-- ==================== (A) the copy refuses before it installs anything ====================
select throws_like(
  format($$ call pgpm.from_hypertable_copy('public.%I', 'ts', p_track_changes => true) $$, :'L55'),
  'pg_partition_magician: cannot migrate hypertable % -- the working relation name ' || :'L55' || '_pgpm_delta_trg is 70 bytes%Shorten the table name by at least 7 byte(s)%',
  'from_hypertable_copy(p_track_changes => true) refuses, naming the longest name and the bytes to shorten by');
select is((select count(*)::int from pg_class where relname like :'L55' || '\_pgpm%'), 0,
  'no working relation was created under a cut name');
select is((select count(*)::int from pg_trigger where tgrelid = format('public.%I', :'L55')::regclass and tgname like '%pgpm%'), 0,
  'and no capture trigger was installed on the source');
select lives_ok(format($$ insert into public.%I (ts, device_id, temp) values (now(), 1000, 1.5) $$, :'L55'),
  'the source still accepts a write');
select is((select array_agg(device_id order by device_id) from public.:L55),
  (select array_agg(g::bigint order by g) from (select generate_series(1, 72) union all select 1000) s(g)),
  'and holds exactly its 72 rows and the new one');
select throws_like(
  format($$ call pgpm.from_hypertable_copy('public.%I', 'ts') $$, :'L55'),
  'pg_partition_magician: cannot migrate hypertable %_pgpm_delta_trg is 70 bytes%',
  'the append-only copy refuses too (the cutover would still probe the delta names)');

-- ==================== (B) every other entry point that derives the names refuses the same way ====================
select throws_like(
  format($$ select pgpm.from_hypertable_preflight('public.%I', 'ts') $$, :'L55'),
  'pg_partition_magician: cannot migrate hypertable %_pgpm_delta_trg is 70 bytes%',
  'the preflight, as a dry-run gate');
select throws_like(
  format($$ call pgpm.from_hypertable_cutover('public.%I', 'ts', interval '1 year') $$, :'L55'),
  'pg_partition_magician: cannot migrate hypertable %_pgpm_delta_trg is 70 bytes%',
  'the cutover, before it looks for a copy');
select throws_like(
  format($$ select pgpm.from_hypertable_drain_appends_step('public.%I', 'ts', 10, null) $$, :'L55'),
  'pg_partition_magician: cannot migrate hypertable %_pgpm_delta_trg is 70 bytes%',
  'the append drain step');
select throws_like(
  format($$ select pgpm.from_hypertable_drain_delta_step('public.%I', 'ts', 10) $$, :'L55'),
  'pg_partition_magician: cannot migrate hypertable %_pgpm_delta_trg is 70 bytes%',
  'the delta drain step');
select is(
  (select relkind::text from pg_class where oid = format('public.%I', :'L55')::regclass)
    || '|' || exists (select 1 from timescaledb_information.hypertables where hypertable_name = :'L55'),
  'r|true', 'and the hypertable is still a hypertable');

-- ==================== (C) the boundary: 49 bytes is refused by one byte, 48 migrates ====================
select mk_keyed_hypertable(:'L49', 10, '1 day', '3 days');
select throws_like(
  format($$ select pgpm.from_hypertable_preflight('public.%I', 'ts') $$, :'L49'),
  'pg_partition_magician: cannot migrate hypertable %_pgpm_delta_trg is 64 bytes%at least 1 byte(s)%',
  'a 49-byte name is refused by one byte');

select mk_keyed_hypertable(:'L48', 30, '1 day', '3 days');
call pgpm.from_hypertable_copy(format('public.%I', :'L48')::regclass, 'ts', p_track_changes => true);
select is(
  (select string_agg(octet_length(n)::text, ',' order by octet_length(n)) from (values
     ((select relname::text from pg_class where oid = to_regclass(format('public.%I', :'L48' || '_pgpm_dest')))),
     ((select relname::text from pg_class where oid = to_regclass(format('public.%I', :'L48' || '_pgpm_delta')))),
     ((select proname::text from pg_proc where oid = to_regprocedure(format('public.%I()', :'L48' || '_pgpm_delta_fn')))),
     ((select tgname::text from pg_trigger where tgrelid = format('public.%I', :'L48')::regclass and tgname = :'L48' || '_pgpm_delta_trg')))
   v(n)),
  '58,59,62,63', 'LIVENESS: at 48 bytes the copy makes all four working objects, each under its whole name');
select lives_ok(format($$ insert into public.%I (ts, device_id, temp) values (now(), 5000, 2.5) $$, :'L48'),
  'a write to the live source during the online window succeeds');
call pgpm.from_hypertable_cutover(format('public.%I', :'L48')::regclass, 'ts', interval '1 year');
select is((select relkind::text from pg_class where oid = format('public.%I', :'L48')::regclass), 'p',
  'and the 48-byte hypertable migrates to a native partitioned table');
select is((select array_agg(device_id order by device_id) from public.:L48),
  (select array_agg(g::bigint order by g) from (select generate_series(1, 30) union all select 5000) s(g)),
  'with its 30 rows and the one written during the copy');

select * from finish();
