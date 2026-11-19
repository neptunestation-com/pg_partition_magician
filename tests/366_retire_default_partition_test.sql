-- retire() refuses a referenced partition's concurrent detach while the parent has a DEFAULT partition, counted, and
-- the retirement holds no detach slot while it stands (issue #1453).
--
-- THE GAP. A referenced partition retires by DETACH ... CONCURRENTLY through the pgpm_detach job, one retirement at a
-- time database-wide. PostgreSQL refuses every concurrent detach of a parent with a DEFAULT partition. pgpm builds
-- none, but nothing refuses one an operator attaches, and retire() re-dispatched the detach on every tick, logging
-- retain_detach (a success action), counting nothing in status(), while the mark held the one detach slot: no other
-- table's referenced retirement was ever dispatched. With the DEFAULT there first, retire() also ran the crossing
-- DELETE, firing the operator's ON DELETE actions, for a detach that could not follow.
--
-- THE CONTRACT. Retention REACHES every range below (a liveness witness says so), so the recall never runs and every
-- effect is retire()'s own.
--   PART A  the DEFAULT is there before the first dispatch: retire() refuses before the crossing DELETE, so the
--           referencing row and the referenced key both survive, no mark is set and the job stays idle. It runs
--           first, while no retirement anywhere holds the slot, so the slot cannot be what stops the crossing.
--   PART B  (the issue's reproduction) the DEFAULT is attached after the dispatch: the refused detach is logged
--           fail_retain_detach naming the DEFAULT, counted in status(), never re-dispatched, its mark kept; and
--           another table's reached retirement gets the detach slot.
--   PART C  the way out the message spells works: with the DEFAULT detached, the next tick dispatches the detach
--           again, it lands and the partition is dropped, and the other table's retirement then completes.
--   PART D  a retirement whose detach is already PENDING when a DEFAULT arrives keeps the slot (FINALIZE completes
--           it whatever partitions the parent has): another table's retirement waits, and the first one completes.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for cron.job
-- and cron.alter_job and runs whatever the standing job holds at the top level, over dblink, as tests/194 does.
--
-- Every table keeps a frontier row at 50,000-odd and retains 35,000 back, so retention reaches [0, 10000) and nothing
-- above it: each table has exactly one retirement in play.
--
-- ASYMMETRIC FIXTURES. The doomed partitions hold different ids (vp4 1, 2, 3; vq4 11, 12; vr4 21, 22, 23, 24; vs4 31, 32;
-- vt4 41, 42, 43), so a
-- drop of the wrong relation or a lost row cannot stand in for the right answer.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

select plan(42);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

create schema pgpm_t366;
create function pgpm_t366.run() returns text language sql as $$
  select case when command = 'select 1' then 'idle'   -- the idle job's command returns a row, which dblink_exec refuses
              else dblink_exec(format('dbname=%s user=postgres', current_database()), command, false) end
    from cron.job where jobname = 'pgpm_detach'
$$;
create function pgpm_t366.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
$$;
create function pgpm_t366.ids(p_rel regclass, p_below bigint) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  execute format('select array_agg(id order by id) from %s where id < %s', p_rel, p_below) into v;
  return v;
end;
$$;
create function pgpm_t366.acts(p_parent regclass, p_lo text) returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log
   where parent_table = p_parent and lo = p_lo and action ~ '^(retain_|fail_retain_|skip_retain)'
$$;
create function pgpm_t366.attached(p_oid oid) returns boolean language sql as $$
  select exists (select 1 from pg_inherits where inhrelid = p_oid and not inhdetachpending)
$$;

-- two parents whose doomed partition an incoming foreign key makes retire by a concurrent detach
create table public.vp4 (id bigint primary key, payload text);
insert into public.vp4 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.vp4', 'id', 10000::bigint, p_retain => 35000, p_paused => false);
select pgpm.extend_to('public.vp4', '60000');
insert into public.vp4 values (50005, 'frontier');
create table public.vp4_ref (id bigint primary key, p_id bigint references public.vp4(id));
insert into public.vp4_ref values (1, 50005);
select child_name as doomed, child_oid as doomed_oid from pgpm.part where parent_table = 'public.vp4'::regclass and lo = '0' \gset

create table public.vq4 (id bigint primary key, payload text);
insert into public.vq4 values (11, 'p'), (12, 'q');
call pgpm.transmute('public.vq4', 'id', 10000::bigint, p_retain => 35000, p_paused => false);
select pgpm.extend_to('public.vq4', '60000');
insert into public.vq4 values (50007, 'frontier');
create table public.vq4_ref (id bigint primary key, p_id bigint references public.vq4(id));
insert into public.vq4_ref values (1, 50007);
select child_name as q_doomed, child_oid as q_doomed_oid from pgpm.part where parent_table = 'public.vq4'::regclass and lo = '0' \gset

select ok(pgpm._retain_boundary(c) is not null and '0' < pgpm._retain_boundary(c), 'LIVENESS: retention reaches vp4''s range')
  from pgpm.config c where c.parent_table = 'public.vp4'::regclass;

-- ====== PART A: the DEFAULT is there before the first dispatch, and a row crosses ======
create table public.vr4 (id bigint primary key, payload text);
insert into public.vr4 values (21, 'w'), (22, 'x'), (23, 'y'), (24, 'z');
call pgpm.transmute('public.vr4', 'id', 10000::bigint, p_retain => 35000, p_paused => false);
select pgpm.extend_to('public.vr4', '60000');
insert into public.vr4 values (50009, 'frontier');
create table public.vr4_ref (id bigint primary key, p_id bigint references public.vr4(id) on delete cascade);
insert into public.vr4_ref values (1, 22), (2, 50009);
create table public.vr4_default partition of public.vr4 default;
select child_name as r_doomed, child_oid as r_doomed_oid from pgpm.part where parent_table = 'public.vr4'::regclass and lo = '0' \gset
select is(pgpm._crossing_keys('public.vr4', '0', '10000'), array['22'], 'A: LIVENESS: a referencing row crosses into the doomed range');
select ok(pgpm_t366.armed() = 'select 1' and not exists (select 1 from pgpm.part where retiring_at is not null),
  'A: LIVENESS: no retirement is in flight anywhere, so nothing but the DEFAULT can stop the crossing and the dispatch');

select ok(not pgpm.retire('public.vr4', :'r_doomed'), 'A: retire() does not retire it');
select is(pgpm_t366.acts('public.vr4', '0'), array['fail_retain_detach'], 'A: logged fail_retain_detach once, no crossing and no dispatch');
select ok((select method from pgpm.log where parent_table = 'public.vr4'::regclass and lo = '0' and action = 'fail_retain_detach') ~ 'vr4_default',
  'A: the failure names the DEFAULT partition');
select is((select array_agg(id order by id) from public.vr4_ref), array[1, 2]::bigint[], 'A: the referencing row survives (no crossing DELETE ran)');
select is(pgpm_t366.ids('public.vr4', 10000), array[21, 22, 23, 24]::bigint[], 'A: the doomed partition keeps every row, the referenced key included');
select ok((select retiring_at is null from pgpm.part where parent_table = 'public.vr4'::regclass and lo = '0'), 'A: no mark is set');
select is(pgpm_t366.armed(), 'select 1', 'A: the job stays idle');
select ok((select retain_drop_failures from pgpm.status() where parent = 'public.vr4'::regclass) = 1, 'A: status() counts it');

-- ====== PART B: the DEFAULT arrives after the dispatch ======
select ok(not pgpm.retire('public.vp4', :'doomed'), 'B: fixture: retire() dispatches vp4''s concurrent detach');
select is(pgpm_t366.armed() ~ 'detach partition' and pgpm_t366.armed() ~ :'doomed', true, 'B: LIVENESS: the job holds vp4''s detach');
create table public.vp4_default partition of public.vp4 default;
select is(pgpm_t366.run(), 'ERROR', 'B: LIVENESS: pg_cron''s run of the detach is refused (a DEFAULT partition exists)');
select ok(pgpm_t366.attached(:doomed_oid), 'B: LIVENESS: and the partition stays attached');
select is(coalesce(array_length(pgpm._crossing_keys('public.vp4', '0', '10000'), 1), 0), 0,
  'B: LIVENESS: no foreign key references the partition''s rows (the refusal is not a crossing)');

call pgpm.maintain('public.vp4');
call pgpm.maintain('public.vp4');
call pgpm.maintain('public.vq4');

select is(pgpm_t366.acts('public.vp4', '0'), array['retain_detach', 'fail_retain_detach', 'fail_retain_detach'],
  'B: vp4: dispatched once, then each tick logs fail_retain_detach and dispatches nothing more');
select ok((select method from pgpm.log where parent_table = 'public.vp4'::regclass and lo = '0' and action = 'fail_retain_detach'
            order by id desc limit 1) ~ 'vp4_default',
  'B: the failure names the DEFAULT partition');
select is((select retain_drop_failures from pgpm.status() where parent = 'public.vp4'::regclass), 2::bigint,
  'B: status() counts both refusals');
select ok((select retiring_at is not null and retiring_oid = :doomed_oid from pgpm.part
            where parent_table = 'public.vp4'::regclass and lo = '0'),
  'B: vp4''s mark is kept, on the partition it was made for');
select ok(pgpm_t366.attached(:doomed_oid) and pgpm_t366.ids('public.vp4', 10000) = array[1, 2, 3]::bigint[],
  'B: vp4''s partition is attached with its rows');
select is(pgpm_t366.acts('public.vq4', '0'), array['retain_detach'], 'B: vq4''s reached retirement gets the detach slot');
select ok(pgpm_t366.armed() ~ :'q_doomed' and pgpm_t366.armed() !~ :'doomed', 'B: and the job now holds vq4''s detach');

-- ====== PART C: the way out ======
-- a tick on vq4 re-dispatches its detach, so both tables' retirements are in play
call pgpm.maintain('public.vq4');
select is(pgpm_t366.armed() ~ :'q_doomed', true, 'C: LIVENESS: vq4''s detach is armed again');
alter table public.vp4 detach partition public.vp4_default;   -- the way out the message spells
call pgpm.maintain('public.vp4');
select ok(pgpm_t366.armed() ~ :'doomed', 'C: with the DEFAULT gone, vp4''s older retirement takes the slot back and dispatches');
select is(pgpm_t366.run(), 'ALTER TABLE', 'C: LIVENESS: and the detach lands');
call pgpm.maintain('public.vp4');
select ok(not exists (select 1 from pg_class where oid = :doomed_oid)
          and not exists (select 1 from pgpm.part where parent_table = 'public.vp4'::regclass and lo = '0'),
  'C: vp4''s partition is dropped and forgotten');
select is(pgpm_t366.ids('public.vp4', 100000), array[50005]::bigint[], 'C: vp4 keeps exactly its frontier row');
call pgpm.maintain('public.vq4');
select ok(pgpm_t366.armed() ~ :'q_doomed', 'C: vq4''s retirement is dispatched again once vp4''s is done');
select is(pgpm_t366.run(), 'ALTER TABLE', 'C: LIVENESS: and its detach lands');
call pgpm.maintain('public.vq4');
select ok(not exists (select 1 from pg_class where oid = :q_doomed_oid)
          and pgpm_t366.ids('public.vq4', 100000) = array[50007]::bigint[],
  'C: vq4''s partition is dropped, its frontier row kept');

-- ====== PART D: a pending detach keeps the slot under a DEFAULT ======
create table public.vs4 (id bigint primary key, payload text);
insert into public.vs4 values (31, 'm'), (32, 'n');
call pgpm.transmute('public.vs4', 'id', 10000::bigint, p_retain => 35000, p_paused => false);
select pgpm.extend_to('public.vs4', '60000');
insert into public.vs4 values (50011, 'frontier');
create table public.vs4_ref (id bigint primary key, p_id bigint references public.vs4(id));
insert into public.vs4_ref values (1, 50011);
select child_name as s_doomed, child_oid as s_doomed_oid from pgpm.part where parent_table = 'public.vs4'::regclass and lo = '0' \gset
create table public.vt4 (id bigint primary key, payload text);
insert into public.vt4 values (41, 'r'), (42, 's'), (43, 't');
call pgpm.transmute('public.vt4', 'id', 10000::bigint, p_retain => 35000, p_paused => false);
select pgpm.extend_to('public.vt4', '60000');
insert into public.vt4 values (50013, 'frontier');
create table public.vt4_ref (id bigint primary key, p_id bigint references public.vt4(id));
insert into public.vt4_ref values (1, 50013);
select child_name as t_doomed from pgpm.part where parent_table = 'public.vt4'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.vs4', :'s_doomed') and pgpm_t366.armed() ~ :'s_doomed', 'D: fixture: vs4''s detach is dispatched');
-- pg_cron's run interrupted in its second phase: a reader of the partition holds it, and the run's statement times out
select dblink_connect('t366_blk', format('dbname=%s user=postgres', current_database()));
select dblink_exec('t366_blk', 'begin');
select n from dblink('t366_blk', format('select count(*) from public.%I', :'s_doomed')) as t(n bigint);
select dblink_exec(format('dbname=%s user=postgres options=-cstatement_timeout=1500', current_database()),
                   pgpm_t366.armed(), false) as interrupted;
select dblink_exec('t366_blk', 'commit');
select dblink_disconnect('t366_blk');
select ok(exists (select 1 from pg_inherits where inhrelid = :s_doomed_oid and inhdetachpending), 'D: LIVENESS: vs4''s detach is pending');
create table public.vs4_default partition of public.vs4 default;
select ok(exists (select 1 from pg_partitioned_table where partrelid = 'public.vs4'::regclass and partdefid <> 0), 'D: LIVENESS: vs4 has a DEFAULT partition');
update cron.job set command = 'select 1';   -- a tick's idle could free the job; the slot must hold regardless

select ok(not pgpm.retire('public.vt4', :'t_doomed'), 'D: vt4''s retirement is not done');
select is(pgpm_t366.acts('public.vt4', '0'), '{}'::text[], 'D: vt4 yields to the pending retirement: nothing dispatched, nothing logged');
select is(pgpm_t366.armed(), 'select 1', 'D: and the job is left alone');
select is(pgpm_t366.acts('public.vs4', '0'), array['retain_detach'], 'D: retire() does not refuse the pending detach of vs4');
call pgpm.maintain('public.vs4');
select ok(pgpm_t366.acts('public.vs4', '0') <> '{}' and not ('fail_retain_detach' = any (pgpm_t366.acts('public.vs4', '0'))),
  'D: a tick on the pending detach logs no refusal');
select ok(pgpm._detach_reap() >= 1, 'D: LIVENESS: the reaper (maintain_all runs it) finalizes the abandoned detach, DEFAULT and all');
call pgpm.maintain('public.vs4');
select ok(not exists (select 1 from pg_class where oid = :s_doomed_oid)
          and not exists (select 1 from pgpm.part where parent_table = 'public.vs4'::regclass and lo = '0'),
  'D: the pending detach completes under the DEFAULT, and the partition is dropped and forgotten');
select is(pgpm_t366.ids('public.vs4', 100000), array[50011]::bigint[], 'D: vs4 keeps exactly its frontier row');

select * from finish();
