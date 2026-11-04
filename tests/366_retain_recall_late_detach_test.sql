-- A detach run pg_cron started before the recall's re-attach committed is taken back by the next tick
-- (issue #1438).
--
-- THE BUG. _retain_recall's re-attach branch returned the pgpm_detach job to idle, re-attached the partition
-- and cleared its retirement marker in ONE transaction. pg_cron reads a job's command from a cache that only a
-- commit refreshes, so a run it started while that transaction was open still carried the armed
-- `DETACH ... CONCURRENTLY`. Queued on the parent behind the ATTACH, it detached the partition again once the
-- recall committed. The row was left attached-looking with no marker: the next tick found nothing to take back,
-- the rows went unserved, the log ended at retain_reattach and status() counted nothing. Only a later tightening
-- noticed, and then refused the table as the operator's (fail_retain_drop), keeping it out for good.
--
-- No operator is involved: pgpm's own run detaches the partition, set_retain loosens retention (its recall only
-- recalls, so the job stays armed), and the tick's recall re-attaches it while the next cadence's run is queued.
--
-- THE CONTRACT.
--   A recalled retirement keeps its marker and pgpm's dispatch record, stamped recalled_at, until retention
--   reaches it again (retire() re-dispatches and clears recalled_at), so a late run's detach is pgpm's own
--   retirement on any later tick and the tick re-attaches it once more. status().retain_detaching does not count
--   a recalled mark. A caller that cannot see the pgpm_detach job (pg_cron shows a job only to its owner and to
--   superusers) is refused, fail_retain_recall, and neither recalls nor re-attaches.
--
-- TWO SESSIONS, ordered by locks, not by time: dblink connection `rc` runs the recall (retain(), the call
-- maintain makes) inside an open transaction; connection `rd` sends the armed command, as pg_cron's worker
-- would, and is seen waiting on the parent's lock in pg_locks before `rc` commits. pg_cron itself is a stand-in
-- catalog (cron.job and cron.alter_job), as in tests/194: the late run's command is the text the job held
-- before the recall, which is what a run started inside the recall's transaction carries.
--
-- ASYMMETRIC FIXTURE. The doomed partition [0, 10000) holds ids 1, 2, 3; the frontier partition holds 50005 and
-- another holds 30001, so a re-attach of the wrong relation or a lost row cannot pass for the right answer.

create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

select plan(66);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

create table public.rl366 (id bigint primary key, payload text);
create schema pgpm_test366;
create function pgpm_test366.ids(p_below bigint) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  select array_agg(id order by id) into v from public.rl366 where id < p_below;
  return v;
end;
$$;
create function pgpm_test366.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
$$;
create function pgpm_test366.attached(p_oid oid) returns boolean language sql as $$
  select exists (select 1 from pg_inherits
                  where inhparent = 'public.rl366'::regclass and inhrelid = p_oid and not inhdetachpending)
$$;
create function pgpm_test366.actions() returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log
   where parent_table = 'public.rl366'::regclass and lo = '0'
     and action in ('retain_detach', 'retain_recall', 'retain_reattach', 'fail_retain_reattach',
                    'retain_drop', 'fail_retain_drop', 'fail_retain_identity', 'retain_disown')
$$;
-- a backend of this application_name waiting on any lock at all (a concurrent detach's second phase waits on the
-- virtual transaction ids of older snapshots, not on a relation)
create function pgpm_test366.wait_for_any(p_app text) returns boolean language plpgsql as $$
begin
  for i in 1 .. 3000 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                where a.application_name = p_app and not l.granted) then
      return true;
    end if;
    perform pg_sleep(0.01);
  end loop;
  return false;
end;
$$;
create function pgpm_test366.on_parent(p_parent regclass, p_oid oid) returns boolean language sql as $$
  select exists (select 1 from pg_inherits where inhparent = p_parent and inhrelid = p_oid and not inhdetachpending)
$$;
create function pgpm_test366.served(p_parent regclass, p_below bigint) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  execute format('select array_agg(id order by id) from %s where id < %s', p_parent, p_below) into v;
  return v;
end;
$$;
-- polled server-side: pg_locks is read live, so one call can wait for another backend's lock request
create function pgpm_test366.wait_for_waiter(p_app text) returns boolean language plpgsql as $$
begin
  for i in 1 .. 3000 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                where a.application_name = p_app and not l.granted
                  and l.relation = 'public.rl366'::regclass) then
      return true;
    end if;
    perform pg_sleep(0.01);
  end loop;
  return false;
end;
$$;

insert into public.rl366 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.rl366', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rl366', '60000');
insert into public.rl366 values (30001, 'other'), (50005, 'frontier');
create table public.rl366_ref (id bigint primary key, p_id bigint references public.rl366(id));
insert into public.rl366_ref values (1, 50005);
select child_name as doomed, child_oid as doomed_oid from pgpm.part
 where parent_table = 'public.rl366'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rl366', :'doomed'), 'fixture: retire() dispatches the concurrent detach');
select pgpm_test366.armed() as cmd \gset
select is(:'cmd', format('alter table public.rl366 detach partition public.%I concurrently', :'doomed'),
  'LIVENESS: the standing job is armed with this partition''s detach');

-- pgpm's own run lands
select :'cmd' \gexec
select ok(not pgpm_test366.attached(:'doomed_oid'), 'LIVENESS: pgpm''s first run detached the partition');

select pgpm.set_retain('public.rl366', '45000');
select is(pgpm_test366.armed(), :'cmd',
  'LIVENESS: set_retain''s recall leaves a detached retirement''s job armed, so the next run starts with the detach');

-- the tick's recall, held open after its re-attach; the next cadence's run is sent meanwhile
select dblink_connect('rc', 'dbname=' || current_database() || ' application_name=rl366_recall');
select dblink_connect('rd', 'dbname=' || current_database() || ' application_name=rl366_run');
select dblink_exec('rc', 'begin');
select * from dblink('rc', $q$ select pgpm.retain('public.rl366'::regclass)::text $q$) as t(n text);
select ok(exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                   where a.application_name = 'rl366_recall' and l.granted
                     and l.relation = 'public.rl366'::regclass and l.mode = 'ShareUpdateExclusiveLock'),
  'LIVENESS: the recall holds the re-attach''s lock on the parent, uncommitted');
select dblink_send_query('rd', :'cmd');
select ok(pgpm_test366.wait_for_waiter('rl366_run'),
  'LIVENESS: the run''s DETACH is queued on the parent behind the re-attach');
select dblink_exec('rc', 'commit');
select is(t.r, 'ALTER TABLE', 'LIVENESS: once the recall committed, the queued run detached the partition again')
  from dblink_get_result('rd') as t(r text);
select dblink_get_result('rd');
select dblink_disconnect('rd');
select dblink_disconnect('rc');

select is(pgpm_test366.actions(), array['retain_detach', 'retain_reattach'],
  'LIVENESS: the recall took the re-attach branch, logged retain_reattach');
select ok(not pgpm_test366.attached(:'doomed_oid'), 'LIVENESS: the partition is out of the parent after the race');
select is(pgpm_test366.ids(20000), null::bigint[], 'LIVENESS: ids 1, 2, 3 are unserved after the race');

select results_eq($$ select retiring_at is not null, detach_dispatched_oid from pgpm.part
                      where parent_table = 'public.rl366'::regclass and lo = '0' $$,
  format('values (true, %s::oid)', :'doomed_oid'),
  'the re-attach kept the marker and pgpm''s dispatch record, so the late detach is still pgpm''s own retirement');

call pgpm.maintain('public.rl366');

select ok(pgpm_test366.attached(:'doomed_oid'), 'the next tick re-attached the same relation, by oid');
select is(pgpm_test366.ids(20000), array[1, 2, 3]::bigint[], 'ids 1, 2, 3 are served by the parent again');
select is(pgpm_test366.actions(), array['retain_detach', 'retain_reattach', 'retain_reattach'],
  'logged as exactly retain_detach, retain_reattach, retain_reattach');
select is(pgpm_test366.armed(), 'select 1', 'the standing job is idle');

call pgpm.maintain('public.rl366');
call pgpm.maintain('public.rl366');

select ok(pgpm_test366.attached(:'doomed_oid'), 'two further ticks leave the partition attached');
select results_eq($$ select retiring_at is not null, detach_dispatched_oid, recalled_at is not null from pgpm.part
                      where parent_table = 'public.rl366'::regclass and lo = '0' $$,
  format('values (true, %s::oid, true)', :'doomed_oid'),
  'with the job idle and no detach of it running, the ticks keep the marker and the dispatch record, stamped recalled');
select is(pgpm_test366.ids(20000), array[1, 2, 3]::bigint[], 'ids 1, 2, 3 are still served');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'public.rl366'::regclass $$,
  $$ values (0::bigint, 0::bigint) $$, 'status() reports nothing failed and nothing detaching');

-- a run of the old command that lands only now (a background worker's cache, a launcher that has not looked)
select :'cmd' \gexec
select ok(not pgpm_test366.attached(:'doomed_oid'), 'LIVENESS: a run landing three ticks later detached the partition');
call pgpm.maintain('public.rl366');
select ok(pgpm_test366.attached(:'doomed_oid'), 'the next tick re-attached it, the kept marker naming it pgpm''s own');
select is(pgpm_test366.ids(20000), array[1, 2, 3]::bigint[], 'ids 1, 2, 3 are served again');
select lives_ok($$ insert into public.rl366_ref values (2, 2) $$,
  'a referencing row can point into the re-attached range');

-- ============ PART B: set_retain and retain() in ONE transaction, a run started while it is open ============
-- The recall's attached branch: set_retain idles the armed job and keeps the mark, and retain() in the same
-- transaction found the job idle and cleared it. The idle was not committed, so a run pg_cron started meanwhile
-- still carried the armed detach; it waited on the transaction and detached the partition once it committed, under
-- no mark. The clear now waits for a transaction that did not idle the job. Ids 11, 12 in the doomed partition.
create table public.rl366b (id bigint primary key, payload text);
insert into public.rl366b values (11, 'k'), (12, 'l');
call pgpm.transmute('public.rl366b', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rl366b', '60000');
insert into public.rl366b values (50005, 'frontier');
create table public.rl366b_ref (id bigint primary key, p_id bigint references public.rl366b(id));
insert into public.rl366b_ref values (1, 50005);
select child_name as b_doomed, child_oid as b_oid from pgpm.part
 where parent_table = 'public.rl366b'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rl366b', :'b_doomed'), 'fixture: (B) retire() dispatches the concurrent detach');
select pgpm_test366.armed() as b_cmd \gset
select is(:'b_cmd', format('alter table public.rl366b detach partition public.%I concurrently', :'b_doomed'),
  'LIVENESS: (B) the job is armed with the still-attached partition''s detach');

select dblink_connect('tb', 'dbname=' || current_database() || ' application_name=rl366b_txn');
select dblink_connect('rb', 'dbname=' || current_database() || ' application_name=rl366b_run');
select dblink_exec('tb', 'begin');
select * from dblink('tb', $q$ select pgpm.set_retain('public.rl366b', '45000')::text $q$) as t(r text);
select * from dblink('tb', $q$ select pgpm.retain('public.rl366b'::regclass)::text $q$) as t(r text);
select is(t.c, 'select 1', 'LIVENESS: (B) inside the transaction the job is idle, uncommitted')
  from dblink('tb', $q$ select command from cron.job where jobname = 'pgpm_detach' $q$) as t(c text);
select dblink_send_query('rb', :'b_cmd');
select ok(pgpm_test366.wait_for_any('rl366b_run'),
  'LIVENESS: (B) the run''s detach is waiting on the open transaction');
select dblink_exec('tb', 'commit');
select is(t.r, 'ALTER TABLE', 'LIVENESS: (B) once the transaction committed, the run detached the partition')
  from dblink_get_result('rb') as t(r text);
select dblink_get_result('rb');
select dblink_disconnect('rb');
select dblink_disconnect('tb');
select ok(not pgpm_test366.on_parent('public.rl366b', :'b_oid'), 'LIVENESS: (B) the partition is out of the parent');

select results_eq($$ select retiring_at is not null, detach_dispatched_oid from pgpm.part
                      where parent_table = 'public.rl366b'::regclass and lo = '0' $$,
  format('values (true, %s::oid)', :'b_oid'),
  'B: the transaction that idled the job did not clear the mark or the dispatch record');

call pgpm.maintain('public.rl366b');
select ok(pgpm_test366.on_parent('public.rl366b', :'b_oid'), 'B: the next tick re-attached the same relation');
select is(pgpm_test366.served('public.rl366b', 20000), array[11, 12]::bigint[], 'B: ids 11, 12 are served again');
select isnt((select retiring_at from pgpm.part where parent_table = 'public.rl366b'::regclass and lo = '0'),
  null, 'LIVENESS: (C) the re-attach kept B''s mark, older than any other, with the job idle');

-- ============ PART C: a mark kept with the job idle does not hold the one detach slot ============
-- One detach is in flight at a time, database-wide, and a retirement yields to an older one. A mark kept by a
-- recall (or one whose retirement was refused before its dispatch) is no detach in flight: the job does not hold
-- it. Yielding to it stalled every other table's referenced retirement until its parent ticked again (never, if
-- paused). Another parent's retirement now dispatches while B's mark is kept. Id 21 in its doomed partition.
create table public.rl366c (id bigint primary key, payload text);
insert into public.rl366c values (21, 'u');
call pgpm.transmute('public.rl366c', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rl366c', '60000');
insert into public.rl366c values (50005, 'frontier');
create table public.rl366c_ref (id bigint primary key, p_id bigint references public.rl366c(id));
insert into public.rl366c_ref values (1, 50005);
select child_name as c_doomed from pgpm.part where parent_table = 'public.rl366c'::regclass and lo = '0' \gset
select is(pgpm_test366.armed(), 'select 1', 'LIVENESS: (C) the job is idle');

select ok(not pgpm.retire('public.rl366c', :'c_doomed'), 'fixture: (C) retire() of the other parent''s partition returns');
select is(pgpm_test366.armed(), format('alter table public.rl366c detach partition public.%I concurrently', :'c_doomed'),
  'C: it dispatched its detach rather than yield to B''s kept mark');
select pgpm_test366.armed() as c_cmd_run \gset

call pgpm.maintain('public.rl366b');
select isnt((select recalled_at from pgpm.part where parent_table = 'public.rl366b'::regclass and lo = '0'),
  null, 'B: a later tick, the job holding another detach, keeps B''s mark, recalled');
select is(pgpm_test366.served('public.rl366b', 20000), array[11, 12]::bigint[], 'B: ids 11, 12 are still served');

-- ============ PART D: retention reaches a recalled retirement again ============
-- retire() dispatches its detach anew and clears recalled_at: the mark is a detach in flight once more, and
-- status() counts it. C's detach is run first, so the slot is free.
select :'c_cmd_run' \gexec
select ok(not pgpm_test366.on_parent('public.rl366c', (select child_oid from pgpm.part where parent_table = 'public.rl366c'::regclass and lo = '0')),
  'LIVENESS: (D) C''s detach landed, so no attached retirement holds the slot');
update pgpm.config set retain = '25000' where parent_table = 'public.rl366b'::regclass;   -- set_retain refuses a tightening that drops
select ok(not pgpm.retire('public.rl366b', :'b_doomed'), 'fixture: (D) retire() of B''s recalled partition returns');
select is(pgpm_test366.armed(), :'b_cmd', 'LIVENESS: (D) retire() re-dispatched B''s detach');
select is((select recalled_at from pgpm.part where parent_table = 'public.rl366b'::regclass and lo = '0'),
  null, 'D: the re-dispatch clears recalled_at');
select is((select retain_detaching from pgpm.status() where parent = 'public.rl366b'::regclass), 1::bigint,
  'D: status() counts B''s retirement as detaching again');
select :'b_cmd' \gexec
select ok(not pgpm_test366.on_parent('public.rl366b', :'b_oid'), 'LIVENESS: (D) B''s detach landed');

-- ============ PART E: a caller that cannot see the job is refused ============
-- pg_cron shows a job only to its owner (cron.job's row-level policy) and to superusers. The table's owner, a
-- non-superuser, loosens retention and catches up: it cannot idle the armed job, so its recall must not be taken
-- for one. Refused at the attached site, and again at the re-attach site once the run lands; a superuser's tick
-- then recalls and re-attaches. Ids 31, 32, 33 in the doomed partition.
create table public.rl366e (id bigint primary key, payload text);
insert into public.rl366e values (31, 'x'), (32, 'y'), (33, 'z');
call pgpm.transmute('public.rl366e', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rl366e', '60000');
insert into public.rl366e values (50005, 'frontier');
create table public.rl366e_ref (id bigint primary key, p_id bigint references public.rl366e(id));
insert into public.rl366e_ref values (1, 50005);
select child_name as e_doomed, child_oid as e_oid from pgpm.part
 where parent_table = 'public.rl366e'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rl366e', :'e_doomed'), 'fixture: (E) retire() dispatches the concurrent detach');
select pgpm_test366.armed() as e_cmd \gset
select is(:'e_cmd', format('alter table public.rl366e detach partition public.%I concurrently', :'e_doomed'),
  'LIVENESS: (E) the job is armed with the partition''s detach');

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'pgpm_test366_owner') then
    execute 'reassign owned by pgpm_test366_owner to current_user';
    execute 'drop owned by pgpm_test366_owner'; execute 'drop role pgpm_test366_owner';
  end if;
end $$;
create role pgpm_test366_owner nologin;
alter table cron.job enable row level security;
create policy job_owner on cron.job using (false);   -- a job another role owns
grant usage on schema cron to pgpm_test366_owner;
grant select on cron.job to pgpm_test366_owner;
grant usage on schema pgpm to pgpm_test366_owner;
grant select, insert, update, delete on all tables in schema pgpm to pgpm_test366_owner;
grant usage on all sequences in schema pgpm to pgpm_test366_owner;
-- the owner owns the table and every partition, so a re-attach it should not make would succeed
select format('alter table %s owner to pgpm_test366_owner', c) from (
  select 'public.rl366e'::regclass as c
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rl366e'::regclass) t \gexec

set role pgpm_test366_owner;
select set_config('pgpm_test366.seen', (select count(*) from cron.job)::text, false);
select pgpm.set_retain('public.rl366e', '45000');
select pgpm.retain('public.rl366e'::regclass);
reset role;
select is(current_setting('pgpm_test366.seen'), '0', 'LIVENESS: (E) the owner role sees no job in cron.job');
select is(pgpm_test366.armed(), :'e_cmd', 'LIVENESS: (E) the job is still armed: the owner could not idle it');
select is(pgpm_test366.served('public.rl366e', 20000), array[31, 32, 33]::bigint[], 'LIVENESS: (E) ids 31, 32, 33 are served');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'public.rl366e'::regclass and lo = '0'),
  array['retain_detach', 'fail_retain_recall', 'fail_retain_recall'],
  'E: set_retain''s recall and retain()''s are each refused, fail_retain_recall');
select ok((select bool_and(position('pgpm_test366_owner' in method) > 0) from pgpm.log
            where parent_table = 'public.rl366e'::regclass and action = 'fail_retain_recall'),
  'E: the refusal names the role');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'public.rl366e'::regclass $$,
  $$ values (2::bigint, 1::bigint) $$, 'E: status() counts both refusals, and the retirement as still detaching');
select is((select recalled_at from pgpm.part where parent_table = 'public.rl366e'::regclass and lo = '0'),
  null, 'E: the refused retirement is not stamped recalled');

-- the run lands; the owner's next catch-up meets the re-attach site
select :'e_cmd' \gexec
select ok(not pgpm_test366.on_parent('public.rl366e', :'e_oid'), 'LIVENESS: (E) the run detached the partition');
set role pgpm_test366_owner;
select pgpm.retain('public.rl366e'::regclass);
reset role;
select ok(not pgpm_test366.on_parent('public.rl366e', :'e_oid'),
  'E: the owner''s recall did not re-attach under a job it cannot idle');
select is((select relowner::regrole::text from pg_class where oid = :'e_oid'), 'pgpm_test366_owner',
  'LIVENESS: (E) the owner owns the detached partition, so nothing but the refusal kept it from re-attaching');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'public.rl366e'::regclass and lo = '0'),
  array['retain_detach', 'fail_retain_recall', 'fail_retain_recall', 'fail_retain_recall'],
  'E: refused again at the re-attach site');

call pgpm.maintain('public.rl366e');
select ok(pgpm_test366.on_parent('public.rl366e', :'e_oid'), 'E: a superuser''s tick re-attached it');
select is(pgpm_test366.served('public.rl366e', 20000), array[31, 32, 33]::bigint[], 'E: ids 31, 32, 33 are served again');
select is(pgpm_test366.armed(), 'select 1', 'E: and the job is idle');

-- ============ PART F: what is not refused ============
-- The refusal is for a caller to whom an existing job is invisible. A superuser sees every job, so one that sees
-- none sees that there is none (unscheduled after the dispatch: nothing is left to run the detach), and in a
-- database with no pg_cron nothing can be armed at all. Both recall as before. C's detach landed in part D;
-- F's partition is still attached. Id 41 in F's doomed partition.
create table public.rl366f (id bigint primary key, payload text);
insert into public.rl366f values (41, 'f');
call pgpm.transmute('public.rl366f', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rl366f', '60000');
insert into public.rl366f values (50005, 'frontier');
create table public.rl366f_ref (id bigint primary key, p_id bigint references public.rl366f(id));
insert into public.rl366f_ref values (1, 50005);
select child_name as f_doomed from pgpm.part where parent_table = 'public.rl366f'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rl366f', :'f_doomed'), 'fixture: (F) retire() dispatches the concurrent detach');
select ok(pgpm_test366.armed() like 'alter table public.rl366f detach partition %',
  'LIVENESS: (F) the job is armed with F''s detach, so F''s mark records a dispatch');

delete from cron.job;   -- unscheduled
select pgpm.set_retain('public.rl366c', '45000');
call pgpm.maintain('public.rl366c');
select ok(pgpm_test366.on_parent('public.rl366c', (select child_oid from pgpm.part where parent_table = 'public.rl366c'::regclass and lo = '0')),
  'F: a superuser that sees no job, there being none, re-attaches C''s partition');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rl366c'::regclass and action = 'fail_retain_recall'),
  0, 'F: and is not refused');

drop schema cron cascade;   -- no pg_cron in this database
grant select on public.rl366f to pgpm_test366_owner;
set role pgpm_test366_owner;
select pgpm.set_retain('public.rl366f', '45000');
select pgpm.retain('public.rl366f'::regclass);
reset role;
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'public.rl366f'::regclass and lo = '0'),
  array['retain_detach'], 'F: with no pg_cron here, the non-superuser''s recall is not refused');
select isnt((select recalled_at from pgpm.part where parent_table = 'public.rl366f'::regclass and lo = '0'),
  null, 'F: and it stamps the retirement recalled');

select * from finish();
reassign owned by pgpm_test366_owner to current_user;
drop owned by pgpm_test366_owner;
drop role pgpm_test366_owner;
