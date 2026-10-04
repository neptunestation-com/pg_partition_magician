-- forget_missing() returns the pgpm_detach job to idle when it forgets the retirement that armed it (issue #893).
--
-- THE BUG. A referenced partition's retirement arms the standing pgpm_detach job with `ALTER TABLE <parent>
-- DETACH PARTITION <child> CONCURRENTLY`, naming both relations by NAME. When the managed table is dropped
-- without untransmute before pg_cron runs that detach, and forget_missing() then clears its pgpm state (the
-- retiring pgpm.part row with it), nothing was left that would ever disarm the job: every pg_cron run
-- re-executed the command. Partition names are a pure function of the table's name and grid, so a table
-- re-created under the same name and transmuted on the same grid has a partition of exactly that name, and
-- the next pg_cron run detached it: its rows vanished from every read of the parent, with nothing logged.
-- The runbook's own remedy ("drop the table and run pgpm.forget_missing()") reaches it.
--
-- THE CONTRACT.
--   PART A  forgetting a dropped table whose retirement armed the job returns the job to idle (`select 1`),
--           so a later namesake's same-named partition stays attached and every one of its rows stays
--           visible through the parent after pg_cron's next run of the job.
--   PART B  a command that is not a detach of the forgotten retirement's partition (another table's, armed
--           after the drop) is left alone.
--   PART C  the disarm is CONDITIONAL on no live retirement owning the command (the #407 rule): when the
--           re-created namesake has armed its OWN retirement of the same-named partition before the
--           operator runs forget_missing(), the job holds a command of IDENTICAL TEXT that belongs to a
--           live retirement, and forget_missing() leaves it armed.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job, as tests/194, 204 and 229 do. Part A simulates pg_cron's run of the job by
-- executing the job's command at the top level with \gexec, which is what pg_cron does with it.
--
-- ASYMMETRIC FIXTURES. Each part's tables hold different ids (A's namesake 1, 2, 12, 17; B's forgotten table 8;
-- C's namesake 4, 14, 16), so an assertion aimed at the wrong table cannot pass.
create extension if not exists pgtap;
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

-- ==================== (A) forgotten while armed, then a namesake on the same grid ====================
create table public.fa246 (id bigint primary key, payload text);
insert into public.fa246 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.fa246', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.fa246 values (15, 'old'), (55, 'frontier');
create table public.fa246_ref (id bigint primary key, fa_id bigint references public.fa246 (id));
insert into public.fa246_ref values (100, 55);
select child_name as a_doomed from pgpm.part where parent_table = 'public.fa246'::regclass and lo = '10' \gset

select is(pgpm.retire('public.fa246', :'a_doomed'), false, 'LIVENESS: A''s retire() takes the referenced path');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.fa246 detach partition public.%I concurrently', :'a_doomed'),
  'LIVENESS: and armed pgpm_detach with the doomed cell''s detach');

-- dropped without untransmute (before pg_cron reached the detach), then forgotten
select (select oid from pg_class where oid = 'public.fa246'::regclass) as a_oid \gset
drop table public.fa246 cascade;
select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:a_oid]::oid[],
  'LIVENESS: forget_missing() forgot exactly A''s dropped table');
select ok(not exists (select 1 from pgpm.part where parent_table = :a_oid::regclass),
  'LIVENESS: and its retiring partition row with it');
select is((select command from cron.job where jobname = 'pgpm_detach'), 'select 1',
  'forget_missing() returned pgpm_detach to idle when it forgot the retirement that armed it');

-- later: a table re-created under the same name, converted on the same grid
create table public.fa246 (id bigint primary key, payload text);
insert into public.fa246 values (1, 'new-a'), (2, 'new-b');
call pgpm.transmute('public.fa246', 'id', 10::bigint, p_obtain => 6, p_paused => true);
insert into public.fa246 values (12, 'new-12'), (17, 'new-17');
select is((select array_agg(id order by id) from public.fa246), array[1, 2, 12, 17]::bigint[],
  'LIVENESS: the namesake holds 1, 2, 12, 17');
select ok(exists (select 1 from pg_inherits i where i.inhparent = 'public.fa246'::regclass
                    and i.inhrelid = to_regclass(format('public.%I', :'a_doomed'))),
  'LIVENESS: and a partition of the forgotten cell''s name is attached to it');

-- pg_cron's next run of pgpm_detach
select command from cron.job where jobname = 'pgpm_detach' \gexec

select is((select array_agg(id order by id) from public.fa246), array[1, 2, 12, 17]::bigint[],
  'after pg_cron''s next run the namesake still shows every row it holds: 1, 2, 12, 17');
select ok(exists (select 1 from pg_inherits i where i.inhparent = 'public.fa246'::regclass
                    and i.inhrelid = to_regclass(format('public.%I', :'a_doomed'))),
  'and its partition of the forgotten cell''s name is still attached');

-- ==================== (B) another table's command is left alone ====================
create table public.fb246 (id bigint primary key, payload text);
insert into public.fb246 values (8, 'h');
call pgpm.transmute('public.fb246', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.fb246 values (58, 'frontier');
create table public.fb246_ref (id bigint primary key, fb_id bigint references public.fb246 (id));
insert into public.fb246_ref values (300, 58);
select child_name as b_doomed from pgpm.part where parent_table = 'public.fb246'::regclass and lo = '0' \gset
select is(pgpm.retire('public.fb246', :'b_doomed'), false, 'LIVENESS: B''s retire() takes the referenced path');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.fb246 detach partition public.%I concurrently', :'b_doomed'),
  'LIVENESS: and armed pgpm_detach with B''s detach');
select (select oid from pg_class where oid = 'public.fb246'::regclass) as b_oid \gset
drop table public.fb246 cascade;
-- another retirement's dispatch now holds the job
update cron.job set command = 'alter table public.elsewhere246 detach partition public.elsewhere246_p1 concurrently'
 where jobname = 'pgpm_detach';

select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:b_oid]::oid[],
  'LIVENESS: forget_missing() forgot exactly B''s dropped table');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  'alter table public.elsewhere246 detach partition public.elsewhere246_p1 concurrently',
  'forget_missing() left another table''s armed command in place');

-- ==================== (C) identical text, owned by the namesake's live retirement ====================
create table public.fc246 (id bigint primary key, payload text);
insert into public.fc246 values (5, 'e'), (6, 'f');
call pgpm.transmute('public.fc246', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.fc246 values (15, 'old'), (56, 'frontier');
create table public.fc246_ref (id bigint primary key, fc_id bigint references public.fc246 (id));
insert into public.fc246_ref values (200, 56);
select child_name as c_doomed from pgpm.part where parent_table = 'public.fc246'::regclass and lo = '10' \gset
select is(pgpm.retire('public.fc246', :'c_doomed'), false, 'LIVENESS: C''s first incarnation armed its retirement');
select (select oid from pg_class where oid = 'public.fc246'::regclass) as c_oid \gset
drop table public.fc246 cascade;

-- the namesake, re-created and retiring the same-named cell BEFORE the operator runs forget_missing()
create table public.fc246 (id bigint primary key, payload text);
insert into public.fc246 values (4, 'new-d');
call pgpm.transmute('public.fc246', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.fc246 values (14, 'new-14'), (16, 'new-16'), (57, 'frontier');
create table public.fc246_ref2 (id bigint primary key, fc_id bigint references public.fc246 (id));
insert into public.fc246_ref2 values (201, 57);
select is(pgpm.retire('public.fc246', :'c_doomed'), false, 'LIVENESS: the namesake''s retire() takes the referenced path');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'public.fc246'::regclass and lo = '10'
            and action in ('retain_detach', 'fail_retain_detach', 'retain_drop', 'fail_retain_identity')),
  array['retain_detach'], 'LIVENESS: and dispatched its own detach (retain_detach, logged against the namesake)');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.fc246 detach partition public.%I concurrently', :'c_doomed'),
  'LIVENESS: and armed pgpm_detach with a command of the same text the forgotten retirement armed');
select ok(exists (select 1 from pgpm.part where parent_table = :c_oid::regclass and child_name = :'c_doomed'
                    and retiring_at is not null),
  'LIVENESS: the dropped incarnation''s retiring row of that name is still there to forget');

select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:c_oid]::oid[],
  'LIVENESS: forget_missing() forgot exactly C''s dropped incarnation');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.fc246 detach partition public.%I concurrently', :'c_doomed'),
  'forget_missing() left armed the command a live retirement owns, though its text matches the forgotten one');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.fc246'::regclass and child_name = :'c_doomed'
                    and retiring_at is not null),
  'and the namesake''s retirement is still under way');

select * from finish();
