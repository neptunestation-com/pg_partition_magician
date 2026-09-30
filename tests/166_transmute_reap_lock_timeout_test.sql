-- _transmute_reap bounds its lock wait and DEFERS, rather than parking behind a long reader (issue #657).
--
-- THE BUG. maintain_all runs _transmute_reap first, before any lock_timeout is set, and the reaper's
-- ALTER TABLE ... DROP CONSTRAINT pgpm_monolith_bound takes ACCESS EXCLUSIVE on the operator's live,
-- still-unconverted table. Under the session default (0: wait forever, which is pg_cron's) one long reader
-- of that table parked the reaper, and its PENDING ACCESS EXCLUSIVE queued every other read and write of
-- the table behind it for the reader's whole life, with the rest of the sweep stalled behind it too.
-- transmute bounds the very lock this undoes (p_lock_timeout, #309); the reaper now bounds its own the
-- same way, and a timeout skips that one table for this tick, logged skip_transmute_reap, instead of
-- stalling the sweep.
--
-- WHAT THIS FILE PINS, in one session plus dblink: the reaper returns (a pre-fix build hangs here until
-- the hang ceiling below cancels the statement, which stops the file), the deferral is per table and
-- logged, the caller's own lock_timeout is untouched, and the deferred table is undone on the next pass
-- once the reader has gone. That an ordinary write is not held up behind the reaper needs a THIRD
-- concurrent session timing a write, which lives in bench/transmute_reap_lock_timeout.sh with a mutation
-- that puts the unbounded wait back.
--
-- ASYMMETRIC FIXTURE. Two abandoned conversions, and only one of them has a reader: the reap must undo
-- exactly the free one (b, 30 rows) and defer exactly the held one (a, 50 rows). A reaper that aborted on
-- the first timeout undoes neither, one that ignored the lock undoes both, and each is a different name.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(21);

create table public.rp166a (id bigint primary key, body text);
insert into public.rp166a select g, 'a' || g from generate_series(1, 50) g;
create table public.rp166a_ref (rid bigint primary key, id bigint references public.rp166a);
create table public.rp166b (id bigint primary key, body text);
insert into public.rp166b select g, 'b' || g from generate_series(1, 30) g;
create table public.rp166b_ref (rid bigint primary key, id bigint references public.rp166b);

create schema pgpm_test166;
-- Poll until p_pid has left pg_stat_activity: dblink_disconnect returns before the backend is gone.
-- pg_stat_activity is read once per transaction and then frozen (the documented snapshot; a function is
-- one transaction), so without clearing it each turn this loop saw its first read 600 times and passed
-- only when the backend had already gone: it ran out on two merge groups and a head (#713).
create function pgpm_test166.gone(p_pid int)
returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if not exists (select 1 from pg_stat_activity where pid = p_pid) then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

-- ======================= fixture: two REAL abandoned conversions =======================
-- A holder keeps both referencing tables locked, so each conversion's cutover times out dropping the
-- preserved incoming key (#444) after phase 1 has committed the bound and the claim. The converting
-- session then disconnects, so both claims have a dead owner: the state the reaper exists for.
select dblink_connect('hold', 'dbname=' || current_database());
select dblink_exec('hold', 'begin');
select dblink_exec('hold', 'lock table public.rp166a_ref, public.rp166b_ref in access share mode');
select dblink_connect('conv', 'dbname=' || current_database());
select * from dblink('conv', 'select pg_backend_pid()') as t(cpid int) \gset
select dblink_exec('conv', $$call pgpm.transmute('public.rp166a', 'id', 1000::bigint, p_obtain => 2,
                                                 p_lock_timeout => '1s', p_incoming_fks => 'preserve')$$, false);
select dblink_exec('conv', $$call pgpm.transmute('public.rp166b', 'id', 1000::bigint, p_obtain => 2,
                                                 p_lock_timeout => '1s', p_incoming_fks => 'preserve')$$, false);
select dblink_exec('hold', 'commit');
select dblink_disconnect('hold');
select dblink_disconnect('conv');

select ok(pgpm_test166.gone(:cpid), 'LIVENESS: the converting session has gone');
select is(
  (select string_agg(parent_table::text || ':' || (not pgpm._session_alive(owner_pid, owner_backend_start))::text,
                     ',' order by parent_table::text)
     from pgpm.transmute_inflight),
  'rp166a:true,rp166b:true',
  'LIVENESS: both conversions are claimed and abandoned (owner dead)');
select is(
  (select string_agg(conrelid::regclass::text, ',' order by conrelid::regclass::text)
     from pg_constraint where conname = 'pgpm_monolith_bound'),
  'rp166a,rp166b',
  'LIVENESS: both tables still carry the bound');
select throws_ok($$ insert into public.rp166a values (1000000000000, 'outside') $$, '23514', null,
  'LIVENESS: the bound is live, rejecting an out-of-range write to a');

-- ======================= the reap, with a long reader on a =======================
select dblink_connect('reader', 'dbname=' || current_database());
select * from dblink('reader', 'select pg_backend_pid()') as t(rpid int) \gset
select dblink_exec('reader', 'begin');
select * from dblink('reader', 'select count(*) from public.rp166a') as t(n bigint);
select is(
  (select string_agg(mode, ',') from pg_locks
    where pid = :rpid and relation = 'public.rp166a'::regclass and granted),
  'AccessShareLock', 'LIVENESS: the reader holds ACCESS SHARE on a, which the reaper''s DROP CONSTRAINT conflicts with');

-- The caller's own lock_timeout: the session default, which is what pg_cron runs maintain_all under.
select is(current_setting('lock_timeout'), '0', 'LIVENESS: the reaper is called with no lock_timeout of its own');

-- Hang ceiling, not the assertion: a build that waits for the reader has this statement cancelled, and
-- the cancellation stops the file (pg_prove runs it under ON_ERROR_STOP), rather than hanging the suite.
set statement_timeout = '30s';
create temp table t166 as select clock_timestamp() as t0;
select is(pgpm._transmute_reap(), 1, 'the reap returns, having undone exactly one conversion');
select cmp_ok(clock_timestamp() - (select t0 from t166), '<', interval '20 seconds',
  'the reaper gave up on the held table rather than waiting for its reader');
reset statement_timeout;

select is(current_setting('lock_timeout'), '0', 'the caller''s lock_timeout is unchanged afterwards');
select is(
  (select state from pg_stat_activity where pid = :rpid), 'idle in transaction',
  'LIVENESS: the reader was still open for the whole reap');

select is(
  (select string_agg(conrelid::regclass::text, ',') from pg_constraint where conname = 'pgpm_monolith_bound'),
  'rp166a', 'the held table keeps its bound; the free one is restored');
select is(
  (select string_agg(parent_table::text, ',') from pgpm.transmute_inflight),
  'rp166a', 'and keeps its claim, so a later sweep finds it again');
select is(
  (select string_agg(parent_table::text, ',') from pgpm.log where action = 'transmute_reap'),
  'rp166b', 'transmute_reap is logged for the free table only');
select is(
  (select string_agg(parent_table::text || ':' || method, ',') from pgpm.log where action = 'skip_transmute_reap'),
  'rp166a:canceling statement due to lock timeout',
  'the held table''s deferral is logged, skip_transmute_reap, with the lock timeout as its reason');
select lives_ok($$ insert into public.rp166b values (1000000000000, 'outside') $$,
  'the free table takes an out-of-range write again');

-- ======================= the next pass, once the reader has gone =======================
select dblink_exec('reader', 'commit');
select dblink_disconnect('reader');

select is(pgpm._transmute_reap(), 1, 'the next reap undoes the deferred conversion');
select is(
  (select count(*)::int from pg_constraint where conname = 'pgpm_monolith_bound'), 0,
  'no bound is left on either table');
select is((select count(*)::int from pgpm.transmute_inflight), 0, 'no claim is left');
select is(
  (select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.log where action = 'transmute_reap'),
  'rp166a,rp166b', 'transmute_reap is now logged for both, once each');
select is(
  (select count(*)::int from pgpm.log where action = 'skip_transmute_reap'), 1,
  'and the one deferral was not repeated');
select lives_ok($$ insert into public.rp166a values (1000000000000, 'outside') $$,
  'the held table takes an out-of-range write again');

select * from finish();
