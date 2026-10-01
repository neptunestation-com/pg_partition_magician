-- _detach_reap and transmute_abort bound their ACCESS EXCLUSIVE waits (issue #708).
--
-- THE BUG. #684 bounded _transmute_reap's and the hypertable swap's ACCESS EXCLUSIVE waits at transmute's
-- default (p_lock_timeout, 5 s), and left two more of the same kind in the core:
--   * _detach_reap's ALTER TABLE ... DETACH PARTITION ... FINALIZE, which maintain_all runs before any
--     lock_timeout is set (pg_cron's session default is 0: wait forever). One ordinary reader of the
--     abandoned partition (a report, a pg_dump) parked the reaper for that reader's whole life: the sweep
--     never reached a single parent, and every later access to the partition queued behind the pending
--     ACCESS EXCLUSIVE. It now carries transmute's bound like _transmute_reap, and a timeout lands in the
--     per-row handler it already had: fail_detach_reap, the partition left pending, the next tick retries.
--   * transmute_abort's ALTER TABLE ... DROP CONSTRAINT pgpm_monolith_bound, the same statement the reaper
--     runs, under whatever the operator's session had. It now takes p_lock_timeout (default '5s', as
--     transmute), and a timeout refuses with lock_not_available, changing nothing.
--
-- WHAT THIS FILE PINS, in one session plus dblink: each call returns (a pre-fix build hangs in the reap
-- until the hang ceiling below cancels the statement, which stops the file), the deferral is per row and
-- logged, the abort's refusal names the table and keeps the bound and the claim, the caller's lock_timeout
-- is untouched, a bad p_lock_timeout is refused, and once the reader has gone the next call does the work.
-- That an ordinary read or write is not held up behind either needs a THIRD concurrent session timing it,
-- which lives in bench/reap_and_abort_lock_timeout.sh with the mutations that put each unbounded wait back.
--
-- ASYMMETRIC FIXTURES. Two abandoned detaches (dra, drb) and one reader, on dra's partition only: the reap
-- must finalize exactly drb's and defer exactly dra's. A reaper that stopped at the first timeout finalizes
-- neither, one that ignored the lock waits for the reader, and each is a different name. Likewise two
-- abandoned conversions (aba, abb) with the reader on aba only: the abort refuses aba and undoes abb.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(30);

create schema pgpm_test198;
-- Poll until p_pid has left pg_stat_activity, clearing the per-transaction snapshot each turn (#713).
create function pgpm_test198.gone(p_pid int)
returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if not exists (select 1 from pg_stat_activity where pid = p_pid) then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;
-- Poll until the detach on p_parent has committed its pending flag AND session p_pid is parked in its
-- wait phase (a not-granted virtualxid lock). Catalogs and pg_locks only: it locks nothing the detach needs.
create function pgpm_test198.parked(p_parent regclass, p_pid int)
returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    if exists (select 1 from pg_inherits where inhparent = p_parent and inhdetachpending)
       and exists (select 1 from pg_locks where pid = p_pid and locktype = 'virtualxid' and not granted)
    then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

-- ======================= fixture 1: two REAL abandoned detaches =======================
create table public.dra (id bigint not null primary key, payload text);
insert into public.dra select g, 'a' from generate_series(1, 500) g;
call pgpm.transmute('public.dra', 'id', 1000::bigint, p_obtain => 3);
create table public.drb (id bigint not null primary key, payload text);
insert into public.drb select g, 'b' from generate_series(1, 300) g;
call pgpm.transmute('public.drb', 'id', 1000::bigint, p_obtain => 3);
select child_name as c_a from pgpm.part where parent_table = 'public.dra'::regclass and lo = '2000' \gset
select child_name as c_b from pgpm.part where parent_table = 'public.drb'::regclass and lo = '2000' \gset

-- A read-committed holder on both parents, pruned to their monoliths, parks each concurrent detach in its
-- wait phase; each detacher's session then dies there, which is what leaves the partition pending.
select dblink_connect('h', 'dbname=' || current_database());
select dblink_exec('h', 'begin');
select * from dblink('h', 'select count(*) from public.dra where id < 1000') as t(c bigint);
select * from dblink('h', 'select count(*) from public.drb where id < 1000') as t(c bigint);
select dblink_connect('xa', 'dbname=' || current_database());
select * from dblink('xa', 'select pg_backend_pid()') as t(xapid int) \gset
select dblink_send_query('xa', format('alter table public.dra detach partition public.%I concurrently', :'c_a'));
select dblink_connect('xb', 'dbname=' || current_database());
select * from dblink('xb', 'select pg_backend_pid()') as t(xbpid int) \gset
select dblink_send_query('xb', format('alter table public.drb detach partition public.%I concurrently', :'c_b'));
select ok(pgpm_test198.parked('public.dra', :xapid) and pgpm_test198.parked('public.drb', :xbpid),
  'LIVENESS: both detaches set their pending flag and parked in the wait phase');
select pg_terminate_backend(:xapid), pg_terminate_backend(:xbpid);
select ok(pgpm_test198.gone(:xapid) and pgpm_test198.gone(:xbpid), 'LIVENESS: both detachers'' sessions have died');
select dblink_exec('h', 'commit');
select dblink_disconnect('h');
select dblink_disconnect('xa');
select dblink_disconnect('xb');

select is(
  (select string_agg(c.relname, ',' order by c.relname) from pg_inherits i join pg_class c on c.oid = i.inhrelid
    where i.inhdetachpending),
  (select string_agg(n, ',' order by n) from unnest(array[:'c_a', :'c_b']::text[]) n),
  'LIVENESS: both partitions are left pending detach, abandoned');

-- The reader of dra's abandoned partition only.
select dblink_connect('reader', 'dbname=' || current_database());
select * from dblink('reader', 'select pg_backend_pid()') as t(rpid int) \gset
select dblink_exec('reader', 'begin');
select * from dblink('reader', format('select count(*) from public.%I', :'c_a')) as t(n bigint);
select is(
  (select string_agg(mode, ',') from pg_locks
    where pid = :rpid and relation = format('public.%I', :'c_a')::regclass and granted),
  'AccessShareLock',
  'LIVENESS: the reader holds ACCESS SHARE on dra''s partition, which FINALIZE''s ACCESS EXCLUSIVE conflicts with');
select is(current_setting('lock_timeout'), '0', 'LIVENESS: the reaper is called with no lock_timeout of its own');

-- Hang ceiling, not the assertion: a build that waits for the reader has this statement cancelled, and
-- the cancellation stops the file (pg_prove runs it under ON_ERROR_STOP), rather than hanging the suite.
set statement_timeout = '30s';
create temp table t198 (k text primary key, t0 timestamptz);
insert into t198 values ('reap', clock_timestamp());
select is(pgpm._detach_reap(), 1, 'the reap returns, having finalized exactly one detach');
select cmp_ok(clock_timestamp() - (select t0 from t198 where k = 'reap'), '<', interval '20 seconds',
  'the reaper gave up on the held partition rather than waiting for its reader');
reset statement_timeout;

select is(current_setting('lock_timeout'), '0', 'the caller''s lock_timeout is unchanged afterwards');
select is((select state from pg_stat_activity where pid = :rpid), 'idle in transaction',
  'LIVENESS: the reader was still open for the whole reap');
select is(
  (select string_agg(c.relname, ',') from pg_inherits i join pg_class c on c.oid = i.inhrelid
    where i.inhdetachpending),
  :'c_a', 'the held partition is still pending; the free one is finalized');
select is(
  (select string_agg(parent_table::text, ',') from pgpm.log where action = 'detach_reap'),
  'drb', 'detach_reap is logged for the free parent only');
select is(
  (select string_agg(parent_table::text || ':' || method, ',') from pgpm.log where action = 'fail_detach_reap'),
  'dra:canceling statement due to lock timeout',
  'the held partition''s deferral is logged, fail_detach_reap, with the lock timeout as its reason');

-- The next pass, once the reader has gone.
select dblink_exec('reader', 'commit');
select dblink_disconnect('reader');
select is(pgpm._detach_reap(), 1, 'the next reap finalizes the deferred detach');
select is((select count(*)::int from pg_inherits where inhdetachpending), 0, 'no partition is left pending');
select is(
  (select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.log where action = 'detach_reap'),
  'dra,drb', 'detach_reap is now logged for both, once each');
select is((select count(*)::int from pgpm.log where action = 'fail_detach_reap'), 1,
  'and the one deferral was not repeated');

-- ======================= fixture 2: two REAL abandoned conversions =======================
-- A holder keeps both referencing tables locked, so each conversion's cutover times out dropping the
-- preserved incoming key after phase 1 committed the bound and the claim; the converting session then
-- disconnects, so both claims have a dead owner (tests/166's fixture).
create table public.aba (id bigint primary key, body text);
insert into public.aba select g, 'a' || g from generate_series(1, 50) g;
create table public.aba_ref (rid bigint primary key, id bigint references public.aba);
create table public.abb (id bigint primary key, body text);
insert into public.abb select g, 'b' || g from generate_series(1, 30) g;
create table public.abb_ref (rid bigint primary key, id bigint references public.abb);

select dblink_connect('hold', 'dbname=' || current_database());
select dblink_exec('hold', 'begin');
select dblink_exec('hold', 'lock table public.aba_ref, public.abb_ref in access share mode');
select dblink_connect('conv', 'dbname=' || current_database());
select * from dblink('conv', 'select pg_backend_pid()') as t(cpid int) \gset
select dblink_exec('conv', $$call pgpm.transmute('public.aba', 'id', 1000::bigint, p_obtain => 2,
                                                 p_lock_timeout => '1s', p_incoming_fks => 'preserve')$$, false);
select dblink_exec('conv', $$call pgpm.transmute('public.abb', 'id', 1000::bigint, p_obtain => 2,
                                                 p_lock_timeout => '1s', p_incoming_fks => 'preserve')$$, false);
select dblink_exec('hold', 'commit');
select dblink_disconnect('hold');
select dblink_disconnect('conv');
select ok(pgpm_test198.gone(:cpid), 'LIVENESS: the converting session has gone');
select is(
  (select string_agg(parent_table::text || ':' || (not pgpm._session_alive(owner_pid, owner_backend_start))::text
                     || ':' || exists (select 1 from pg_constraint c
                                        where c.conrelid = i.parent_table and c.conname = 'pgpm_monolith_bound'),
                     ',' order by parent_table::text)
     from pgpm.transmute_inflight i),
  'aba:true:true,abb:true:true',
  'LIVENESS: both conversions are claimed, abandoned, and still carry the bound');

-- The reader of aba only.
select dblink_connect('reader2', 'dbname=' || current_database());
select * from dblink('reader2', 'select pg_backend_pid()') as t(r2pid int) \gset
select dblink_exec('reader2', 'begin');
select * from dblink('reader2', 'select count(*) from public.aba') as t(n bigint);
select is(
  (select string_agg(mode, ',') from pg_locks where pid = :r2pid and relation = 'public.aba'::regclass and granted),
  'AccessShareLock', 'LIVENESS: the reader holds ACCESS SHARE on aba, which the DROP CONSTRAINT conflicts with');

-- Same hang ceiling as the reap: a build that waits for the reader is cancelled, which stops the file.
set statement_timeout = '30s';
insert into t198 values ('abort', clock_timestamp());
select throws_ok($$ select pgpm.transmute_abort('public.aba') $$, '55P03', NULL,
  'transmute_abort, with the default bound, refuses the held table with lock_not_available');
select cmp_ok(clock_timestamp() - (select t0 from t198 where k = 'abort'), '<', interval '20 seconds',
  'it gave up rather than waiting for the reader');
insert into t198 values ('abort1s', clock_timestamp());
select throws_like($$ select pgpm.transmute_abort('public.aba', p_lock_timeout => '1s') $$,
  'pg_partition_magician: transmute_abort(aba) could not take ACCESS EXCLUSIVE on aba within 1s%',
  'a shorter p_lock_timeout is honoured, and the refusal names the table and the bound it waited');
select cmp_ok(clock_timestamp() - (select t0 from t198 where k = 'abort1s'), '<', interval '4 seconds',
  'within that shorter bound');
reset statement_timeout;
select throws_like($$ select pgpm.transmute_abort('public.abb', p_lock_timeout => 'soon') $$,
  'pg_partition_magician: p_lock_timeout must be a valid lock_timeout value (got soon)%',
  'a bad p_lock_timeout is refused');

select is(current_setting('lock_timeout'), '0', 'the caller''s lock_timeout is unchanged by the refusals');
select ok(pgpm.transmute_abort('public.abb'), 'the free table is aborted while the reader is still on aba');
select is(
  (select string_agg(parent_table::text, ',') from pgpm.transmute_inflight)
    || '/' || (select string_agg(conrelid::regclass::text, ',') from pg_constraint where conname = 'pgpm_monolith_bound')
    || '/' || (select string_agg(parent_table::text, ',') from pgpm.log where action = 'transmute_abort'),
  'aba/aba/abb',
  'aba keeps its claim and its bound; only abb is undone, and only abb is logged');
select is(current_setting('lock_timeout'), '0', 'the caller''s lock_timeout is unchanged by the abort that succeeded');

select dblink_exec('reader2', 'commit');
select dblink_disconnect('reader2');
select ok(pgpm.transmute_abort('public.aba'), 'once the reader has gone the abort of aba goes through');
select is(
  (select count(*)::int from pgpm.transmute_inflight)
    || '/' || (select count(*)::int from pg_constraint where conname = 'pgpm_monolith_bound')
    || '/' || (select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.log where action = 'transmute_abort'),
  '0/0/aba,abb', 'no claim or bound is left, and each abort is logged once');

select * from finish();
