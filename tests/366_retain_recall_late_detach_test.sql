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
--   The re-attach keeps the marker and pgpm's dispatch record, as the attached branch does (#652), so a late
--   run's detach is still pgpm's own retirement: the next tick re-attaches it once more. A tick after that, with
--   the job idle and no detach of it running, clears the marker.
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

select plan(21);

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

select ok(pgpm_test366.attached(:'doomed_oid'), 'a further tick leaves the partition attached');
select is((select retiring_at from pgpm.part where parent_table = 'public.rl366'::regclass and lo = '0'),
  null, 'the tick after, finding no detach of it running, clears the marker');
select is((select detach_dispatched_oid from pgpm.part where parent_table = 'public.rl366'::regclass and lo = '0'),
  null, 'and the dispatch record');
select is(pgpm_test366.ids(20000), array[1, 2, 3]::bigint[], 'ids 1, 2, 3 are still served');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'public.rl366'::regclass $$,
  $$ values (0::bigint, 0::bigint) $$, 'status() reports nothing failed and nothing detaching');
select lives_ok($$ insert into public.rl366_ref values (2, 2) $$,
  'a referencing row can point into the re-attached range');

select * from finish();
