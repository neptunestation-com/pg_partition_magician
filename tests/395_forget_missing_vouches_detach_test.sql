-- forget_missing() disarms every pgpm_detach job it can see, and refuses a disarm it cannot vouch for (#1488, #1461).
--
-- THE BUGS. pg_cron keeps one pgpm_detach job per role that ran pgpm.schedule(), and shows a non-superuser only its own
-- (row security, username = current_user). forget_missing's #893 disarm (tests/246) read ONE unordered row of cron.job
-- and judged the disarm from that command alone, so:
--   #1488  a superuser, with the owner's idle job read first, left the administrator's job armed with the forgotten
--          retirement's DETACH ... CONCURRENTLY;
--   #1461  the table's non-superuser owner saw only its own idle job and left the administrator's armed.
-- Either way the forgotten rows were gone, nothing else would ever disarm the job, and its next run detached the
-- same-named partition of a table re-created under the same name and grid: rows out, nothing logged.
--
-- THE CONTRACT.
--   PART A  (#1488) a superuser's forget_missing() idles every job holding a forgotten retirement's detach, whichever
--           row an unordered read returns first, and leaves a job holding another table's command as it is.
--   PART B  (#1461) a non-superuser that is not the role whose job holds a dispatched detach (retiring_by) is refused,
--           before anything is cleared (a second dropped table with no retirement is not cleared either), and told to
--           run it as that role or a superuser; a superuser's call then idles the job and clears both.
--   PART C  the one role whose own job holds the detach (retiring_by) is not refused: its call idles its job.
--   PART D  a mark older than #1451's record (no retiring_by, no record of the dispatch) is refused for a
--           non-superuser, naming a superuser as the one who can run it.
--   PART E  a mark this release made and never dispatched is held by no job: the non-superuser's call clears it, and
--           it is no record the build refusals read (_dropped_retirements).
--   PART F  a retirement two roles dispatched (the dispatch recorded, retiring_by nulled, tests/194 part S) is
--           refused for a non-superuser, naming a superuser: a null role is no role that can vouch.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for cron.job
-- (with pg_cron's username column and its row-security policy) and cron.alter_job, as tests/194 does. pgTAP's
-- bookkeeping is this session's temp objects, which the role cannot touch, so what the role observes goes through
-- set_config and is asserted after reset role.
--
-- ASYMMETRIC FIXTURES. Each part's table holds a different id set (A 1-3, B 11-12, C 21-24, D 31, E 41-45, F 33-36), and the
-- three jobs hold three different commands, so an assertion aimed at the wrong table or job cannot pass.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(40);

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
  if not exists (select 1 from pg_roles where rolname = 'pgpm_test395_owner') then
    create role pgpm_test395_owner nosuperuser nobypassrls;
  end if;
end $$;
grant usage on schema pgpm to pgpm_test395_owner;
grant all on all tables in schema pgpm to pgpm_test395_owner;
grant all on all sequences in schema pgpm to pgpm_test395_owner;
grant create, usage on schema public to pgpm_test395_owner;
grant usage on schema cron to pgpm_test395_owner;
grant select, update on cron.job to pgpm_test395_owner;
-- three jobs: the owner's (created first), another role's, the administrator's
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test395_owner'),
                            (2, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test395_other'),
                            (3, 'pgpm_detach', current_database(), 'select 1', 'postgres');
create function pg_temp.cmd(p_job bigint) returns text language sql as $$ select command from cron.job where jobid = p_job $$;
-- a table with a referenced partition at lo 10, so its retirement goes through the pgpm_detach job
create function pg_temp.mk(p_rel text, p_ids int[]) returns void language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_rel);
  execute format('insert into public.%I select i, ''v'' from unnest(%L::int[]) i', p_rel, p_ids);
end $$;
-- the administrator's dispatch reaches every job it sees; then the owner's re-run of pgpm.schedule() idles its own,
-- the other role's job takes another table's detach, and the administrator's is touched last, so an unordered read
-- of the jobs returns the owner's idle one first (the order #1488 met)
create function pg_temp.after_admin_dispatch() returns void language plpgsql as $$
begin
  update cron.job set command = 'select 1' where jobid = 1;
  update cron.job set command = 'alter table public.elsewhere395 detach partition public.elsewhere395_p1 concurrently' where jobid = 2;
  update cron.job set command = command where jobid = 3;
end $$;

-- ==================== (A) #1488: a superuser judges every job ====================
select pg_temp.mk('fa395', array[1, 2, 3]);
call pgpm.transmute('public.fa395', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.fa395 values (15, 'old'), (55, 'frontier');
create table public.fa395_ref (id bigint primary key, fa_id bigint references public.fa395 (id));
insert into public.fa395_ref values (100, 55);
select child_name as a_doomed from pgpm.part where parent_table = 'public.fa395'::regclass and lo = '10' \gset
select is(pgpm.retire('public.fa395', :'a_doomed'), false, 'LIVENESS: (A) retire() takes the referenced path');
select pg_temp.after_admin_dispatch();
select is(pg_temp.cmd(3), format('alter table public.fa395 detach partition public.%I concurrently', :'a_doomed'),
  'LIVENESS: (A) the administrator''s job holds the doomed cell''s detach');
select is((select command from cron.job where jobname = 'pgpm_detach' and database = current_database() limit 1), 'select 1',
  'LIVENESS: (A) an unordered read of the jobs returns an idle one first');
select (select oid from pg_class where oid = 'public.fa395'::regclass) as a_oid \gset
drop table public.fa395 cascade;
select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:a_oid]::oid[],
  'LIVENESS: (A) forget_missing() forgot exactly the dropped table');
select is(pg_temp.cmd(3), 'select 1', 'A: forget_missing() idled the administrator''s job, not only the first row it read');
select is(pg_temp.cmd(2), 'alter table public.elsewhere395 detach partition public.elsewhere395_p1 concurrently',
  'A: and left another table''s command in the other role''s job');
select is(pg_temp.cmd(1), 'select 1', 'A: and the owner''s idle job idle');

-- pg_cron's own row security from here on: a role sees only the jobs it scheduled
create policy pgpm_test395_own on cron.job using (username = current_user);
alter table cron.job enable row level security;
select ok(not rolsuper and not rolbypassrls, 'LIVENESS: the owner is neither a superuser nor exempt from row security')
  from pg_roles where rolname = 'pgpm_test395_owner';

-- ==================== (B) #1461: the owner cannot vouch for the administrator's job ====================
select pg_temp.mk('fbx395', array[12]);   -- dropped too, with no retirement: older, so its oid comes first
call pgpm.transmute('public.fbx395', 'id', 10::bigint, p_obtain => 2, p_paused => true);
select pg_temp.mk('fb395', array[11]);
call pgpm.transmute('public.fb395', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.fb395 values (58, 'frontier');
create table public.fb395_ref (id bigint primary key, fb_id bigint references public.fb395 (id));
insert into public.fb395_ref values (300, 58);
select child_name as b_doomed from pgpm.part where parent_table = 'public.fb395'::regclass and lo = '10' \gset
select is(pgpm.retire('public.fb395', :'b_doomed'), false, 'LIVENESS: (B) the administrator''s retire() takes the referenced path');
select pg_temp.after_admin_dispatch();
select is(pg_temp.cmd(3), format('alter table public.fb395 detach partition public.%I concurrently', :'b_doomed'),
  'LIVENESS: (B) the administrator''s job holds the detach');
select is((select format('%s %s', retiring_by, detach_dispatched_oid is not null) from pgpm.part
            where parent_table = 'public.fb395'::regclass and child_name = :'b_doomed'), 'postgres t',
  'LIVENESS: (B) the mark records the administrator''s dispatch');
select (select oid from pg_class where oid = 'public.fb395'::regclass) as b_oid,
       (select oid from pg_class where oid = 'public.fbx395'::regclass) as bx_oid \gset
drop table public.fb395 cascade;
drop table public.fbx395 cascade;
set role pgpm_test395_owner;
select set_config('t395.b_seen', (select string_agg(format('%s:%s', username, command), ',') from cron.job), false);
do $$
begin
  perform pgpm.forget_missing();
  perform set_config('t395.b', 'not refused', false);
exception when others then
  perform set_config('t395.b', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select is(current_setting('t395.b_seen'), 'pgpm_test395_owner:select 1', 'LIVENESS: (B) the owner sees one job, its own, idle');
select ok(current_setting('t395.b') ~ ('^P0001 pg_partition_magician: forget_missing refused, nothing cleared: the dropped table with oid '
            || :b_oid || ' was retiring ' || :'b_doomed' || ', whose detach pgpm dispatched .*role pgpm_test395_owner cannot read every job .*Run select \* from pgpm\.forget_missing\(\); as role postgres or a superuser\.$'),
  'B: the owner''s forget_missing() is refused, naming the retirement and who can run it');
select is((select array_agg(parent_table::oid order by parent_table::oid) from pgpm.config
            where parent_table::oid in (:b_oid, :bx_oid)), array[:bx_oid, :b_oid]::oid[],
  'B: nothing was cleared: both dropped tables are still registered, the one with no retirement too');
select ok(exists (select 1 from pgpm.part where parent_table = :b_oid::regclass and child_name = :'b_doomed' and retiring_at is not null),
  'B: and the retiring row is still there');
select is(pg_temp.cmd(3), format('alter table public.fb395 detach partition public.%I concurrently', :'b_doomed'),
  'B: and the administrator''s job is as it was');
select is((select array_agg(parent_oid order by parent_oid) from pgpm.forget_missing()), array[:bx_oid, :b_oid]::oid[],
  'B: a superuser''s forget_missing() then clears both');
select is(pg_temp.cmd(3), 'select 1', 'B: and idles the administrator''s job');

-- ==================== (C) the role whose own job holds the detach can vouch ====================
select pg_temp.mk('fc395', array[21, 22, 23, 24]);
call pgpm.transmute('public.fc395', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.fc395 values (65, 'frontier');
create table public.fc395_ref (id bigint primary key, fc_id bigint references public.fc395 (id));
insert into public.fc395_ref values (400, 65);
select child_name as c_doomed from pgpm.part where parent_table = 'public.fc395'::regclass and lo = '20' \gset
select format('alter table %s owner to pgpm_test395_owner', r) from (
  select 'public.fc395'::regclass r union all select 'public.fc395_ref'::regclass
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.fc395'::regclass) t \gexec
set role pgpm_test395_owner;
select set_config('t395.c_retire', pgpm.retire('public.fc395', :'c_doomed')::text, false);
reset role;
select is(current_setting('t395.c_retire'), 'false', 'LIVENESS: (C) the owner''s retire() takes the referenced path');
select is(pg_temp.cmd(1), format('alter table public.fc395 detach partition public.%I concurrently', :'c_doomed'),
  'LIVENESS: (C) and armed the owner''s own job');
select is(pg_temp.cmd(3), 'select 1', 'LIVENESS: (C) and not the administrator''s, which it cannot see');
select is((select retiring_by::text from pgpm.part where parent_table = 'public.fc395'::regclass and child_name = :'c_doomed'),
  'pgpm_test395_owner', 'LIVENESS: (C) the mark records the owner''s dispatch');
select (select oid from pg_class where oid = 'public.fc395'::regclass) as c_oid \gset
drop table public.fc395 cascade;
set role pgpm_test395_owner;
do $$
begin
  perform set_config('t395.c', (select string_agg(parent_oid::text, ',') from pgpm.forget_missing()), false);
exception when others then
  perform set_config('t395.c', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select is(current_setting('t395.c'), :'c_oid', 'C: the owner''s forget_missing() is not refused and clears the table');
select is(pg_temp.cmd(1), 'select 1', 'C: and idles its own job');

-- ==================== (D) a mark older than the record: only a superuser vouches ====================
select pg_temp.mk('fd395', array[31]);
call pgpm.transmute('public.fd395', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.fd395 values (75, 'frontier');
create table public.fd395_ref (id bigint primary key, fd_id bigint references public.fd395 (id));
insert into public.fd395_ref values (500, 75);
select child_name as d_doomed from pgpm.part where parent_table = 'public.fd395'::regclass and lo = '30' \gset
select is(pgpm.retire('public.fd395', :'d_doomed'), false, 'LIVENESS: (D) the administrator''s retire() takes the referenced path');
select pg_temp.after_admin_dispatch();
-- as a pgpm older than #1451 left it: no role, no record of the dispatch
update pgpm.part set retiring_by = null, detach_dispatched_oid = null
 where parent_table = 'public.fd395'::regclass and child_name = :'d_doomed';
select is(pg_temp.cmd(3), format('alter table public.fd395 detach partition public.%I concurrently', :'d_doomed'),
  'LIVENESS: (D) the administrator''s job holds the detach');
select (select oid from pg_class where oid = 'public.fd395'::regclass) as d_oid \gset
drop table public.fd395 cascade;
set role pgpm_test395_owner;
do $$
begin
  perform pgpm.forget_missing();
  perform set_config('t395.d', 'not refused', false);
exception when others then
  perform set_config('t395.d', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select ok(current_setting('t395.d') ~ ('^P0001 pg_partition_magician: forget_missing refused, nothing cleared: the dropped table with oid '
            || :d_oid || ' was retiring ' || :'d_doomed' || ', whose detach pgpm may have dispatched .*as a superuser\.$'),
  'D: a mark older than the record is refused for the owner, naming a superuser');
select ok(exists (select 1 from pgpm.config where parent_table = :d_oid::regclass), 'D: and nothing was cleared');
select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:d_oid]::oid[], 'D: a superuser''s call clears it');
select is(pg_temp.cmd(3), 'select 1', 'D: and idles the administrator''s job');

-- ==================== (E) a mark never dispatched is held by no job ====================
select pg_temp.mk('fe395', array[41, 42, 43, 44, 45]);
call pgpm.transmute('public.fe395', 'id', 10::bigint, p_obtain => 6, p_paused => true);
select child_name as e_marked from pgpm.part where parent_table = 'public.fe395'::regclass and lo = '40' \gset
-- this release's mark whose dispatch was refused: a role recorded, no record of a dispatch
update pgpm.part set retiring_at = now(), retiring_by = 'postgres'
 where parent_table = 'public.fe395'::regclass and child_name = :'e_marked';
select is((select format('%s %s', retiring_by, detach_dispatched_oid is null) from pgpm.part
            where parent_table = 'public.fe395'::regclass and child_name = :'e_marked'), 'postgres t',
  'LIVENESS: (E) the mark records a role and no dispatch');
select (select oid from pg_class where oid = 'public.fe395'::regclass) as e_oid \gset
drop table public.fe395 cascade;
-- #1491: forget_missing's vouch (_detach_job_vouched) takes such a mark too, so the record itself is asserted, which the
-- build refusals read: no name of it is refused
select ok(not exists (select 1 from pgpm._dropped_retirements() where child_name = :'e_marked'),
  'E: the dropped table''s never-dispatched mark is no retirement a job may hold');
set role pgpm_test395_owner;
do $$
begin
  perform set_config('t395.e', (select string_agg(parent_oid::text, ',') from pgpm.forget_missing()), false);
exception when others then
  perform set_config('t395.e', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select is(current_setting('t395.e'), :'e_oid', 'E: the owner''s forget_missing() is not refused and clears it');
select ok(not exists (select 1 from pgpm.part where parent_table = :e_oid::regclass), 'E: with its rows');

-- ==================== (F) a retirement two roles dispatched: only a superuser vouches ====================
select pg_temp.mk('ff395', array[33, 34, 36]);
call pgpm.transmute('public.ff395', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.ff395 values (75, 'frontier');
create table public.ff395_ref (id bigint primary key, ff_id bigint references public.ff395 (id));
insert into public.ff395_ref values (600, 75);
select child_name as f_doomed from pgpm.part where parent_table = 'public.ff395'::regclass and lo = '30' \gset
select is(pgpm.retire('public.ff395', :'f_doomed'), false, 'LIVENESS: (F) the administrator''s retire() takes the referenced path');
select pg_temp.after_admin_dispatch();
-- as another role's re-dispatch leaves it (#1459): the dispatch recorded, no one role
update pgpm.part set retiring_by = null
 where parent_table = 'public.ff395'::regclass and child_name = :'f_doomed';
select is((select format('%s %s', coalesce(retiring_by::text, 'null'), detach_dispatched_oid is not null) from pgpm.part
            where parent_table = 'public.ff395'::regclass and child_name = :'f_doomed'), 'null t',
  'LIVENESS: (F) the mark records a dispatch and no one role');
select is(pg_temp.cmd(3), format('alter table public.ff395 detach partition public.%I concurrently', :'f_doomed'),
  'LIVENESS: (F) the administrator''s job holds the detach');
select (select oid from pg_class where oid = 'public.ff395'::regclass) as f_oid \gset
drop table public.ff395 cascade;
set role pgpm_test395_owner;
do $$
begin
  perform pgpm.forget_missing();
  perform set_config('t395.f', 'not refused', false);
exception when others then
  perform set_config('t395.f', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select ok(current_setting('t395.f') ~ ('^P0001 pg_partition_magician: forget_missing refused, nothing cleared: the dropped table with oid '
            || :f_oid || ' was retiring ' || :'f_doomed' || ', whose detach pgpm dispatched .*as a superuser\.$'),
  'F: a retirement two roles dispatched is refused for the owner, naming a superuser');
select ok(exists (select 1 from pgpm.config where parent_table = :f_oid::regclass), 'F: and nothing was cleared');
select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:f_oid]::oid[], 'F: a superuser''s call clears it');

alter table cron.job disable row level security;
select * from finish();
