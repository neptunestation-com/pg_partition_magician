-- The tracking delta follows the hypertable's writers through the online window (issue #979).
--
-- A tracking from_hypertable_copy's capture trigger wrote the delta (<rel>_pgpm_delta) as the WRITER, so every
-- role that could write the hypertable needed INSERT on it (since #1073 the capture is SECURITY DEFINER and
-- writes as its owner, so a write no longer depends on these grants; the grants are still made and re-synced,
-- and this file checks them by the delta's privileges). The copy granted that
-- once, to the roles that could write the hypertable at copy time (_regrain_capture_grant), and nothing granted
-- again: a role granted DML on the hypertable during the online window had every write refused 'permission
-- denied for table <rel>_pgpm_delta' until the cutover. Core's regrain re-grants on every tick (#496); the
-- module's ticks are its drains, its drain steps and its cutover, and each now re-syncs the delta's writer
-- grants before it acts (_from_hypertable_scratch_follow), so a role granted mid-window writes from the next
-- one on, as a role granted mid-regrain does from the next tick.
--
-- SITE 1, a drain step: w52_late is granted INSERT on the hypertable after the copy; one
-- from_hypertable_drain_delta_step later it writes, and the delta captured its key.
-- SITE 2, the drain procedure on its own: w52_proc is granted after the delta has been drained empty, so the
-- procedure's loop never calls the step; one CALL of from_hypertable_drain_delta later it writes.
-- The cutover calls the same helper at its top; tests/timescale/db/53 pins that site through the owner half.
--
-- Each negative is paired with a liveness witness: before the step, the late role holds INSERT on the
-- hypertable and none on the delta (so the step is what grants it), and the step reconciled the change
-- w52_early made. w52_never, which holds nothing on the hypertable, is granted nothing on the delta: the
-- re-sync follows the hypertable's ACL, not "every role". ASYMMETRIC: 30 rows copied; three writers each add
-- one row with a distinct key (1001, 1002, 1003), named by identity in the delta.
-- Roles are named, never `to current_user` (that segfaults a backend on the fleet image), created only when
-- absent, and dropped at the end. bench/hypertable_delta_writer_grants.sh runs this file against the
-- hypertable_delta_grants_not_resynced mutant, which it must FAIL.
select plan(11);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'w52_early') then create role w52_early; end if;
  if not exists (select 1 from pg_roles where rolname = 'w52_late') then create role w52_late; end if;
  if not exists (select 1 from pg_roles where rolname = 'w52_proc') then create role w52_proc; end if;
  if not exists (select 1 from pg_roles where rolname = 'w52_never') then create role w52_never; end if;
end $$;
grant w52_early, w52_late, w52_proc, w52_never to postgres;   -- by name: this session writes as each below
grant usage on schema public to w52_early, w52_late, w52_proc, w52_never;

create table public.g52 (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.g52', 'ts', chunk_time_interval => interval '1 day');
insert into public.g52 select timestamptz '2024-01-01 00:00+00' + n * interval '2 hours', n, n from generate_series(1, 30) n;
grant insert, select on public.g52 to w52_early;
call pgpm.from_hypertable_copy('public.g52', 'ts', p_track_changes => true);
select pgpm._scratch_rel('public.g52', 'hypertable_delta')::text as delta \gset
grant insert, select on public.g52 to w52_late;

-- the delta's keys, by identity
create function w52_delta_ids() returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  execute format('select array_agg(distinct id order by id) from %s', pgpm._scratch_rel('public.g52', 'hypertable_delta')) into v;
  return v;
end $f$;

select ok(:'delta' is not null and has_table_privilege('w52_early', :'delta', 'INSERT'),
  'LIVENESS: the tracking copy recorded its delta and gave the writer it saw (w52_early) INSERT on it');
set role w52_early;
insert into public.g52 values ('2024-01-01 01:00+00', 1001, 1);
reset role;
select ok(has_table_privilege('w52_late', 'public.g52', 'INSERT') and not has_table_privilege('w52_late', :'delta', 'INSERT'),
  'LIVENESS: w52_late, granted INSERT on the hypertable after the copy, holds none on the delta before a drain step');

-- SITE 1: one drain step
select is(pgpm.from_hypertable_drain_delta_step('public.g52', 'ts'), 1::bigint,
  'LIVENESS: the drain step ran and reconciled w52_early''s one change (key 1001)');
select ok(has_table_privilege('w52_late', :'delta', 'INSERT'),
  'the drain step granted INSERT on the delta to w52_late, which can write the hypertable');
set role w52_late;
select lives_ok($$ insert into public.g52 values ('2024-01-01 03:00+00', 1002, 2) $$,
  'a role granted INSERT on the hypertable during the online window writes it after the next drain step');
reset role;
select is(w52_delta_ids(), array[1002]::bigint[],
  'the capture trigger logged w52_late''s write by its key (1002) and nothing else is pending');
select ok(not has_table_privilege('w52_never', :'delta', 'INSERT') and not has_table_privilege('w52_never', 'public.g52', 'INSERT'),
  'the drain step granted nothing to w52_never, which cannot write the hypertable');

-- SITE 2: the drain procedure, with the delta already empty so its loop never reaches the step
select pgpm.from_hypertable_drain_delta_step('public.g52', 'ts') as drained \gset
grant insert, select on public.g52 to w52_proc;
select ok(w52_delta_ids() is null and not has_table_privilege('w52_proc', :'delta', 'INSERT'),
  'LIVENESS: a second step drained the delta empty, and w52_proc, granted after it, holds no INSERT on it');
call pgpm.from_hypertable_drain_delta('public.g52', 'ts');
select ok(has_table_privilege('w52_proc', :'delta', 'INSERT'),
  'from_hypertable_drain_delta granted INSERT on the delta to w52_proc although it had nothing to drain');
set role w52_proc;
select lives_ok($$ insert into public.g52 values ('2024-01-01 05:00+00', 1003, 3) $$,
  'a role granted INSERT on the hypertable during the online window writes it after the next drain');
reset role;
select is(w52_delta_ids(), array[1003]::bigint[], 'the capture trigger logged w52_proc''s write by its key (1003)');

select * from finish();

-- roles are cluster-wide: leave none behind. Everything they hold a grant on goes first.
select pgpm._scratch_rel('public.g52', 'hypertable_dest')::text as dest \gset
drop table public.g52;
drop table :delta, :dest;
revoke usage on schema public from w52_early, w52_late, w52_proc, w52_never;
drop role w52_early, w52_late, w52_proc, w52_never;
