-- retire()'s completion is kept when the caller cannot vouch that no pgpm_detach job it cannot see holds the detach (#1491).
--
-- THE BUG. retire() completes a retirement whose detach pgpm dispatched by returning the job to idle and dropping the
-- partition, deleting its pgpm.part row. pg_cron keeps one pgpm_detach job per role that ran pgpm.schedule() and shows a
-- non-superuser only its own (row security, username = current_user), so the table's non-superuser owner completing a
-- retirement the administrator dispatched idled only its own job. The administrator's stayed armed with the detach,
-- the row was gone, so nothing recorded it any more, and once the owner dropped and re-created the table on the same
-- grid the job's next run detached the namesake partition: rows out, nothing logged.
--
-- THE CONTRACT (_detach_job_vouched decides who can vouch).
--   PART A  the owner's retire() of a landed detach the administrator dispatched keeps it: nothing dropped, the row and
--           its mark kept, no job touched (the owner's own job holds another table's detach and keeps it),
--           fail_retain_drop naming the role to run as, counted. A superuser's retire() then idles the job and drops it.
--   PART B  kept, the row is the record #1490's refusals read once the owner drops the table: the re-created table's
--           transmute is refused, the owner's forget_missing() is refused, and a superuser's forget_missing() idles the
--           administrator's job, after which the conversion goes through and the job's run leaves its rows in place.
--   PART C  the #835 path, the one-step drop of a still-attached partition whose dispatched detach has not run (its
--           foreign key dropped since): the owner's retire() keeps it too; a superuser's idles the job and drops it.
--   PART D  the role whose own job alone holds the detach (retiring_by) can vouch: its retire() idles its job and drops
--           the partition, as before.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for cron.job
-- (with pg_cron's username column and its row-security policy) and cron.alter_job, as tests/395 does, and runs a
-- job's command with \gexec at the top level, as pg_cron does. What the owner observes goes through set_config.
--
-- ASYMMETRIC FIXTURES. Each part's table holds a different id set (A 1-3, B 11-12 then 14, 16, 18, C 21-24, D 31-35), and the
-- two jobs hold different commands, so an assertion aimed at the wrong table or job cannot pass.
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
  if not exists (select 1 from pg_roles where rolname = 'pgpm_test397_owner') then
    create role pgpm_test397_owner nosuperuser nobypassrls;
  end if;
end $$;
grant usage on schema pgpm to pgpm_test397_owner;
grant all on all tables in schema pgpm to pgpm_test397_owner;
grant all on all sequences in schema pgpm to pgpm_test397_owner;
grant create, usage on schema public to pgpm_test397_owner;
grant usage on schema cron to pgpm_test397_owner;
grant select, update on cron.job to pgpm_test397_owner;
-- the owner's job and the administrator's; pg_cron's row security: a role sees only the jobs it scheduled
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test397_owner'),
                            (2, 'pgpm_detach', current_database(), 'select 1', 'postgres');
create policy pgpm_test397_own on cron.job using (username = current_user);
alter table cron.job enable row level security;
create function pg_temp.cmd(p_job bigint) returns text language sql as $$ select command from cron.job where jobid = p_job $$;
create function pg_temp.mark(p_parent regclass, p_lo text) returns text language sql as $$
  select coalesce((select format('%s %s %s', retiring_at is not null, retiring_by, detach_dispatched_oid is not null)
                     from pgpm.part where parent_table = p_parent and lo = p_lo), 'no row')
$$;
create function pg_temp.actions(p_parent regclass, p_lo text) returns text[] language sql as $$
  select array_agg(action order by id) from pgpm.log where parent_table = p_parent and lo = p_lo
$$;
create function pg_temp.attached(p_parent regclass, p_child text) returns boolean language sql as $$
  select exists (select 1 from pg_inherits where inhparent = p_parent and inhrelid = to_regclass(format('public.%I', p_child)))
$$;
create function pg_temp.ids(p_rel text) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if to_regclass(format('public.%I', p_rel)) is null then return null; end if;
  execute format('select array_agg(id order by id) from public.%I', p_rel) into v;
  return v;
end $$;
-- the table, its referencing table and its partitions are the owner's: the administrator scheduled the jobs
create function pg_temp.to_owner(p_parent regclass) returns void language plpgsql as $$
declare r regclass;
begin
  for r in select p_parent union all select c.conrelid::regclass from pg_constraint c where c.confrelid = p_parent and c.contype = 'f'
           union all select inhrelid::regclass from pg_inherits where inhparent = p_parent loop
    execute format('alter table %s owner to pgpm_test397_owner', r);
  end loop;
end $$;
select ok(not rolsuper and not rolbypassrls, 'LIVENESS: the owner is neither a superuser nor exempt from row security')
  from pg_roles where rolname = 'pgpm_test397_owner';

-- ==================== (A) the owner cannot vouch for the administrator's job: kept ====================
create table public.ra397 (id bigint primary key, payload text);
insert into public.ra397 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.ra397', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.ra397 values (55, 'frontier');
create table public.ra397_ref (id bigint primary key, r bigint references public.ra397 (id));
insert into public.ra397_ref values (100, 55);
select pg_temp.to_owner('public.ra397');
select child_name as a_doomed from pgpm.part where parent_table = 'public.ra397'::regclass and lo = '0' \gset
select is(pgpm.retire('public.ra397', :'a_doomed'), false, 'LIVENESS: (A) the administrator''s retire() dispatches the detach');
-- the owner's job has since taken another table's detach (a detached retirement holds no slot)
update cron.job set command = 'alter table public.elsewhere397 detach partition public.elsewhere397_p1 concurrently' where jobid = 1;
select is(pg_temp.cmd(2), format('alter table public.ra397 detach partition public.%I concurrently', :'a_doomed'),
  'LIVENESS: (A) the administrator''s job holds the detach');
select pg_temp.cmd(2) \gexec
select ok(not pg_temp.attached('public.ra397', :'a_doomed') and to_regclass(format('public.%I', :'a_doomed')) is not null,
  'LIVENESS: (A) the job''s run landed the detach');
select is(pg_temp.mark('public.ra397', '0'), 't postgres t', 'LIVENESS: (A) the mark records the administrator''s dispatch');
set role pgpm_test397_owner;
select set_config('t397.a_seen', (select string_agg(format('%s:%s', username, command), ',') from cron.job), false);
select set_config('t397.a', pgpm.retire('public.ra397', :'a_doomed')::text, false);
reset role;
select is(current_setting('t397.a_seen'),
  'pgpm_test397_owner:alter table public.elsewhere397 detach partition public.elsewhere397_p1 concurrently',
  'LIVENESS: (A) the owner sees one job, its own, holding another table''s detach');
select is(current_setting('t397.a'), 'false', 'A: the owner''s retire() does not complete the retirement');
select is(pg_temp.ids(:'a_doomed'), array[1, 2, 3]::bigint[],
  'A: the detached partition stands, with ids 1, 2, 3');
select is(pg_temp.mark('public.ra397', '0'), 't postgres t', 'A: its row keeps the mark, the dispatch and its role');
select is(pg_temp.cmd(2), format('alter table public.ra397 detach partition public.%I concurrently', :'a_doomed'),
  'A: the administrator''s job still holds the detach, for the tick that completes it');
select is(pg_temp.cmd(1), 'alter table public.elsewhere397 detach partition public.elsewhere397_p1 concurrently',
  'A: and the owner''s job keeps the other table''s detach: nothing was idled');
select is(pg_temp.actions('public.ra397', '0'), array['retain_detach', 'fail_retain_drop'],
  'A: logged fail_retain_drop, and no retain_drop');
select ok((select method from pgpm.log where parent_table = 'public.ra397'::regclass and lo = '0' and action = 'fail_retain_drop')
            ~ ('^public\.' || :'a_doomed' || ' is detached by its retirement, and role pgpm_test397_owner cannot read every pgpm_detach job that may still hold its detach .*kept, not dropped\. Run maintenance as role postgres or a superuser, and its tick drops it$'),
  'A: naming the role that cannot read the job and the role to run as');
select ok((select retain_drop_failures from pgpm.status() where parent = 'public.ra397'::regclass) > 0, 'A: and status() counts it');
select is(pgpm.retire('public.ra397', :'a_doomed'), true, 'A: a superuser''s retire() completes it');
select is(pg_temp.cmd(2), 'select 1', 'A: returning the administrator''s job to idle');
select ok(to_regclass(format('public.%I', :'a_doomed')) is null and pg_temp.mark('public.ra397', '0') = 'no row',
  'A: and dropping the partition and its row');

-- ==================== (B) the kept row is what the dropped table's refusals read ====================
update cron.job set command = 'select 1' where jobid = 1;
create table public.rb397 (id bigint primary key, payload text);
insert into public.rb397 values (11, 'k'), (12, 'l');
call pgpm.transmute('public.rb397', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.rb397 values (57, 'frontier');
create table public.rb397_ref (id bigint primary key, r bigint references public.rb397 (id));
insert into public.rb397_ref values (200, 57);
select pg_temp.to_owner('public.rb397');
select child_name as b_doomed from pgpm.part where parent_table = 'public.rb397'::regclass and lo = '10' \gset
select is(pgpm.retire('public.rb397', :'b_doomed'), false, 'LIVENESS: (B) the administrator''s retire() dispatches the detach');
update cron.job set command = 'select 1' where jobid = 1;   -- the owner's re-run of pgpm.schedule() idles its own job
select pg_temp.cmd(2) \gexec
select ok(not pg_temp.attached('public.rb397', :'b_doomed'), 'LIVENESS: (B) the administrator''s job landed the detach');
set role pgpm_test397_owner;
select set_config('t397.b', pgpm.retire('public.rb397', :'b_doomed')::text, false);
reset role;
select is(current_setting('t397.b'), 'false', 'B: the owner''s retire() keeps it');
select 'public.rb397'::regclass::oid as b_oid \gset
-- the owner starts over: the table, its referencing table and the kept partition dropped, the table re-created
drop table public.rb397_ref;
drop table public.rb397;
select format('drop table if exists public.%I', :'b_doomed') \gexec
select ok(exists (select 1 from pgpm._dropped_retirements() where child_name = :'b_doomed'),
  'B: the dropped table''s state still records the retirement');
create table public.rb397 (id bigint primary key, payload text);
insert into public.rb397 values (14, 'x'), (16, 'y'), (18, 'z');
do $$
begin
  call pgpm.transmute('public.rb397', 'id', 10::bigint, p_obtain => 6, p_paused => true);
  perform set_config('t397.b_tm', 'not refused', false);
exception when others then
  perform set_config('t397.b_tm', sqlstate || ' ' || sqlerrm, false);
end $$;
select ok(current_setting('t397.b_tm') ~ ('^P0001 pg_partition_magician: transmute refused to make partition ' || :'b_doomed'
            || ': run pgpm\.forget_missing\(\) first\.'),
  'B: the re-created table''s transmute is refused the recorded name');
select ok(not exists (select 1 from pgpm.config where parent_table = 'public.rb397'::regclass)
          and (select array_agg(id order by id) from public.rb397) = array[14, 16, 18]::bigint[],
  'B: and leaves it unconverted, with ids 14, 16, 18');
set role pgpm_test397_owner;
do $$
begin
  perform pgpm.forget_missing();
  perform set_config('t397.b_fm', 'not refused', false);
exception when others then
  perform set_config('t397.b_fm', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select ok(current_setting('t397.b_fm') ~ ('^P0001 pg_partition_magician: forget_missing refused, nothing cleared: the dropped table with oid '
            || :b_oid || ' was retiring ' || :'b_doomed' || ', whose detach pgpm dispatched .*Run select \* from pgpm\.forget_missing\(\); as role postgres or a superuser\.$'),
  'B: the owner''s forget_missing() is refused, naming the role to run it as');
select is(pg_temp.cmd(2), format('alter table public.rb397 detach partition public.%I concurrently', :'b_doomed'),
  'LIVENESS: (B) the administrator''s job still holds the detach of the recorded name');
select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:b_oid]::oid[],
  'B: a superuser''s forget_missing() forgets the dropped table');
select is(pg_temp.cmd(2), 'select 1', 'B: and idles the administrator''s job');
call pgpm.transmute('public.rb397', 'id', 10::bigint, p_obtain => 6, p_paused => true);
select ok(pg_temp.attached('public.rb397', :'b_doomed'), 'LIVENESS: (B) the conversion then goes through, its monolith under that name');
select pg_temp.cmd(2) \gexec
select is((select array_agg(id order by id) from public.rb397), array[14, 16, 18]::bigint[],
  'B: and the job''s next run leaves ids 14, 16, 18 in the table');

-- ==================== (C) the #835 one-step drop, its dispatched detach not yet run: kept ====================
create table public.rc397 (id bigint primary key, payload text);
insert into public.rc397 values (21, 'u'), (22, 'v'), (23, 'w'), (24, 'x');
call pgpm.transmute('public.rc397', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.rc397 values (66, 'frontier');
create table public.rc397_ref (id bigint primary key, r bigint references public.rc397 (id));
insert into public.rc397_ref values (300, 66);
select pg_temp.to_owner('public.rc397');
select child_name as c_doomed from pgpm.part where parent_table = 'public.rc397'::regclass and lo = '20' \gset
select is(pgpm.retire('public.rc397', :'c_doomed'), false, 'LIVENESS: (C) the administrator''s retire() dispatches the detach');
update cron.job set command = 'alter table public.elsewhere397 detach partition public.elsewhere397_p3 concurrently' where jobid = 1;
drop table public.rc397_ref;   -- the incoming foreign key goes before pg_cron runs the detach
select ok(pg_temp.attached('public.rc397', :'c_doomed')
          and not exists (select 1 from pg_constraint where confrelid = 'public.rc397'::regclass and contype = 'f'),
  'LIVENESS: (C) the partition is attached and nothing references the table: the one-step drop path');
select is(pg_temp.cmd(2), format('alter table public.rc397 detach partition public.%I concurrently', :'c_doomed'),
  'LIVENESS: (C) the administrator''s job holds the detach');
set role pgpm_test397_owner;
select set_config('t397.c', pgpm.retire('public.rc397', :'c_doomed')::text, false);
reset role;
select is(current_setting('t397.c'), 'false', 'C: the owner''s retire() does not complete it');
select ok(pg_temp.attached('public.rc397', :'c_doomed') and pg_temp.ids(:'c_doomed') = array[21, 22, 23, 24]::bigint[],
  'C: the partition stays attached, with ids 21 to 24');
select is(pg_temp.mark('public.rc397', '20'), 't postgres t', 'C: its row keeps the mark');
select is(pg_temp.cmd(1), 'alter table public.elsewhere397 detach partition public.elsewhere397_p3 concurrently',
  'C: and the owner''s job keeps the other table''s detach');
select ok((select method from pgpm.log where parent_table = 'public.rc397'::regclass and lo = '20' and action = 'fail_retain_drop')
            ~ ('^public\.' || :'c_doomed' || ' ends its retirement in a one-step drop, and role pgpm_test397_owner cannot read every pgpm_detach job .*Run maintenance as role postgres or a superuser, and its tick drops it$'),
  'C: logged fail_retain_drop, naming the role to run as');
select is(pgpm.retire('public.rc397', :'c_doomed'), true, 'C: a superuser''s retire() completes it');
select is(pg_temp.cmd(2), 'select 1', 'C: returning the administrator''s job to idle');
select is(pg_temp.cmd(1), 'alter table public.elsewhere397 detach partition public.elsewhere397_p3 concurrently',
  'C: and leaving another table''s detach where it is (#835''s conditional disarm)');
select ok(to_regclass(format('public.%I', :'c_doomed')) is null and pg_temp.mark('public.rc397', '20') = 'no row',
  'C: and dropping the partition and its row');

-- ==================== (D) the role whose own job alone holds the detach completes it ====================
update cron.job set command = 'select 1' where jobid = 1;
update cron.job set command = 'alter table public.elsewhere397 detach partition public.elsewhere397_p4 concurrently' where jobid = 2;
create table public.rd397 (id bigint primary key, payload text);
insert into public.rd397 select g, 'd' from generate_series(31, 35) g;
call pgpm.transmute('public.rd397', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.rd397 values (78, 'frontier');
create table public.rd397_ref (id bigint primary key, r bigint references public.rd397 (id));
insert into public.rd397_ref values (400, 78);
select pg_temp.to_owner('public.rd397');
select child_name as d_doomed from pgpm.part where parent_table = 'public.rd397'::regclass and lo = '30' \gset
set role pgpm_test397_owner;
select set_config('t397.d1', pgpm.retire('public.rd397', :'d_doomed')::text, false);
reset role;
select is(current_setting('t397.d1') || ' ' || pg_temp.cmd(1),
  format('false alter table public.rd397 detach partition public.%I concurrently', :'d_doomed'),
  'LIVENESS: (D) the owner''s retire() dispatches the detach through its own job');
select is(pg_temp.mark('public.rd397', '30'), 't pgpm_test397_owner t', 'LIVENESS: (D) the mark records the owner''s dispatch');
select pg_temp.cmd(1) \gexec
select ok(not pg_temp.attached('public.rd397', :'d_doomed'), 'LIVENESS: (D) the owner''s job landed the detach');
set role pgpm_test397_owner;
select set_config('t397.d2', pgpm.retire('public.rd397', :'d_doomed')::text, false);
reset role;
select is(current_setting('t397.d2'), 'true', 'D: the owner''s retire() completes it');
select ok(to_regclass(format('public.%I', :'d_doomed')) is null and pg_temp.mark('public.rd397', '30') = 'no row',
  'D: dropping the partition and its row');
select is(pg_temp.actions('public.rd397', '30'), array['retain_detach', 'retain_drop'], 'D: logged retain_drop, nothing refused');
select is(pg_temp.cmd(1), 'select 1', 'D: and its own job is idle');
select is(pg_temp.cmd(2), 'alter table public.elsewhere397 detach partition public.elsewhere397_p4 concurrently',
  'D: the administrator''s job, which never held this detach, is as it was');

select * from finish();
