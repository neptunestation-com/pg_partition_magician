-- A retirement that dispatched a detach and ends in the one-step DROP disarms its own detach (issue #835).
--
-- THE BUG. retire() returned the standing pgpm_detach job to idle only inside its referenced branch. A
-- partition marked retiring_at by a call that saw an incoming FK, whose FK is then dropped before pg_cron
-- runs the detach, is finished by the next call on the ONE-STEP path (a bare DROP of the still-attached
-- partition), which never disarmed: the job kept running `ALTER TABLE ... DETACH PARTITION <dropped name>
-- CONCURRENTLY` every tick, against docs/reference.md's "returns it to idle once the drop lands", until a
-- later dispatch overwrote it.
--
-- THE CONTRACT.
--   PART A  the one-step DROP of a dispatched retirement returns the job to idle (`select 1`) once the drop
--           has landed, and logs exactly retain_detach then retain_drop.
--   PART B  the disarm is CONDITIONAL, the #407 rule: when the job holds another retirement's command by the
--           time the drop lands, the one-step DROP leaves that command alone.
--   PART C  an ordinary one-step retirement, which never dispatched anything, does not touch the job.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job, as tests/194 and 204 do. Nothing here runs the armed command.
--
-- ASYMMETRIC FIXTURES. Each part's doomed partition holds a different set of ids (A 1, 2, 3; B 5, 6; C 7),
-- and the job's stand-in commands differ per part, so a disarm aimed at the wrong command cannot pass.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(17);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

-- ==================== (A) dispatched, FK dropped, finished by the one-step DROP ====================
create table public.rd229 (id bigint primary key, payload text);
insert into public.rd229 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.rd229', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.rd229 values (55, 'frontier');
create table public.rd229_ref (id bigint primary key, rd_id bigint references public.rd229 (id));
insert into public.rd229_ref values (100, 55);
select child_name as a_doomed from pgpm.part where parent_table = 'public.rd229'::regclass and lo = '0' \gset

select is(pgpm.retire('public.rd229', :'a_doomed'), false, 'LIVENESS: the first retire() takes the referenced path');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.rd229 detach partition public.%I concurrently', :'a_doomed'),
  'LIVENESS: and armed pgpm_detach with this partition''s detach');

alter table public.rd229_ref drop constraint rd229_ref_rd_id_fkey;   -- before pg_cron reaches the detach

select is(pgpm.retire('public.rd229', :'a_doomed'), true, 'LIVENESS: the next retire() drops the partition on the one-step path');
select ok(to_regclass(format('public.%I', :'a_doomed')) is null, 'LIVENESS: the partition is gone');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'public.rd229'::regclass and lo = '0'
            and action in ('retain_detach', 'retain_drop', 'fail_retain_drop', 'fail_retain_identity')),
  array['retain_detach', 'retain_drop'], 'logged exactly retain_detach then retain_drop');
select is((select command from cron.job where jobname = 'pgpm_detach'), 'select 1',
  'once the drop has landed, pgpm_detach is back to idle and no longer runs a detach of the dropped partition');
select is((select array_agg(id order by id) from public.rd229), array[55]::bigint[],
  'the dropped partition took exactly its own rows');

-- ==================== (B) the job holds another retirement's command: left alone ====================
create table public.rb229 (id bigint primary key, payload text);
insert into public.rb229 values (5, 'e'), (6, 'f');
call pgpm.transmute('public.rb229', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.rb229 values (57, 'frontier');
create table public.rb229_ref (id bigint primary key, rb_id bigint references public.rb229 (id));
insert into public.rb229_ref values (200, 57);
select child_name as b_doomed from pgpm.part where parent_table = 'public.rb229'::regclass and lo = '0' \gset

select is(pgpm.retire('public.rb229', :'b_doomed'), false, 'LIVENESS: B''s first retire() takes the referenced path');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.rb229 detach partition public.%I concurrently', :'b_doomed'),
  'LIVENESS: and armed pgpm_detach with B''s detach');

-- another retirement's dispatch now holds the job (any command that is not B's own)
update cron.job set command = 'alter table public.elsewhere229 detach partition public.elsewhere229_p1 concurrently'
 where jobname = 'pgpm_detach';
alter table public.rb229_ref drop constraint rb229_ref_rb_id_fkey;

select is(pgpm.retire('public.rb229', :'b_doomed'), true, 'LIVENESS: B''s next retire() drops it on the one-step path');
select ok(to_regclass(format('public.%I', :'b_doomed')) is null, 'LIVENESS: B''s partition is gone');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  'alter table public.elsewhere229 detach partition public.elsewhere229_p1 concurrently',
  'the one-step DROP left another retirement''s armed command in place');
select is((select array_agg(id order by id) from public.rb229), array[57]::bigint[],
  'B''s dropped partition took exactly its own rows');

-- ==================== (C) an ordinary one-step retirement does not touch the job ====================
create table public.rc229 (id bigint primary key, payload text);
insert into public.rc229 values (7, 'g');
call pgpm.transmute('public.rc229', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.rc229 values (58, 'frontier');
select child_name as c_doomed from pgpm.part where parent_table = 'public.rc229'::regclass and lo = '0' \gset
update cron.job set command = format('alter table public.rc229 detach partition public.%I concurrently', :'c_doomed')
 where jobname = 'pgpm_detach';

select ok((select retiring_at is null from pgpm.part where parent_table = 'public.rc229'::regclass and child_name = :'c_doomed'),
  'LIVENESS: C''s partition was never dispatched (no retiring_at)');
select is(pgpm.retire('public.rc229', :'c_doomed'), true, 'LIVENESS: C''s retire() drops it on the one-step path');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.rc229 detach partition public.%I concurrently', :'c_doomed'),
  'a one-step retirement that never dispatched leaves the job as it found it, even holding its own name');
select is((select array_agg(id order by id) from public.rc229), array[58]::bigint[],
  'C''s dropped partition took exactly its own row');

select * from finish();
