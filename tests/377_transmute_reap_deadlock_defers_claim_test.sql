-- A deadlock met in _transmute_reap's per-claim lock wait defers that claim to the next tick, as a lock timeout
-- does, instead of ending the whole maintain_all tick (issue #1231, B17-03).
--
-- The sweep reaps abandoned conversions one claim at a time, each under the table's ACCESS EXCLUSIVE, and keeps
-- the lock of a table it has reaped until maintain_all commits (B17-01). So waiting on the next claim's table
-- behind a reader, it holds the first: when that reader goes on to touch the first table, the two wait on each
-- other, and the sweep, which waited first, is the deadlock detector's victim. The per-claim handler caught only
-- lock_not_available, so 40P01 escaped it and ended the tick: the first table's finished reap rolled back with
-- it, and _detach_reap and every parent went unmaintained. It is caught beside the lock timeout now, and logged
-- the same way, skip_transmute_reap with the error, the claim and its bound left for the next tick.
--
-- Fixture, asymmetric: t1 (20 rows) and t2 (30 rows) each carry an abandoned claim and its NOT VALID bound, t1's
-- recorded first, so the sweep reaps t1 and then waits on t2, which a reader holds. The reader's own deadlock
-- timeout is set past the sweep's, so the sweep, not the reader, is the one the detector breaks the cycle in.
-- bench/transmute_reap_deadlock.sh runs this file against the mutant whose handler catches the timeout alone.
\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only true
create extension if not exists pgtap;
create extension if not exists dblink;
set timezone = 'UTC';
set client_min_messages = warning;
select plan(6);

create table t1 (id bigint not null, ts timestamptz not null, primary key (id, ts));
create table t2 (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into t1 select i, now() - i * interval '1 minute' from generate_series(1, 20) i;
insert into t2 select i, now() - i * interval '1 minute' from generate_series(1, 30) i;
select pgpm._ts_text(date_trunc('day', now() at time zone 'UTC' - interval '2 hours') at time zone 'UTC') as lo,
       pgpm._ts_text((date_trunc('day', now() at time zone 'UTC') + interval '1 day') at time zone 'UTC') as hi \gset
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz, control_attnum)
values ('t1'::regclass, 'public', 't1', 'time', :'lo', :'hi', 'UTC', 2);
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz, control_attnum)
values ('t2'::regclass, 'public', 't2', 'time', :'lo', :'hi', 'UTC', 2);
alter table t1 add constraint pgpm_monolith_bound check (ts >= :'lo'::timestamptz and ts < :'hi'::timestamptz) not valid;
alter table t2 add constraint pgpm_monolith_bound check (ts >= :'lo'::timestamptz and ts < :'hi'::timestamptz) not valid;

select dblink_connect('r377h', 'dbname=' || current_database() || ' user=postgres') is not null;
select dblink_connect('r377r', 'dbname=' || current_database() || ' user=postgres') is not null;
select dblink_exec('r377h', 'set deadlock_timeout = ''30s''') is not null;
select dblink_exec('r377h', 'begin') is not null;
select * from dblink('r377h', 'select count(*) from t2') as z(n bigint);
select * from dblink('r377r', 'select pg_backend_pid()') as z(pid int) \gset r_
select set_config('r377.rpid', :'r_pid', false) is not null;

-- each poll is its own statement's read of pg_locks, which is not snapshotted
create function pg_temp.r377_wait(p_pid int, p_rel regclass) returns boolean language plpgsql as $$
begin
  for i in 1 .. 250 loop
    if exists (select 1 from pg_locks where pid = p_pid and not granted and locktype = 'relation' and relation = p_rel) then
      return true;
    end if;
    perform pg_sleep(0.02);
  end loop;
  return false;
end $$;

select dblink_send_query('r377r', 'call pgpm.maintain_all()') = 1;
select ok(pg_temp.r377_wait(current_setting('r377.rpid')::int, 't2')
          and exists (select 1 from pg_locks where pid = current_setting('r377.rpid')::int and granted
                        and locktype = 'relation' and relation = 't1'::regclass and mode = 'AccessExclusiveLock'),
  'LIVENESS: the sweep holds t1, reaped, and waits on t2 behind the reader');
-- the reader's transaction goes on to read t1: each now waits on the other
select dblink_send_query('r377h', 'select count(*) from t1') = 1;
select * from dblink_get_result('r377r', false) as z(r text);
select dblink_error_message('r377r') as err \gset
select * from dblink_get_result('r377h', false) as z(n bigint);
select * from dblink_get_result('r377h', false) as z(n bigint);
select dblink_exec('r377h', 'commit') is not null;

select ok(:'err'::text ~ 'deadlock detected'
          or exists (select 1 from pgpm.log where parent_table = 't2'::regclass and action = 'skip_transmute_reap'
                        and method like 'deadlock detected%'),
  'LIVENESS: the sweep met the deadlock in t2''s lock wait (the tick raised it, or logged it as t2''s deferral)');
select is(:'err'::text, 'OK'::text, 'the tick does not end on one claim''s lock wait (maintain_all raised nothing)');
select ok(exists (select 1 from pgpm.log where parent_table = 't1'::regclass and action = 'transmute_reap')
          and not exists (select 1 from pg_constraint where conrelid = 't1'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 't1'::regclass),
  't1''s reap, done before the wait, survives the tick: its bound and claim are gone');
select is((select string_agg(action || ':' || left(method, 17), ',' order by id) from pgpm.log
            where parent_table = 't2'::regclass),
  'skip_transmute_reap:deadlock detected',
  't2 is deferred to the next tick, logged once as skip_transmute_reap with the deadlock');
select ok(exists (select 1 from pg_constraint where conrelid = 't2'::regclass and conname = 'pgpm_monolith_bound')
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 't2'::regclass),
  't2''s claim and bound are left exactly where they were, for the next tick');

select dblink_disconnect('r377h') is not null;
select dblink_disconnect('r377r') is not null;
select * from finish();
