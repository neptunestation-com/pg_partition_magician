-- set_partition_tz serialises against an obtain() or extend_to() in flight on the same parent, in both
-- orders (issue #725).
--
-- THE DEFECT. set_partition_tz judged the grid from COMMITTED pgpm.part and took only _regrain_lock, which
-- obtain() and extend_to() never take; neither of them took any lock the setter waited for, nor read the
-- zone under one. So two interleavings each left a grid whose top is off the recorded zone's lattice, and
-- the next extension a permanent one-hour hole that refuses writes, which is the exact outcome
-- set_partition_tz exists to refuse (#455), and which it does refuse when the two calls run one after the
-- other. Fixture: a uuidv7 month grid recorded in Africa/Lagos (UTC+1 all year) with its top at
-- 2030-07-01 Lagos, which is also a Europe/London month edge (BST); London and Lagos agree at month edges
-- from July to October 2030 and not at November or December.
--   (1) extend_to/obtain builds July..November on the Lagos lattice and has not committed; the setter reads
--       a grid whose top is still July 1, accepts Lagos -> London, and once both commit the top is
--       2030-11-30 23:00Z, which is no London month edge.
--   (2) the setter has accepted Lagos -> London and has not committed; extend_to/obtain reads the zone
--       still recorded (Lagos), builds July..November on the Lagos lattice, and the same top results.
--
-- THE CONTRACT. Both orders serialise on the parent's config row: obtain() and extend_to() read it FOR KEY
-- SHARE, and set_partition_tz reads it FOR UPDATE before it judges anything.
--   (A) extend_to held open: the setter waits for it, then judges the grid it built and refuses.
--   (B) the setter held open: extend_to waits for it, then builds on the NEW zone's lattice.
--   (C) obtain held open: as (A).
--   (D) the setter held open: obtain as (B).
-- Every refusal is pinned by its message, every grid by the exact bounds of its cells, and every write by
-- the partition it landed in.
--
-- THE PROBES use two dblink sessions ordered by lock state, never by sleeps: the first holds its call
-- open in a transaction, the second is sent only then, and they are collected only once the second is
-- seen WAITING on a lock while the first is still idle in its transaction. Those witnesses are what keep
-- the outcomes honest: a refusal in (A) or (C) is also what a setter that simply ran after the extension
-- committed returns. bench/set_partition_tz_grid_lock.sh runs this file against mutants with each of the
-- three locks removed, and `./test.sh discriminate` requires it to FAIL on every one.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(43);

-- One fixture per section: two rows in June 2030, transmuted in Lagos with no lookahead, so the grid is
-- the monolith alone, [2030-05-31 23:00Z, 2030-06-30 23:00Z).
create function pg_temp.mk195(p_tab text) returns void language plpgsql as $$
begin
  execute format('create table public.%I (id uuid primary key, v int)', p_tab);
  execute format($i$insert into public.%I
    select (left(pgpm._ts_to_uuid(ts)::text, 24) || lpad(to_hex(n), 12, '0'))::uuid, n
      from (values (timestamptz '2030-06-10 00:00+00', 1), (timestamptz '2030-06-20 00:00+00', 2)) x(ts, n)$i$, p_tab);
end $$;
set timezone = 'Africa/Lagos';
select pg_temp.mk195('tz195_a');
call pgpm.transmute('public.tz195_a', 'id', '1 month', p_obtain => 0, p_force_uuidv7 => true, p_force_frontier => true);
select pg_temp.mk195('tz195_b');
call pgpm.transmute('public.tz195_b', 'id', '1 month', p_obtain => 0, p_force_uuidv7 => true, p_force_frontier => true);
select pg_temp.mk195('tz195_c');
call pgpm.transmute('public.tz195_c', 'id', '1 month', p_obtain => 0, p_force_uuidv7 => true, p_force_frontier => true);
select pg_temp.mk195('tz195_d');
call pgpm.transmute('public.tz195_d', 'id', '1 month', p_obtain => 0, p_force_uuidv7 => true, p_force_frontier => true);
set timezone = 'UTC';
select pgpm.set_obtain('public.tz195_c', 5);
select pgpm.set_obtain('public.tz195_d', 5);

-- cells above the monolith, as UTC 'lo/hi', in grid order
create function pg_temp.cells195(p_parent regclass) returns text[] language sql as $$
  select coalesce(array_agg(to_char(lo::timestamptz at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || '/'
                         || to_char(hi::timestamptz at time zone 'UTC', 'YYYY-MM-DD HH24:MI') order by lo::timestamptz), '{}')
    from pgpm.part where parent_table = p_parent and attached and lo::timestamptz >= timestamptz '2030-06-30 23:00+00'
$$;
-- wait until session B is seen waiting on a lock, or has finished (it did not wait at all)
create function pg_temp.await_b195() returns void language plpgsql as $$
begin
  for i in 1 .. 6000 loop
    -- pg_stat_activity is a per-transaction snapshot; clear it every turn or the loop rereads its first
    -- sample (#713)
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where pid = current_setting('c195.bpid')::int
                       and wait_event_type = 'Lock');
    exit when dblink_is_busy('c195_b') = 0;
    perform pg_sleep(0.005);
  end loop;
end $$;
-- collect session B's outcome as 'sqlstate result-or-message'
create function pg_temp.collect_b195(p_who text) returns void language plpgsql as $$
declare v text;
begin
  begin
    select x into v from dblink_get_result('c195_b') as t(x text);
    insert into public.c195_outcome values (p_who, '00000', v);
  exception when others then
    insert into public.c195_outcome values (p_who, sqlstate, left(sqlerrm, 300));
  end;
  begin perform * from dblink_get_result('c195_b') as t(x text); exception when others then null; end;
end $$;
create table public.c195_outcome (who text primary key, state text, result text);

select is((select array_agg(partition_tz order by parent_table::text) from pgpm.config
            where parent_table::text in ('tz195_a', 'tz195_b', 'tz195_c', 'tz195_d')),
  array['Africa/Lagos', 'Africa/Lagos', 'Africa/Lagos', 'Africa/Lagos'],
  'fixture: every grid is recorded in Africa/Lagos');
select is((select array_agg(to_char(lo::timestamptz at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || '/'
                         || to_char(hi::timestamptz at time zone 'UTC', 'YYYY-MM-DD HH24:MI'))
             from pgpm.part where parent_table = 'public.tz195_a'::regclass and attached),
  array['2030-05-31 23:00/2030-06-30 23:00'],
  'fixture: the grid is the monolith alone, [June 1, July 1) Lagos');
select ok(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2030-05-31 23:00:00+00', 'Europe/London')::timestamptz
            = timestamptz '2030-05-31 23:00+00'
      and pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2030-06-30 23:00:00+00', 'Europe/London')::timestamptz
            = timestamptz '2030-06-30 23:00+00',
  'LIVENESS: London agrees with Lagos at both committed bounds, so Lagos -> London passes every check on that grid alone');
select isnt(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2030-11-30 23:00:00+00', 'Europe/London')::timestamptz,
  timestamptz '2030-11-30 23:00+00',
  'LIVENESS: and disagrees at December 1 Lagos (2030-11-30 23:00Z), where an extension to November tops out');

select dblink_connect('c195_a', 'dbname=' || current_database());
select dblink_connect('c195_b', 'dbname=' || current_database());
select pid as apid from dblink('c195_a', 'select pg_backend_pid()') as t(pid int) \gset
select pid as bpid from dblink('c195_b', 'select pg_backend_pid()') as t(pid int) \gset
select set_config('c195.bpid', :'bpid', false);

-- ======================================================================================================
-- (A) extend_to builds July..November in Lagos and holds its transaction; the zone change waits, refuses
-- ======================================================================================================
select dblink_exec('c195_a', 'begin');
select is((select x from dblink('c195_a',
            $q$select pgpm.extend_to('public.tz195_a', pgpm._ts_to_uuid('2030-11-15 00:00+00')::text)::text$q$) as t(x text)),
  '5', 'LIVENESS: (A) session A extended the grid by five cells and holds its transaction open');
select dblink_send_query('c195_b', $q$select pgpm.set_partition_tz('public.tz195_a', 'Europe/London')::text$q$);
select pg_temp.await_b195();
select ok(exists (select 1 from pg_stat_activity where pid = :bpid and wait_event_type = 'Lock'),
  'LIVENESS: (A) the zone change is waiting on a lock...');
select ok(exists (select 1 from pg_stat_activity where pid = :apid and state = 'idle in transaction'),
  'LIVENESS: (A) ...while session A''s extension is still uncommitted');
select dblink_exec('c195_a', 'commit');
select pg_temp.collect_b195('A');

select is((select state from public.c195_outcome where who = 'A'), 'P0001',
  '(A) the zone change raised once the extension had committed');
select ok((select result like 'pg_partition_magician: set_partition_tz(tz195_a, Europe/London) refused -- the grid built so far ends at 2030-11-30 23:00:00+00, which is not a 1 mon grid boundary in Europe/London%'
             from public.c195_outcome where who = 'A'),
  '(A) refused for the grid session A built: its top, December 1 Lagos, is no London month edge');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz195_a'::regclass), 'Africa/Lagos',
  '(A) the zone is still Lagos');
select is((select count(*)::int from pgpm.log where parent_table = 'public.tz195_a'::regclass and action = 'set_partition_tz'), 0,
  '(A) no zone change was logged');
select is(pg_temp.cells195('public.tz195_a'),
  array['2030-06-30 23:00/2030-07-31 23:00', '2030-07-31 23:00/2030-08-31 23:00', '2030-08-31 23:00/2030-09-30 23:00',
        '2030-09-30 23:00/2030-10-31 23:00', '2030-10-31 23:00/2030-11-30 23:00'],
  '(A) session A''s five cells are on the Lagos lattice');
select is(pgpm.extend_to('public.tz195_a', pgpm._ts_to_uuid('2031-01-15 00:00+00')::text), 2,
  '(A) the grid extends past them, in Lagos');
select lives_ok($$ insert into public.tz195_a values (pgpm._ts_to_uuid('2030-11-30 23:30+00'), 9) $$,
  '(A) a write at 2030-11-30 23:30Z has a partition');
select is((select tableoid::regclass::text from public.tz195_a where v = 9), 'tz195_a_p2030_12',
  '(A) and it is December Lagos, flush against November: no hole');

-- ======================================================================================================
-- (B) the zone change is accepted and held open; extend_to waits for it, then builds in London
-- ======================================================================================================
select dblink_exec('c195_a', 'begin');
select is((select x from dblink('c195_a',
            $q$select pgpm.set_partition_tz('public.tz195_b', 'Europe/London')::text$q$) as t(x text)),
  '', 'LIVENESS: (B) session A changed the zone to London and holds its transaction open');
select dblink_send_query('c195_b',
  $q$select pgpm.extend_to('public.tz195_b', pgpm._ts_to_uuid('2030-11-15 00:00+00')::text)::text$q$);
select pg_temp.await_b195();
select ok(exists (select 1 from pg_stat_activity where pid = :bpid and wait_event_type = 'Lock'),
  'LIVENESS: (B) the extension is waiting on a lock...');
select ok(exists (select 1 from pg_stat_activity where pid = :apid and state = 'idle in transaction'),
  'LIVENESS: (B) ...while session A''s zone change is still uncommitted');
select dblink_exec('c195_a', 'commit');
select pg_temp.collect_b195('B');

select is((select state || ' ' || result from public.c195_outcome where who = 'B'), '00000 5',
  '(B) the extension ran once the zone change had committed and built five cells');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz195_b'::regclass), 'Europe/London',
  '(B) the zone is London');
select is(pg_temp.cells195('public.tz195_b'),
  array['2030-06-30 23:00/2030-07-31 23:00', '2030-07-31 23:00/2030-08-31 23:00', '2030-08-31 23:00/2030-09-30 23:00',
        '2030-09-30 23:00/2030-11-01 00:00', '2030-11-01 00:00/2030-12-01 00:00'],
  '(B) the five cells are on the London lattice: October ends at November 1 00:00Z (GMT), not Lagos''s 23:00Z');
select is(pgpm.extend_to('public.tz195_b', pgpm._ts_to_uuid('2031-01-15 00:00+00')::text), 2,
  '(B) the grid extends past them, in London');
select lives_ok($$ insert into public.tz195_b values (pgpm._ts_to_uuid('2030-11-30 23:30+00'), 9) $$,
  '(B) a write at 2030-11-30 23:30Z has a partition');
select is((select tableoid::regclass::text from public.tz195_b where v = 9), 'tz195_b_p2030_11',
  '(B) and it is November London');

-- ======================================================================================================
-- (C) obtain builds July..November in Lagos and holds its transaction; the zone change waits, refuses
-- ======================================================================================================
select dblink_exec('c195_a', 'begin');
select is((select x from dblink('c195_a', $q$select pgpm.obtain('public.tz195_c')::text$q$) as t(x text)),
  '5', 'LIVENESS: (C) session A obtained five cells and holds its transaction open');
select dblink_send_query('c195_b', $q$select pgpm.set_partition_tz('public.tz195_c', 'Europe/London')::text$q$);
select pg_temp.await_b195();
select ok(exists (select 1 from pg_stat_activity where pid = :bpid and wait_event_type = 'Lock'),
  'LIVENESS: (C) the zone change is waiting on a lock...');
select ok(exists (select 1 from pg_stat_activity where pid = :apid and state = 'idle in transaction'),
  'LIVENESS: (C) ...while session A''s obtain is still uncommitted');
select dblink_exec('c195_a', 'commit');
select pg_temp.collect_b195('C');

select is((select state from public.c195_outcome where who = 'C'), 'P0001',
  '(C) the zone change raised once the obtain had committed');
select ok((select result like 'pg_partition_magician: set_partition_tz(tz195_c, Europe/London) refused -- the grid built so far ends at 2030-11-30 23:00:00+00, which is not a 1 mon grid boundary in Europe/London%'
             from public.c195_outcome where who = 'C'),
  '(C) refused for the grid session A built');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz195_c'::regclass), 'Africa/Lagos',
  '(C) the zone is still Lagos');
select is((select count(*)::int from pgpm.log where parent_table = 'public.tz195_c'::regclass and action = 'set_partition_tz'), 0,
  '(C) no zone change was logged');
select is(pg_temp.cells195('public.tz195_c'),
  array['2030-06-30 23:00/2030-07-31 23:00', '2030-07-31 23:00/2030-08-31 23:00', '2030-08-31 23:00/2030-09-30 23:00',
        '2030-09-30 23:00/2030-10-31 23:00', '2030-10-31 23:00/2030-11-30 23:00'],
  '(C) session A''s five cells are on the Lagos lattice');
select lives_ok($$ insert into public.tz195_c values (pgpm._ts_to_uuid('2030-11-30 22:30+00'), 9) $$,
  '(C) a write at 2030-11-30 22:30Z has a partition');
select is((select tableoid::regclass::text from public.tz195_c where v = 9), 'tz195_c_p2030_11',
  '(C) and it is November Lagos');

-- ======================================================================================================
-- (D) the zone change is accepted and held open; obtain waits for it, then builds in London
-- ======================================================================================================
select dblink_exec('c195_a', 'begin');
select is((select x from dblink('c195_a',
            $q$select pgpm.set_partition_tz('public.tz195_d', 'Europe/London')::text$q$) as t(x text)),
  '', 'LIVENESS: (D) session A changed the zone to London and holds its transaction open');
select dblink_send_query('c195_b', $q$select pgpm.obtain('public.tz195_d')::text$q$);
select pg_temp.await_b195();
select ok(exists (select 1 from pg_stat_activity where pid = :bpid and wait_event_type = 'Lock'),
  'LIVENESS: (D) the obtain is waiting on a lock...');
select ok(exists (select 1 from pg_stat_activity where pid = :apid and state = 'idle in transaction'),
  'LIVENESS: (D) ...while session A''s zone change is still uncommitted');
select dblink_exec('c195_a', 'commit');
select pg_temp.collect_b195('D');
select dblink_disconnect('c195_a');
select dblink_disconnect('c195_b');

select is((select state || ' ' || result from public.c195_outcome where who = 'D'), '00000 5',
  '(D) the obtain ran once the zone change had committed and built five cells');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz195_d'::regclass), 'Europe/London',
  '(D) the zone is London');
select is(pg_temp.cells195('public.tz195_d'),
  array['2030-06-30 23:00/2030-07-31 23:00', '2030-07-31 23:00/2030-08-31 23:00', '2030-08-31 23:00/2030-09-30 23:00',
        '2030-09-30 23:00/2030-11-01 00:00', '2030-11-01 00:00/2030-12-01 00:00'],
  '(D) the five cells are on the London lattice');
select is(pgpm.extend_to('public.tz195_d', pgpm._ts_to_uuid('2031-01-15 00:00+00')::text), 2,
  '(D) the grid extends past them, in London');
select lives_ok($$ insert into public.tz195_d values (pgpm._ts_to_uuid('2030-11-30 23:30+00'), 9) $$,
  '(D) a write at 2030-11-30 23:30Z has a partition');
select is((select tableoid::regclass::text from public.tz195_d where v = 9), 'tz195_d_p2030_11',
  '(D) and it is November London');

select * from finish();
