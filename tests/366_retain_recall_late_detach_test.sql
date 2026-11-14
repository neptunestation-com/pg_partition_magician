-- A detach run pg_cron started before a recall was seen is taken back, and the recall is made only on a job confirmed
-- idle (issue #1438).
--
-- THE BUG. _retain_recall's re-attach branch returned the pgpm_detach job to idle, re-attached the partition and
-- cleared its retirement marker in ONE transaction. pg_cron reads a job's command from a cache that only a commit
-- refreshes, so a run it started while that transaction was open still carried the armed `DETACH ... CONCURRENTLY`.
-- Queued on the parent behind the ATTACH, it detached the partition again once the recall committed, under no
-- marker: the rows went unserved, the log ended at retain_reattach and status() counted nothing. The idle itself was
-- a guess: _idle_detach_job swallowed pg_cron's refusal, so a caller that could not change the job recalled nothing
-- and said it had.
--
-- THE CONTRACT.
--   A recall is made only on a job the attempt itself confirms idle, or confirms absent; otherwise it is refused,
--   fail_retain_recall, counted, with pg_cron's reason, and neither recalls nor re-attaches. A recalled retirement
--   keeps its marker and pgpm's dispatch record, stamped recalled_at, until cron.job_run_details shows that no run
--   can still carry the detach: no run of the job unfinished, and a run of it carrying another command above the
--   run-id watermark a LATER transaction read once the recall was committed. Then the mark is cleared, and a hand
--   detach is the operator's again. Until then a late run's detach is pgpm's own and the next tick re-attaches it;
--   retire() never drops a table detached under a recalled mark, nor adopts a detach pending under one, and its
--   re-dispatch of a recalled retirement clears the old dispatch record; a recalled mark holds no detach slot.
--   Confirmed absent reads pgpm's schedule()/unschedule() record per role, since pg_cron keeps one job per role and
--   unschedule() removes only the caller's, and the install logs the jobs it sees that the record lacks.
--
-- TWO SESSIONS where a race matters, ordered by locks, not by time: dblink connection `rc` (or `tb`) holds the recall
-- open; `rd` (or `rb`) sends the armed command, as pg_cron's worker would, and is seen waiting before the first
-- commits. pg_cron itself is a stand-in catalog (cron.job, cron.alter_job, cron.job_run_details) that refuses a
-- non-owner as pg_cron does; a run is recorded in job_run_details when it starts, as pg_cron's launcher records it.
--
-- ASYMMETRIC FIXTURES. Each part's doomed partition holds its own ids (1, 2, 3; 11, 12; 21; 31, 32, 33; 41; 51, 52;
-- 61, 62; 71, 72; 81, 82, 83; 91, 92), so a re-attach of the wrong relation or a lost row cannot pass for the right
-- answer.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

select plan(102);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text, username text default current_user);
-- pg_cron's own rule: only the job's owner or a superuser changes it
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language plpgsql as $$
declare v_owner text;
begin
  select j.username into v_owner from cron.job j where j.jobid = job_id;
  if not found then raise exception 'could not find valid entry for job %', job_id; end if;
  if v_owner <> current_user and not (select rolsuper from pg_roles where rolname = current_user) then
    raise exception 'must be owner of job %', job_id;
  end if;
  update cron.job j set command = coalesce(alter_job.command, j.command) where j.jobid = job_id;
end;
$$;
create table cron.job_run_details (jobid bigint, runid bigserial, database text, username text, command text,
                                   status text, start_time timestamptz, end_time timestamptz);
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

create table public.rl366 (id bigint primary key, payload text);
create schema pgpm_test366;
-- a run of the standing job (or of p_cmd, a command a worker read earlier), recorded; \gexec runs the text returned
create function pgpm_test366.ran(p_cmd text default null) returns text language sql as $$
  insert into cron.job_run_details (jobid, database, username, command, status, start_time, end_time)
  select jobid, database, username, coalesce(p_cmd, command), 'succeeded', clock_timestamp(), clock_timestamp()
    from cron.job where jobname = 'pgpm_detach'
  returning command
$$;
-- a run started and not yet finished, and its end
create function pgpm_test366.started(p_cmd text) returns bigint language sql as $$
  insert into cron.job_run_details (jobid, database, username, command, status, start_time)
  values (1, current_database(), 'postgres', p_cmd, 'running', clock_timestamp())
  returning runid
$$;
create function pgpm_test366.finished(p_runid bigint) returns void language sql as $$
  update cron.job_run_details set status = 'succeeded', end_time = clock_timestamp() where runid = p_runid
$$;
create function pgpm_test366.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
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
create function pgpm_test366.ids(p_rel oid) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if not exists (select 1 from pg_class where oid = p_rel) then return null; end if;
  execute format('select array_agg(id order by id) from %s', p_rel::regclass) into v;
  return v;
end;
$$;
create function pgpm_test366.actions(p_parent regclass) returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log
   where parent_table = p_parent and lo = '0'
     and action in ('retain_detach', 'retain_recall', 'retain_reattach', 'fail_retain_reattach', 'fail_retain_recall',
                    'retain_drop', 'fail_retain_drop', 'fail_retain_identity', 'retain_disown')
$$;
create function pgpm_test366.mark(p_parent regclass) returns pgpm.part language sql as $$
  select * from pgpm.part where parent_table = p_parent and lo = '0'
$$;
-- a doomed partition [0, 10000) holding p_ids, a frontier row at 50005, and a referencing row on the frontier
create procedure pgpm_test366.landed(p_name text, p_ids bigint[]) language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_name);
  execute format('insert into public.%I select i, ''d'' from unnest(%L::bigint[]) i', p_name, p_ids);
  call pgpm.transmute(('public.' || p_name)::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
  perform pgpm.extend_to(('public.' || p_name)::regclass, '60000');
  execute format('insert into public.%I values (50005, ''frontier'')', p_name);
  execute format('create table public.%I (id bigint primary key, p_id bigint references public.%I(id))', p_name || '_ref', p_name);
  execute format('insert into public.%I values (1, 50005)', p_name || '_ref');
end;
$$;
-- a backend of this application_name waiting on any lock at all (a concurrent detach's second phase waits on the
-- virtual transaction ids of older snapshots, not on a relation); polled server-side, each sample fresh
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

-- ============ PART A: a run started inside the re-attach's transaction, and the bound ============
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
select pgpm_test366.ran(:'cmd') \gexec
select ok(not pgpm_test366.on_parent('public.rl366', :'doomed_oid'), 'LIVENESS: pgpm''s first run detached the partition');
select pgpm.set_retain('public.rl366', '45000');
select is(pgpm_test366.armed(), :'cmd',
  'LIVENESS: set_retain''s recall leaves a detached retirement''s job armed, so the next run starts with the detach');

-- the tick's recall, held open after its re-attach; the next cadence's run starts meanwhile
select dblink_connect('rc', 'dbname=' || current_database() || ' application_name=rl366_recall');
select dblink_connect('rd', 'dbname=' || current_database() || ' application_name=rl366_run');
select dblink_exec('rc', 'begin');
select * from dblink('rc', $q$ select pgpm.retain('public.rl366'::regclass)::text $q$) as t(n text);
select pgpm_test366.started(:'cmd') as a_run \gset
select dblink_send_query('rd', :'cmd');
select ok(pgpm_test366.wait_for_any('rl366_run'), 'LIVENESS: the run''s DETACH is queued behind the uncommitted re-attach');
select dblink_exec('rc', 'commit');
select is(t.r, 'ALTER TABLE', 'LIVENESS: once the recall committed, the queued run detached the partition again')
  from dblink_get_result('rd') as t(r text);
select dblink_get_result('rd');
select pgpm_test366.finished(:'a_run');
select dblink_disconnect('rd');
select dblink_disconnect('rc');
select is(pgpm_test366.actions('public.rl366'), array['retain_detach', 'retain_reattach'],
  'LIVENESS: the recall took the re-attach branch, logged retain_reattach');
select ok(not pgpm_test366.on_parent('public.rl366', :'doomed_oid'), 'LIVENESS: the partition is out of the parent after the race');

select results_eq($$ select retiring_at is not null, detach_dispatched_oid, recalled_at is not null
                      from pgpm_test366.mark('public.rl366') $$,
  format('values (true, %s::oid, true)', :'doomed_oid'),
  'A: the re-attach kept the marker and the dispatch record, stamped recalled, so the late detach is pgpm''s own');

call pgpm.maintain('public.rl366');
select ok(pgpm_test366.on_parent('public.rl366', :'doomed_oid'), 'A: the next tick re-attached the same relation, by oid');
select is(pgpm_test366.served('public.rl366', 20000), array[1, 2, 3]::bigint[], 'A: ids 1, 2, 3 are served by the parent again');
select is(pgpm_test366.actions('public.rl366'), array['retain_detach', 'retain_reattach', 'retain_reattach'],
  'A: logged as exactly retain_detach, retain_reattach, retain_reattach');
select is(pgpm_test366.armed(), 'select 1', 'A: the standing job is idle');

call pgpm.maintain('public.rl366');
select isnt((pgpm_test366.mark('public.rl366')).recall_seen_run, null,
  'LIVENESS: a later tick saw the recall committed and read pg_cron''s run watermark');
select isnt((pgpm_test366.mark('public.rl366')).retiring_at, null,
  'A: with no run of the job started since, the tick keeps the marker');
select results_eq($$ select retain_drop_failures, retain_detaching, retain_recalled from pgpm.status()
                      where parent = 'public.rl366'::regclass $$,
  $$ values (0::bigint, 0::bigint, 1::bigint) $$, 'A: status() counts it as recalled, not detaching, and nothing failed');

-- a run of the old command that lands only now (a launcher that has not reloaded its cache)
select pgpm_test366.ran(:'cmd') \gexec
select ok(not pgpm_test366.on_parent('public.rl366', :'doomed_oid'), 'LIVENESS: a run landing two ticks later detached the partition');
call pgpm.maintain('public.rl366');
select ok(pgpm_test366.on_parent('public.rl366', :'doomed_oid'), 'A: the next tick re-attached it, the kept marker naming it pgpm''s own');
select is(pgpm_test366.served('public.rl366', 20000), array[1, 2, 3]::bigint[], 'A: ids 1, 2, 3 are served again');

-- a run of the idle job, started above the watermark and still running, holds the mark; finished, it clears it
select pgpm_test366.started('select 1') as a_idle \gset
call pgpm.maintain('public.rl366');
select isnt((pgpm_test366.mark('public.rl366')).retiring_at, null, 'A: a run of the job still unfinished keeps the marker');
select pgpm_test366.finished(:'a_idle');
call pgpm.maintain('public.rl366');
select results_eq($$ select retiring_at, detach_dispatched_oid, recalled_at, recall_seen_run from pgpm_test366.mark('public.rl366') $$,
  $$ values (null::timestamptz, null::oid, null::timestamptz, null::bigint) $$,
  'A: once a run of the idle job above the watermark finished, the tick clears the marker and the recall');
select is(pgpm_test366.served('public.rl366', 20000), array[1, 2, 3]::bigint[], 'A: ids 1, 2, 3 are still served');

-- from then on the operator's hand detach is the operator's: retention reaching it again does not drop it
alter table public.rl366 detach partition public.:"doomed";
update pgpm.config set retain = '25000' where parent_table = 'public.rl366'::regclass;   -- set_retain refuses a tightening that drops
select ok(not pgpm.retire('public.rl366', :'doomed'), 'fixture: retire() of the hand-detached partition returns');
select is(pgpm_test366.actions('public.rl366'),
  array['retain_detach', 'retain_reattach', 'retain_reattach', 'retain_reattach', 'fail_retain_drop'],
  'A: retire() refuses the hand-detached table, fail_retain_drop');
select is(pgpm_test366.ids(:'doomed_oid'), array[1, 2, 3]::bigint[], 'A: the operator''s table stands with ids 1, 2, 3');

-- ============ PART B: set_retain and retain() in ONE transaction, a run started while it is open ============
call pgpm_test366.landed('rl366b', array[11, 12]);
select child_name as b_doomed, child_oid as b_oid from pgpm.part where parent_table = 'public.rl366b'::regclass and lo = '0' \gset
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
select results_eq($$ select * from dblink('tb', 'select recalled_at is not null, recall_seen_run is null from pgpm.part
                       where parent_table = ''public.rl366b''::regclass and lo = ''0''') as t(a boolean, b boolean) $$,
  $$ values (true, true) $$,
  'B: the recall''s own transaction stamps it recalled, and its retain() reads no watermark for it');
select pgpm_test366.started(:'b_cmd') as b_run \gset
select dblink_send_query('rb', :'b_cmd');
select ok(pgpm_test366.wait_for_any('rl366b_run'), 'LIVENESS: (B) the run''s detach is waiting on the open transaction');
select dblink_exec('tb', 'commit');
select is(t.r, 'ALTER TABLE', 'LIVENESS: (B) once the transaction committed, the run detached the partition')
  from dblink_get_result('rb') as t(r text);
select dblink_get_result('rb');
select pgpm_test366.finished(:'b_run');
select dblink_disconnect('rb');
select dblink_disconnect('tb');
select ok(not pgpm_test366.on_parent('public.rl366b', :'b_oid'), 'LIVENESS: (B) the partition is out of the parent');

call pgpm.maintain('public.rl366b');
select ok(pgpm_test366.on_parent('public.rl366b', :'b_oid'), 'B: the next tick re-attached the same relation');
select is(pgpm_test366.served('public.rl366b', 20000), array[11, 12]::bigint[], 'B: ids 11, 12 are served again');

-- ============ PART C: a recalled mark does not hold the one detach slot ============
-- One detach is in flight at a time, database-wide, and a retirement yields to an older one still attached. B's
-- mark, older than any other, is kept by its recall with the job idle: no detach in flight.
call pgpm_test366.landed('rl366c', array[21]);
select child_name as c_doomed from pgpm.part where parent_table = 'public.rl366c'::regclass and lo = '0' \gset
select ok((pgpm_test366.mark('public.rl366b')).recalled_at is not null and pgpm_test366.armed() = 'select 1',
  'LIVENESS: (C) B''s attached, recalled mark is kept, older than any other, with the job idle');
select ok(not pgpm.retire('public.rl366c', :'c_doomed'), 'fixture: (C) retire() of the other parent''s partition returns');
select is(pgpm_test366.armed(), format('alter table public.rl366c detach partition public.%I concurrently', :'c_doomed'),
  'C: it dispatched its detach rather than yield to B''s recalled mark');
select pgpm_test366.armed() as c_cmd \gset

-- ============ PART D: retention reaches a recalled retirement again ============
select pgpm_test366.ran(:'c_cmd') \gexec   -- C's detach lands, the slot is free
update pgpm.config set retain = '25000' where parent_table = 'public.rl366b'::regclass;
select ok(not pgpm.retire('public.rl366b', :'b_doomed'), 'fixture: (D) retire() of B''s recalled partition returns');
select is(pgpm_test366.armed(), :'b_cmd', 'LIVENESS: (D) retire() re-dispatched B''s detach');
select results_eq($$ select recalled_at, recall_xid::text, recall_seen_run from pgpm_test366.mark('public.rl366b') $$,
  $$ values (null::timestamptz, null::text, null::bigint) $$, 'D: the re-dispatch clears the recall');
select results_eq($$ select retain_detaching, retain_recalled from pgpm.status() where parent = 'public.rl366b'::regclass $$,
  $$ values (1::bigint, 0::bigint) $$, 'D: status() counts B''s retirement as detaching again');
select pgpm_test366.ran(:'b_cmd') \gexec
select ok(not pgpm_test366.on_parent('public.rl366b', :'b_oid'), 'LIVENESS: (D) B''s detach landed');

-- ============ PART H: retire() never drops a table detached under a recalled mark ============
call pgpm_test366.landed('rl366h', array[61, 62]);
select child_name as h_doomed, child_oid as h_oid from pgpm.part where parent_table = 'public.rl366h'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rl366h', :'h_doomed'), 'fixture: (H) retire() dispatches the concurrent detach');
select pgpm.set_retain('public.rl366h', '45000');
select is(pgpm_test366.actions('public.rl366h'), array['retain_detach', 'retain_recall'], 'LIVENESS: (H) the detach was recalled');
select ok((pgpm_test366.mark('public.rl366h')).recalled_at is not null, 'LIVENESS: (H) and the mark kept, recalled');
alter table public.rl366h detach partition public.:"h_doomed";   -- the operator keeps it
update pgpm.config set retain = '25000' where parent_table = 'public.rl366h'::regclass;
select ok(not pgpm.retire('public.rl366h', :'h_doomed'), 'fixture: (H) retire() of the detached partition returns');
select is((pgpm_test366.actions('public.rl366h'))[3], 'fail_retain_drop', 'H: refused, fail_retain_drop');
select ok((select method from pgpm.log where parent_table = 'public.rl366h'::regclass and action = 'fail_retain_drop')
            like '%recalled%', 'H: the refusal says the mark was recalled');
select is(pgpm_test366.ids(:'h_oid'), array[61, 62]::bigint[], 'H: the table stands with ids 61, 62');

-- ============ PART E: a recall whose idle the attempt cannot confirm is refused ============
call pgpm_test366.landed('rl366e', array[31, 32, 33]);
select child_name as e_doomed, child_oid as e_oid from pgpm.part where parent_table = 'public.rl366e'::regclass and lo = '0' \gset
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
create policy job_owner on cron.job using (username = current_user);   -- pg_cron's own policy: a job shows to its owner
grant usage on schema cron to pgpm_test366_owner;
grant select on cron.job, cron.job_run_details to pgpm_test366_owner;
grant usage on schema pgpm to pgpm_test366_owner;
grant select, insert, update, delete on all tables in schema pgpm to pgpm_test366_owner;
grant usage on all sequences in schema pgpm to pgpm_test366_owner;
-- the owner owns the table and every partition, so a recall or re-attach it should not make would succeed
select format('alter table %s owner to pgpm_test366_owner', c) from (
  select 'public.rl366e'::regclass as c
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rl366e'::regclass) t \gexec

-- E1: the owner sees no job (another role's, invisible) and pgpm records no unschedule()
set role pgpm_test366_owner;
select set_config('pgpm_test366.seen', (select count(*) from cron.job)::text, false);
select pgpm.set_retain('public.rl366e', '45000');
select pgpm.retain('public.rl366e'::regclass);
reset role;
select is(current_setting('pgpm_test366.seen'), '0', 'LIVENESS: (E1) the owner role sees no job in cron.job');
select is(pgpm_test366.armed(), :'e_cmd', 'LIVENESS: (E1) the job is still armed');
select is(pgpm_test366.actions('public.rl366e'), array['retain_detach', 'fail_retain_recall', 'fail_retain_recall'],
  'E1: set_retain''s recall and retain()''s are each refused, fail_retain_recall');
select ok((select bool_and(position('pgpm_test366_owner' in method) > 0 and position('sees no pgpm_detach job' in method) > 0)
             from pgpm.log where parent_table = 'public.rl366e'::regclass and action = 'fail_retain_recall'),
  'E1: the refusal names the role and the reason');
select results_eq($$ select retain_drop_failures, retain_detaching, retain_recalled from pgpm.status()
                      where parent = 'public.rl366e'::regclass $$,
  $$ values (2::bigint, 1::bigint, 0::bigint) $$, 'E1: status() counts both refusals, and the retirement as still detaching');

-- E2: the run lands; with BYPASSRLS the owner SEES the job, and pg_cron refuses its change as a non-owner's
select pgpm_test366.ran(:'e_cmd') \gexec
select ok(not pgpm_test366.on_parent('public.rl366e', :'e_oid'), 'LIVENESS: (E2) the run detached the partition');
alter role pgpm_test366_owner bypassrls;
set role pgpm_test366_owner;
select set_config('pgpm_test366.seen', (select count(*) from cron.job)::text, false);
select pgpm.retain('public.rl366e'::regclass);
reset role;
alter role pgpm_test366_owner nobypassrls;
select is(current_setting('pgpm_test366.seen'), '1', 'LIVENESS: (E2) with BYPASSRLS the owner role sees the job');
select ok(not pgpm_test366.on_parent('public.rl366e', :'e_oid'), 'E2: the owner''s recall did not re-attach under a job it cannot idle');
select ok((select method from pgpm.log where parent_table = 'public.rl366e'::regclass and action = 'fail_retain_recall'
            order by id desc limit 1) like '%must be owner of job%', 'E2: refused with pg_cron''s own reason');

-- E3: the owner owns the job, and lacks EXECUTE on cron.alter_job (pg_cron 1.6 revokes it from PUBLIC)
select set_config('pgpm_test366.cmd', :'e_cmd', false);
update cron.job set username = 'pgpm_test366_owner';
revoke execute on function cron.alter_job(bigint, text, text, text, text, boolean) from public;
set role pgpm_test366_owner;
select set_config('pgpm_test366.seen', (select count(*) from cron.job where command = current_setting('pgpm_test366.cmd'))::text, false);
select pgpm.retain('public.rl366e'::regclass);
reset role;
grant execute on function cron.alter_job(bigint, text, text, text, text, boolean) to public;
update cron.job set username = 'postgres';
select is(current_setting('pgpm_test366.seen'), '1', 'LIVENESS: (E3) the owner sees its own job, armed');
select ok(not pgpm_test366.on_parent('public.rl366e', :'e_oid'), 'E3: the owner''s recall did not re-attach');
select ok((select method from pgpm.log where parent_table = 'public.rl366e'::regclass and action = 'fail_retain_recall'
            order by id desc limit 1) like '%permission denied%', 'E3: refused with the missing EXECUTE');
select is(pgpm_test366.armed(), :'e_cmd', 'LIVENESS: (E3) the job is still armed');

call pgpm.maintain('public.rl366e');
select ok(pgpm_test366.on_parent('public.rl366e', :'e_oid'), 'E: a superuser''s tick re-attached it');
select is(pgpm_test366.served('public.rl366e', 20000), array[31, 32, 33]::bigint[], 'E: ids 31, 32, 33 are served again');
select is(pgpm_test366.armed(), 'select 1', 'E: and the job is idle');

-- ============ PART G: a job pgpm.unschedule() removed is confirmed absent ============
-- pg_cron shows a job only to its owner and to superusers, so a non-superuser that sees none knows there is none only
-- from pgpm's own record: the last of schedule() and unschedule() to run. (The stand-in has no pg_cron extension for
-- those two to act on, so their log rows are written here as they write them.)
call pgpm_test366.landed('rl366g', array[51, 52]);
select child_name as g_doomed, child_oid as g_oid from pgpm.part where parent_table = 'public.rl366g'::regclass and lo = '0' \gset
select format('alter table %s owner to pgpm_test366_owner', c) from (
  select 'public.rl366g'::regclass as c union all select 'public.rl366g_ref'::regclass
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rl366g'::regclass) t \gexec
insert into pgpm.log (parent_table, action, method) values (null, 'schedule', 'by postgres');
select ok(not pgpm.retire('public.rl366g', :'g_doomed'), 'fixture: (G) retire() dispatches the concurrent detach');
select pgpm_test366.armed() as g_cmd \gset
select pgpm_test366.ran(:'g_cmd') \gexec
select ok(not pgpm_test366.on_parent('public.rl366g', :'g_oid'), 'LIVENESS: (G) the detach landed');
alter table cron.job disable row level security;
delete from cron.job;   -- unscheduled by hand, around pgpm.unschedule()
set role pgpm_test366_owner;
select pgpm.set_retain('public.rl366g', '45000');
select pgpm.retain('public.rl366g'::regclass);
reset role;
select ok(not pgpm_test366.on_parent('public.rl366g', :'g_oid'),
  'G: with schedule() the last pgpm records, the owner that sees no job is refused');
insert into pgpm.log (parent_table, action, method) values (null, 'unschedule', 'by postgres, 3 job(s) removed');
set role pgpm_test366_owner;
select pgpm.retain('public.rl366g'::regclass);
reset role;
select ok(pgpm_test366.on_parent('public.rl366g', :'g_oid'), 'G: after pgpm.unschedule(), its recall re-attached the partition');
select is(pgpm_test366.served('public.rl366g', 20000), array[51, 52]::bigint[], 'G: ids 51, 52 are served again');
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1', 'postgres');

-- ============ PART I: pgpm's record is read per role ============
-- pg_cron keeps one pgpm_detach per role that ran schedule(), and unschedule() removes only the caller's: the owner's
-- unschedule() after its own schedule() says nothing of the administrator's job, which stays armed.
call pgpm_test366.landed('rl366i', array[71, 72]);
select child_name as i_doomed, child_oid as i_oid from pgpm.part where parent_table = 'public.rl366i'::regclass and lo = '0' \gset
select format('alter table %s owner to pgpm_test366_owner', c) from (
  select 'public.rl366i'::regclass as c union all select 'public.rl366i_ref'::regclass
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rl366i'::regclass) t \gexec
insert into pgpm.log (parent_table, action, method) values
  (null, 'schedule', 'by postgres'), (null, 'schedule', 'by pgpm_test366_owner'),
  (null, 'unschedule', 'by pgpm_test366_owner, 3 job(s) removed');
select ok(not pgpm.retire('public.rl366i', :'i_doomed'), 'fixture: (I) retire() dispatches the concurrent detach');
select pgpm_test366.armed() as i_cmd \gset
alter table cron.job enable row level security;
set role pgpm_test366_owner;
select set_config('pgpm_test366.seen', (select count(*) from cron.job)::text, false);
select pgpm.set_retain('public.rl366i', '45000');
select pgpm.retain('public.rl366i'::regclass);
reset role;
select is(current_setting('pgpm_test366.seen'), '0', 'LIVENESS: (I) the owner role sees no job');
select is((select action from pgpm.log where parent_table is null and action in ('schedule', 'unschedule') order by id desc limit 1),
  'unschedule', 'LIVENESS: (I) the last of schedule() and unschedule() that pgpm records is the owner''s unschedule()');
select is(pgpm_test366.armed(), :'i_cmd', 'LIVENESS: (I) the administrator''s job is still armed');
select is(pgpm_test366.actions('public.rl366i'), array['retain_detach', 'fail_retain_recall', 'fail_retain_recall'],
  'I: with the administrator''s schedule() its own latest row, the owner''s recalls are refused');
select is((pgpm_test366.mark('public.rl366i')).recalled_at, null, 'I: and nothing is stamped recalled');
-- the administrator unschedules too: no role holds a job, and the recall is made
alter table cron.job disable row level security;
delete from cron.job;
insert into pgpm.log (parent_table, action, method) values (null, 'unschedule', 'by postgres, 3 job(s) removed');
set role pgpm_test366_owner;
select pgpm.retain('public.rl366i'::regclass);
reset role;
select isnt((pgpm_test366.mark('public.rl366i')).recalled_at, null, 'I: once every role has unscheduled, the owner''s recall is made');
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1', 'postgres');

-- ============ PART J: a hand detach pending under a recalled mark is the operator's ============
-- A recalled mark's dispatch record is kept only for the bound: a detach pending under it is a late run of pgpm's or
-- the operator's own, and nothing tells them apart. Retention reaching it again must not adopt it.
call pgpm_test366.landed('rl366j', array[81, 82, 83]);
select child_name as j_doomed, child_oid as j_oid from pgpm.part where parent_table = 'public.rl366j'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rl366j', :'j_doomed'), 'fixture: (J) retire() dispatches the concurrent detach');
select pgpm.set_retain('public.rl366j', '45000');
select isnt((pgpm_test366.mark('public.rl366j')).recalled_at, null, 'LIVENESS: (J) the recall kept the mark, stamped recalled');
-- the operator's DETACH ... CONCURRENTLY, cancelled in its wait for an older transaction: left pending
select dblink_connect('jb', 'dbname=' || current_database());
select dblink_connect('jo', 'dbname=' || current_database());
select dblink_exec('jb', 'begin');
select * from dblink('jb', 'select count(*)::text from public.rl366j') as t(c text);
select dblink_exec('jo', 'set statement_timeout = 400');
select dblink_exec('jo', format('alter table public.rl366j detach partition public.%I concurrently', :'j_doomed'), false);
select dblink_exec('jb', 'rollback');
select dblink_disconnect('jb');
select dblink_disconnect('jo');
select ok((select inhdetachpending from pg_inherits where inhparent = 'public.rl366j'::regclass and inhrelid = :'j_oid'::oid),
  'LIVENESS: (J) the operator''s hand detach is left pending');
update pgpm.config set retain = '25000' where parent_table = 'public.rl366j'::regclass;
select pgpm.retire('public.rl366j', :'j_doomed');
select is(pgpm_test366.armed(), 'select 1', 'J: retire() does not dispatch a detach pending under a recalled mark');
select pgpm._detach_reap();
select ok(not exists (select 1 from pg_inherits where inhrelid = :'j_oid'::oid), 'LIVENESS: (J) the pending detach was finished');
select pgpm.retire('public.rl366j', :'j_doomed');
select pgpm.retire('public.rl366j', :'j_doomed');
select is(pgpm_test366.ids(:'j_oid'), array[81, 82, 83]::bigint[], 'J: the table the operator detached is kept, ids 81, 82, 83');
select is((pgpm_test366.mark('public.rl366j')).retiring_at, null, 'J: and the recalled mark is disowned');

-- ============ PART K: a re-dispatch that fails leaves no record of a dispatch ============
call pgpm_test366.landed('rl366k', array[91, 92]);
select child_name as k_doomed, child_oid as k_oid from pgpm.part where parent_table = 'public.rl366k'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rl366k', :'k_doomed'), 'fixture: (K) retire() dispatches the concurrent detach');
select pgpm.set_retain('public.rl366k', '45000');
select ok((select recalled_at is not null and detach_dispatched_oid = :'k_oid'::oid from pgpm.part
            where parent_table = 'public.rl366k'::regclass and lo = '0'),
  'LIVENESS: (K) the recall kept the mark and the dispatch record');
update pgpm.config set retain = '25000' where parent_table = 'public.rl366k'::regclass;
delete from cron.job;   -- no job to arm: schedule() not run, or unscheduled
select pgpm.retire('public.rl366k', :'k_doomed');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rl366k'::regclass and action = 'fail_retain_detach'),
  'LIVENESS: (K) the re-dispatch failed');
select is((pgpm_test366.mark('public.rl366k')).detach_dispatched_oid, null, 'K: the failed re-dispatch left no dispatch record');
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1', 'postgres');
alter table public.rl366k detach partition public.:"k_doomed";
select pgpm.retire('public.rl366k', :'k_doomed');
select pgpm.retire('public.rl366k', :'k_doomed');
select is(pgpm_test366.ids(:'k_oid'), array[91, 92]::bigint[], 'K: the table the operator then detached by hand is kept, ids 91, 92');

-- ============ PART L: the install brings pgpm's record up to the jobs it sees ============
-- L1: a pgpm_detach an older pgpm made without logging it, where the record shows every role it knows unscheduled
delete from pgpm.log where parent_table is null and action in ('schedule', 'unschedule');
insert into pgpm.log (parent_table, action, method) values
  (null, 'schedule', 'by pgpm_test366_owner'), (null, 'unschedule', 'by pgpm_test366_owner, 3 job(s) removed');
delete from cron.job;
insert into cron.job values (2, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test366_old');
select ok(pgpm._detach_jobs_unscheduled(), 'LIVENESS: (L1) without the install''s pass the record reads as no job left');
select pgpm._seed_detach_ledger();
select ok(not pgpm._detach_jobs_unscheduled(), 'L1: the install logs the job it sees that the record lacks');
select is(pgpm._detach_ledger_last('pgpm_test366_old'), 'schedule', 'L1: under the role that holds it');
-- L2: a non-superuser brings the record up over tables already managed, and cannot see another role's job
delete from pgpm.log where parent_table is null and action in ('schedule', 'unschedule');
alter table cron.job enable row level security;
set role pgpm_test366_owner;
select set_config('pgpm_test366.seen', (select count(*) from cron.job)::text, false);
select pgpm._seed_detach_ledger();
reset role;
select is(current_setting('pgpm_test366.seen'), '0', 'LIVENESS: (L2) the owner role sees no job');
-- the owner then schedules and unschedules its own
insert into pgpm.log (parent_table, action, method) values
  (null, 'schedule', 'by pgpm_test366_owner'), (null, 'unschedule', 'by pgpm_test366_owner, 3 job(s) removed');
select ok(not pgpm._detach_jobs_unscheduled(), 'L2: the placeholder stands for the jobs it could not see');
-- a superuser's pass logs the job and retires the placeholder; with that job unscheduled too, no job is left
select pgpm._seed_detach_ledger();
select is(pgpm._detach_ledger_last('?unknown'), 'unschedule', 'L2: a superuser''s pass retires the placeholder');
delete from cron.job;
insert into pgpm.log (parent_table, action, method) values (null, 'unschedule', 'by pgpm_test366_old, 3 job(s) removed');
select ok(pgpm._detach_jobs_unscheduled(), 'LIVENESS: (L2) once every role has unscheduled, the record reads as no job left');
alter table cron.job disable row level security;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1', 'postgres');   -- for part F

-- ============ PART F: no pg_cron here ============
call pgpm_test366.landed('rl366f', array[41]);
select child_name as f_doomed from pgpm.part where parent_table = 'public.rl366f'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rl366f', :'f_doomed'), 'fixture: (F) retire() dispatches the concurrent detach');
drop schema cron cascade;
grant select on public.rl366f to pgpm_test366_owner;
set role pgpm_test366_owner;
select pgpm.set_retain('public.rl366f', '45000');
reset role;
select is(pgpm_test366.actions('public.rl366f'), array['retain_detach'],
  'F: with no pg_cron here, the non-superuser''s recall is not refused');
select isnt((pgpm_test366.mark('public.rl366f')).recalled_at, null, 'F: it stamps the retirement recalled');
call pgpm.maintain('public.rl366f');
select is((pgpm_test366.mark('public.rl366f')).retiring_at, null, 'F: and with nothing that can run a detach, the next tick clears the mark');

select * from finish();
reassign owned by pgpm_test366_owner to current_user;
drop owned by pgpm_test366_owner;
drop role pgpm_test366_owner;
