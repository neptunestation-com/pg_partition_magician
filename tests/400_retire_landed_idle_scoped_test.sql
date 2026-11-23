-- retire()'s idle of a landed detach resets only the pgpm_detach jobs that may hold it (#1498).
--
-- THE BUG. Once a referenced partition's detach landed, retire() returned the job to idle with
-- _idle_detach_job(null) before the drop, which resets every pgpm_detach job the caller sees. pg_cron keeps one job
-- per role that ran pgpm.schedule() and shows a superuser all of them, so a superuser's tick completing one retirement
-- reset every other role's job too, one holding ANOTHER retirement's dispatched detach that had not run included: that
-- detach was clobbered, against #407's rule, and waited a tick or more for a re-dispatch (whose role, if the
-- superuser's, then nulled retiring_by and left the retirement for a superuser to complete).
--
-- THE CONTRACT (pgpm._idle_landed_detach). Unconditional on the command, as #407 requires, but over the jobs that may
-- hold the detach. A dispatch arms every job its role sees (pg_cron's row security): a non-superuser's its own, a
-- superuser's every role's. So:
--   PART A  a superuser dispatched it: every job is reset, another role's too (the superuser's dispatch armed it),
--           except the job holding another mark's pending detach, which keeps it.
--   PART B  a non-superuser alone dispatched it (retiring_by): a superuser's completion resets that role's job and
--           leaves every other role's job as it was, whatever it holds.
--   PART C  two roles dispatched it (retiring_by null): every job is reset, one holding no mark's detach included.
--   PART D  the scope is recorded at the dispatch, never read off the role later: a superuser's dispatch records no
--           role, so once that role is demoted its own tick is deferred (it sees only its own job), and another
--           superuser's completion resets every job.
--   PART F  a cron.job with no username column keeps no job per role: the dispatch records its role, and the idle
--           still reaches every job (it scopes by a column that is not there to read).
--   PART E  every install clears the role of a dispatched mark an older release recorded for a role that reads every
--           job (pgpm._unrecord_wide_dispatchers), and only that.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for cron.job
-- (with pg_cron's username column and its row-security policy) and cron.alter_job, as tests/397 does, and runs a
-- job's command with \gexec at the top level, as pg_cron does. What a non-superuser observes goes through set_config.
--
-- ASYMMETRIC FIXTURES. Each table's retiring partition holds a different id set (ra 1-2, rb 3-5, rd 6-9, re 0 and 9, rf 1-2, rg 4-5),
-- and the jobs hold different commands, so an assertion aimed at the wrong job or table cannot pass.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(49);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text,
                       username text not null default current_user);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pgpm_test400_owner') then
    create role pgpm_test400_owner nosuperuser nobypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'pgpm_test400_other') then
    create role pgpm_test400_other nosuperuser nobypassrls;
  end if;
end $$;
grant usage on schema pgpm to pgpm_test400_owner;
grant all on all tables in schema pgpm to pgpm_test400_owner;
grant all on all sequences in schema pgpm to pgpm_test400_owner;
grant create, usage on schema public to pgpm_test400_owner;
grant usage on schema cron to pgpm_test400_owner;
grant select, update on cron.job to pgpm_test400_owner;
-- the owner's job, the administrator's and another role's; pg_cron's row security: a role sees only its own jobs
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test400_owner'),
                            (2, 'pgpm_detach', current_database(), 'select 1', 'postgres'),
                            (3, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test400_other');
create policy pgpm_test400_own on cron.job using (username = current_user);
alter table cron.job enable row level security;
create function pg_temp.cmd(p_job bigint) returns text language sql as $$ select command from cron.job where jobid = p_job $$;
create function pg_temp.det(p_parent text, p_child text) returns text language sql as $$
  select format('alter table public.%I detach partition public.%I concurrently', p_parent, p_child)
$$;
create function pg_temp.mark(p_parent regclass) returns text language sql as $$
  select coalesce((select format('%s %s %s', retiring_at is not null, retiring_by, detach_dispatched_oid is not null)
                     from pgpm.part where parent_table = p_parent and lo = '0'), 'no row')
$$;
create function pg_temp.attached(p_parent regclass, p_child text) returns boolean language sql as $$
  select exists (select 1 from pg_inherits where inhparent = p_parent and inhrelid = to_regclass(format('public.%I', p_child)))
$$;
create function pg_temp.dropped(p_parent regclass, p_child text) returns boolean language sql as $$
  select to_regclass(format('public.%I', p_child)) is null
     and exists (select 1 from pgpm.log where parent_table = p_parent and lo = '0' and action = 'retain_drop')
$$;
-- a table whose lo 0 partition (p_ids) is past retention, referenced, so it retires through the pgpm_detach job
create function pg_temp.mk(p_rel text, p_ids int[]) returns text language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_rel);
  execute format('insert into public.%I select unnest($1), ''x''', p_rel) using p_ids;
  return p_rel;
end $$;
create function pg_temp.finish_mk(p_rel text, p_role name) returns text language plpgsql as $$
declare r regclass;
begin
  execute format('insert into public.%I values (55, ''frontier'')', p_rel);
  execute format('create table public.%I (id bigint primary key, r bigint references public.%I (id))', p_rel || '_ref', p_rel);
  execute format('insert into public.%I values (100, 55)', p_rel || '_ref');
  if p_role is not null then
    for r in select format('public.%I', p_rel)::regclass union all select format('public.%I', p_rel || '_ref')::regclass
             union all select inhrelid::regclass from pg_inherits where inhparent = format('public.%I', p_rel)::regclass loop
      execute format('alter table %s owner to %I', r, p_role);
    end loop;
  end if;
  return (select child_name from pgpm.part where parent_table = format('public.%I', p_rel)::regclass and lo = '0');
end $$;
select ok(bool_and(not rolsuper and not rolbypassrls) and count(*) = 2,
  'LIVENESS: the owner and the other role are neither superusers nor exempt from row security')
  from pg_roles where rolname in ('pgpm_test400_owner', 'pgpm_test400_other');

-- ==================== (A) a superuser dispatched it: every job but another mark's pending detach ====================
select pg_temp.mk('ra400', array[1, 2]);
call pgpm.transmute('public.ra400', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
select pg_temp.finish_mk('ra400', 'pgpm_test400_owner') as ra \gset
select pg_temp.mk('rb400', array[3, 4, 5]);
call pgpm.transmute('public.rb400', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
select pg_temp.finish_mk('rb400', null) as rb \gset
select is(pgpm.retire('public.rb400', :'rb'), false, 'LIVENESS: (A) the administrator''s retire() dispatches rb400''s detach');
select is(array[pg_temp.cmd(1), pg_temp.cmd(2), pg_temp.cmd(3)], array_fill(pg_temp.det('rb400', :'rb'), array[3]),
  'LIVENESS: (A) the superuser''s dispatch armed every role''s job');
select is(pg_temp.mark('public.rb400'), 't  t',
  'A: the mark records the dispatch and no role: the superuser''s armed every role''s job (_dispatch_reached_others)');
select pg_temp.cmd(2) \gexec
select ok(not pg_temp.attached('public.rb400', :'rb'), 'LIVENESS: (A) the administrator''s job landed rb400''s detach');
set role pgpm_test400_owner;
select set_config('t400.a', pgpm.retire('public.ra400', :'ra')::text, false);
reset role;
select is(current_setting('t400.a') || ' ' || pg_temp.cmd(1), 'false ' || pg_temp.det('ra400', :'ra'),
  'LIVENESS: (A) the owner''s retire() then dispatches ra400''s detach through its own job');
select is(pg_temp.mark('public.ra400'), 't pgpm_test400_owner t', 'LIVENESS: (A) the mark records the owner''s dispatch');
select is(pg_temp.cmd(3), pg_temp.det('rb400', :'rb'), 'LIVENESS: (A) the other role''s job still holds rb400''s landed detach');
select is(pgpm.retire('public.rb400', :'rb'), true, 'LIVENESS: (A) the administrator''s retire() completes rb400');
select ok(pg_temp.dropped('public.rb400', :'rb'), 'LIVENESS: (A) dropping its partition, retain_drop logged');
select is(pg_temp.cmd(1), pg_temp.det('ra400', :'ra'), 'A: the owner''s job keeps ra400''s pending detach');
select ok(pg_temp.attached('public.ra400', :'ra') and pg_temp.mark('public.ra400') = 't pgpm_test400_owner t',
  'A: and ra400''s partition is attached and marked, the dispatch still its');
select is(pg_temp.cmd(2), 'select 1', 'A: the administrator''s job, the recorded dispatcher''s, is idle');
select is(pg_temp.cmd(3), 'select 1',
  'A: and so is the other role''s, which the superuser''s dispatch armed with the dropped partition''s detach');

-- ==================== (B) a non-superuser alone dispatched it: its job only ====================
update cron.job set command = 'alter table public.elsewhere400 detach partition public.elsewhere400_p2 concurrently' where jobid = 2;
update cron.job set command = 'alter table public.elsewhere400 detach partition public.elsewhere400_p3 concurrently' where jobid = 3;
select pg_temp.cmd(1) \gexec
select ok(not pg_temp.attached('public.ra400', :'ra'), 'LIVENESS: (B) the owner''s job landed ra400''s detach');
select is(pgpm.retire('public.ra400', :'ra'), true, 'LIVENESS: (B) a superuser''s retire() completes ra400');
select ok(pg_temp.dropped('public.ra400', :'ra') and pg_temp.mark('public.ra400') = 'no row',
  'LIVENESS: (B) dropping its partition and its row, retain_drop logged');
select is(pg_temp.cmd(1), 'select 1', 'B: the owner''s job, the recorded dispatcher''s, is idle');
select is(pg_temp.cmd(2), 'alter table public.elsewhere400 detach partition public.elsewhere400_p2 concurrently',
  'B: the administrator''s job, which never held ra400''s detach, is as it was');
select is(pg_temp.cmd(3), 'alter table public.elsewhere400 detach partition public.elsewhere400_p3 concurrently',
  'B: and so is the other role''s');

-- ==================== (C) two roles dispatched it: every job ====================
update cron.job set command = 'select 1' where jobid in (1, 2);
select pg_temp.mk('rd400', array[6, 7, 8, 9]);
call pgpm.transmute('public.rd400', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
select pg_temp.finish_mk('rd400', 'pgpm_test400_owner') as rd \gset
set role pgpm_test400_owner;
select set_config('t400.c', pgpm.retire('public.rd400', :'rd')::text, false);
reset role;
select is(current_setting('t400.c') || ' ' || pg_temp.cmd(1), 'false ' || pg_temp.det('rd400', :'rd'),
  'LIVENESS: (C) the owner''s retire() dispatches rd400''s detach through its own job');
select is(pgpm.retire('public.rd400', :'rd'), false, 'LIVENESS: (C) the administrator''s retire() dispatches it again');
select is(pg_temp.mark('public.rd400'), 't  t', 'LIVENESS: (C) two roles dispatched it: retiring_by is null');
update cron.job set command = 'alter table public.elsewhere400 detach partition public.elsewhere400_p4 concurrently' where jobid = 3;
select is(array[pg_temp.cmd(1), pg_temp.cmd(2)], array_fill(pg_temp.det('rd400', :'rd'), array[2]),
  'LIVENESS: (C) the owner''s and the administrator''s jobs hold rd400''s detach');
select pg_temp.cmd(2) \gexec
select ok(not pg_temp.attached('public.rd400', :'rd'), 'LIVENESS: (C) the administrator''s job landed rd400''s detach');
set role pgpm_test400_owner;
select set_config('t400.c2', pgpm.retire('public.rd400', :'rd')::text, false);
reset role;
select is(current_setting('t400.c2'), 'false', 'LIVENESS: (C) the owner cannot vouch for a retirement two roles dispatched');
select is(pgpm.retire('public.rd400', :'rd'), true, 'LIVENESS: (C) a superuser''s retire() completes rd400');
select ok(pg_temp.dropped('public.rd400', :'rd'), 'LIVENESS: (C) dropping its partition, retain_drop logged');
select is(array[pg_temp.cmd(1), pg_temp.cmd(2), pg_temp.cmd(3)], array['select 1', 'select 1', 'select 1'],
  'C: every job is idle, the one holding a detach no mark records included');
select is((select array_agg(id order by id) from public.rd400), array[55]::bigint[],
  'C: and rd400 keeps only its frontier row, ids 6 to 9 retired with the partition');


-- ==================== (D) a superuser dispatches, is demoted, and another superuser completes ====================
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pgpm_test400_admin') then
    create role pgpm_test400_admin superuser nobypassrls;
  end if;
end $$;
alter role pgpm_test400_admin superuser nobypassrls;   -- a re-run finds it demoted
grant usage on schema pgpm to pgpm_test400_admin;
grant all on all tables in schema pgpm to pgpm_test400_admin;
grant all on all sequences in schema pgpm to pgpm_test400_admin;
grant usage on schema cron to pgpm_test400_admin;
grant select, update on cron.job to pgpm_test400_admin;
insert into cron.job values (4, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test400_admin');
update cron.job set command = 'alter table public.elsewhere400 detach partition public.elsewhere400_p5 concurrently' where jobid = 3;
select pg_temp.mk('re400', array[0, 9]);
call pgpm.transmute('public.re400', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
select pg_temp.finish_mk('re400', 'pgpm_test400_admin') as re \gset
set role pgpm_test400_admin;
select set_config('t400.d', pgpm.retire('public.re400', :'re')::text, false);
reset role;
select is(current_setting('t400.d'), 'false', 'LIVENESS: (D) the admin''s retire(), a superuser''s, dispatches re400''s detach');
select is(array[pg_temp.cmd(1), pg_temp.cmd(2), pg_temp.cmd(3), pg_temp.cmd(4)], array_fill(pg_temp.det('re400', :'re'), array[4]),
  'LIVENESS: (D) and its dispatch armed all four roles'' jobs');
select is(pg_temp.mark('public.re400'), 't  t', 'D: the mark records the dispatch and no role');
alter role pgpm_test400_admin nosuperuser;
select ok(not rolsuper and not rolbypassrls, 'LIVENESS: (D) the admin is demoted') from pg_roles where rolname = 'pgpm_test400_admin';
select pg_temp.cmd(4) \gexec
select ok(not pg_temp.attached('public.re400', :'re'), 'LIVENESS: (D) the admin''s job landed re400''s detach');
set role pgpm_test400_admin;
select set_config('t400.d2', pgpm.retire('public.re400', :'re')::text, false);
reset role;
select is(current_setting('t400.d2'), 'false', 'D: the demoted admin''s tick does not complete it');
select ok((select method from pgpm.log where parent_table = 'public.re400'::regclass and lo = '0' and action = 'fail_retain_drop')
            ~ ('^public\.' || :'re' || ' is detached by its retirement, and role pgpm_test400_admin cannot read every pgpm_detach job .*Run maintenance as a superuser, and its tick drops it$'),
  'D: it logs fail_retain_drop naming a superuser to run as');
select is(array[pg_temp.cmd(1), pg_temp.cmd(2), pg_temp.cmd(3)], array_fill(pg_temp.det('re400', :'re'), array[3]),
  'D: and the other roles'' jobs still hold re400''s detach, for the tick that completes it');
select is(pgpm.retire('public.re400', :'re'), true, 'LIVENESS: (D) another superuser''s retire() completes re400');
select ok(pg_temp.dropped('public.re400', :'re'), 'LIVENESS: (D) dropping its partition, retain_drop logged');
select is(array[pg_temp.cmd(1), pg_temp.cmd(2), pg_temp.cmd(3), pg_temp.cmd(4)], array['select 1', 'select 1', 'select 1', 'select 1'],
  'D: every role''s job is idle, the demoted admin''s and the three it armed as a superuser');

-- ==================== (F) a cron.job with no username column: every job ====================
drop policy pgpm_test400_own on cron.job;
alter table cron.job disable row level security;
alter table cron.job drop column username;
update cron.job set command = 'alter table public.elsewhere400 detach partition public.elsewhere400_p6 concurrently' where jobid = 3;
select pg_temp.mk('rg400', array[4, 5]);
call pgpm.transmute('public.rg400', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
select pg_temp.finish_mk('rg400', null) as rg \gset
select is(pgpm.retire('public.rg400', :'rg'), false, 'LIVENESS: (F) the administrator''s retire() dispatches rg400''s detach');
select is(pg_temp.mark('public.rg400'), 't postgres t', 'F: with no job per role, the dispatch records its role');
update cron.job set command = 'alter table public.elsewhere400 detach partition public.elsewhere400_p6 concurrently' where jobid = 3;
select pg_temp.cmd(2) \gexec
select ok(not pg_temp.attached('public.rg400', :'rg'), 'LIVENESS: (F) the job landed rg400''s detach');
select is(pgpm.retire('public.rg400', :'rg'), true, 'LIVENESS: (F) the administrator''s retire() completes rg400');
select is(array[pg_temp.cmd(1), pg_temp.cmd(2), pg_temp.cmd(3), pg_temp.cmd(4)], array['select 1', 'select 1', 'select 1', 'select 1'],
  'F: and every job is idle: there is no username to scope by');

-- ==================== (E) the install clears a role an older release recorded for a wide dispatch ====================
select pg_temp.mk('rf400', array[1, 2]);
call pgpm.transmute('public.rf400', 'id', 10::bigint, p_obtain => 6, p_paused => true);
-- three rows, the lowest three cells: a superuser's dispatched mark, a non-superuser's, and a superuser's undispatched one
create temp table rf400_rows as
  select child_name, row_number() over (order by lo::bigint) as k from pgpm.part where parent_table = 'public.rf400'::regclass;
update pgpm.part p set retiring_at = now(),
                       detach_dispatched_oid = case when f.k < 3 then p.child_oid end,
                       retiring_by = case f.k when 2 then 'pgpm_test400_owner' else 'postgres' end
  from rf400_rows f where p.parent_table = 'public.rf400'::regclass and p.child_name = f.child_name and f.k <= 3;
select is((select count(*) from pgpm.part p join rf400_rows f using (child_name)
            where p.parent_table = 'public.rf400'::regclass and f.k <= 3 and p.retiring_at is not null), 3::bigint,
  'LIVENESS: (E) three marks, as an older release left them');
select is(pgpm._unrecord_wide_dispatchers(), 1, 'E: the backfill clears one mark');
select is((select array_agg(format('%s:%s:%s', f.k, p.retiring_by, p.detach_dispatched_oid is not null) order by f.k)
             from pgpm.part p join rf400_rows f using (child_name)
            where p.parent_table = 'public.rf400'::regclass and f.k <= 3),
          array['1::t', '2:pgpm_test400_owner:t', '3:postgres:f'],
  'E: the superuser''s dispatched mark, and neither a non-superuser''s nor a never-dispatched one');
-- the hand-made marks go, so nothing is left marked with no job holding it
update pgpm.part set retiring_at = null, retiring_by = null, detach_dispatched_oid = null
 where parent_table = 'public.rf400'::regclass;

select * from finish();
