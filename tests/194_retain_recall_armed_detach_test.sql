-- Loosening retention recalls a dispatched detach, and a detach that lands anyway is re-attached
-- (issue #724).
--
-- THE BUG. Retiring a REFERENCED partition is two-step: retire() marks it (pgpm.part.retiring_at) and
-- points the standing pgpm_detach cron job at its concurrent detach, and a later call DROPs it. When
-- retention was loosened in between (set_retain to a longer value, or an id table's frontier moving back
-- because its newest rows were deleted), nothing recalled the armed command. Cron detached the partition,
-- retire() was never called on it again (retain() walks only what the horizon reaches), and nothing put it
-- back: its rows vanished from every read of the parent, writes into its range were refused (23514),
-- pgpm.part still said attached, and status() showed no failure. docs/reference.md's set_retain says a
-- wider horizon only ever keeps a superset of what the narrower one kept.
--
-- THE CONTRACT.
--   PART A: set_retain recalls the armed detach of a partition the new value no longer reaches, at once
--           (the job is back to `select 1` before cron can run it), logs retain_recall, and the next tick
--           clears the marker. The partition never leaves the parent and its range stays writable.
--   PART B: a detach pg_cron had ALREADY picked up when the recall landed still runs. The tick finds the
--           marked partition detached, retention no longer reaching it, and re-attaches it (the same
--           relation, on its own bounds, without the CHECK the concurrent detach left behind, with the
--           incoming foreign key enforced on it again), logged retain_reattach.
--   PART C: the frontier moving back, with no set_retain at all, is recalled by the tick itself.
--   PART D: one-directional. A loosening that still reaches the partition recalls nothing: the job stays
--           armed with its detach and the retirement completes with a DROP.
--   PART E: a re-attach that cannot succeed is refused loudly: fail_retain_reattach, counted in
--           status().retain_drop_failures, and the detached table and its rows are left whole.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in
-- for the two things pgpm touches (cron.job and cron.alter_job), and runs whatever the standing job holds
-- at the top level, exactly as pg_cron's worker would (tests/77 and the issue's reproduction do the same).
--
-- ASYMMETRIC FIXTURES. Every part's doomed partition holds a different set of ids, so a re-attach of the
-- wrong relation, a lost row or a resurrected one cannot stand in for the right answer.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(51);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

create schema pgpm_test194;
-- the ids a relation holds, null when it does not exist (a results_eq over a missing table would raise
-- and take the rest of the file with it, which would hide the assertion count the guard checks)
create function pgpm_test194.ids(p_rel text, p_below bigint default null) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg(id order by id) from %s where id < %s', p_rel, coalesce(p_below, 9223372036854775807)) into v;
  return v;
end;
$$;
create function pgpm_test194.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
$$;
create function pgpm_test194.attached(p_parent regclass, p_child name) returns boolean language sql as $$
  select exists (select 1 from pg_inherits
                  where inhparent = p_parent and inhrelid = to_regclass(format('public.%I', p_child))
                    and not inhdetachpending)
$$;
create function pgpm_test194.reached(p_parent regclass, p_hi text) returns boolean language sql as $$
  select not pgpm._native_gt(c.control_kind, p_hi, pgpm._retain_boundary(c))
    from pgpm.config c where c.parent_table = p_parent
$$;
create function pgpm_test194.actions(p_parent regclass, p_lo text) returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log
   where parent_table = p_parent and lo = p_lo
     and action in ('retain_detach', 'retain_recall', 'retain_reattach', 'fail_retain_reattach',
                    'retain_drop', 'fail_retain_drop', 'fail_retain_identity')
$$;

-- ================= PART A: set_retain recalls the armed detach (the issue's reproduction) =================
-- monolith [0, 10000) holds 1, 2, 3; the frontier at 50005 puts the retain 25000 horizon at 20000. The
-- referencing row points at the live frontier row, so there is no crossing and nothing stops the detach.
create table public.rr194a (id bigint primary key, payload text);
insert into public.rr194a values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.rr194a', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194a', '60000');
insert into public.rr194a values (50005, 'frontier');
create table public.rr194a_ref (id bigint primary key, p_id bigint references public.rr194a(id));
insert into public.rr194a_ref values (1, 50005);
select child_name as a_doomed, hi as a_hi from pgpm.part
 where parent_table = 'public.rr194a'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194a', :'a_doomed'), 'fixture: (A) retire() dispatches the detach and returns false');
select is(pgpm_test194.armed(), format('alter table public.rr194a detach partition public.%I concurrently', :'a_doomed'),
  'LIVENESS: (A) the standing job is armed with this partition''s concurrent detach');
select isnt((select retiring_at from pgpm.part where parent_table = 'public.rr194a'::regclass and child_name = :'a_doomed'),
  null, 'LIVENESS: (A) the partition is marked retiring');

select pgpm.set_retain('public.rr194a', '45000');   -- horizon 20000 -> 0
select ok(not pgpm_test194.reached('public.rr194a', :'a_hi'), 'LIVENESS: (A) after loosening, retention no longer reaches the partition');
select is(pgpm_test194.armed(), 'select 1', 'A: set_retain returns the standing job to idle before cron can run the detach');
select is(pgpm_test194.actions('public.rr194a', '0'), array['retain_detach', 'retain_recall'],
  'A: the recall is logged as exactly retain_recall, once');

-- pg_cron's next tick: run whatever the standing job holds, at the top level
select command from cron.job where jobname = 'pgpm_detach' \gexec
call pgpm.maintain('public.rr194a');

select ok(pgpm_test194.attached('public.rr194a', :'a_doomed'), 'A: the kept partition is still attached to the parent');
select is(pgpm_test194.ids('public.rr194a', 20000), array[1, 2, 3]::bigint[],
  'A: ids 1, 2, 3 are still readable through the parent');
select is((select retiring_at from pgpm.part where parent_table = 'public.rr194a'::regclass and child_name = :'a_doomed'),
  null, 'A: the tick after the recall clears the retiring marker');
select lives_ok($$ insert into public.rr194a values (4, 'd') $$, 'A: a write into the kept range has a partition to land in');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'public.rr194a'::regclass $$,
  $$ values (0::bigint, 0::bigint) $$, 'A: status() reports nothing failed and nothing detaching');

-- ====== PART B: a detach cron already picked up lands AFTER the recall, and the tick re-attaches it ======
create table public.rr194b (id bigint primary key, payload text);
insert into public.rr194b values (5, 'e'), (6, 'f'), (7, 'g'), (8, 'h');
call pgpm.transmute('public.rr194b', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194b', '60000');
insert into public.rr194b values (50005, 'frontier');
create table public.rr194b_ref (id bigint primary key, p_id bigint references public.rr194b(id));
insert into public.rr194b_ref values (1, 50005);
select child_name as b_doomed, hi as b_hi, child_oid as b_oid from pgpm.part
 where parent_table = 'public.rr194b'::regclass and lo = '0' \gset
select array_agg(conname::text order by conname) as b_cons from pg_constraint where conrelid = :'b_oid'::oid \gset

select ok(not pgpm.retire('public.rr194b', :'b_doomed'), 'fixture: (B) retire() dispatches the detach');
-- pg_cron has already read the command: this is the text its worker is about to run
select pgpm_test194.armed() as b_cmd \gset
select is(:'b_cmd', format('alter table public.rr194b detach partition public.%I concurrently', :'b_doomed'),
  'LIVENESS: (B) the command cron picked up is this partition''s detach');
select pgpm.set_retain('public.rr194b', '45000');
select is(pgpm_test194.armed(), 'select 1', 'LIVENESS: (B) the recall reached the job');
select ok(not pgpm_test194.reached('public.rr194b', :'b_hi'), 'LIVENESS: (B) retention no longer reaches the partition');

-- the worker that started before the recall runs the detach anyway
select :'b_cmd' \gexec
select ok(not pgpm_test194.attached('public.rr194b', :'b_doomed'), 'LIVENESS: (B) the late detach landed: the partition left the parent');
select is(pgpm_test194.ids('public.rr194b', 20000), null::bigint[], 'LIVENESS: (B) its rows are invisible through the parent');

call pgpm.maintain('public.rr194b');

select ok(pgpm_test194.attached('public.rr194b', :'b_doomed'), 'B: the tick re-attached the partition');
select is((select inhrelid from pg_inherits where inhparent = 'public.rr194b'::regclass and inhrelid = :'b_oid'::oid),
  :'b_oid'::oid, 'B: the relation re-attached is the one that was detached, by oid');
select is(pgpm_test194.ids('public.rr194b', 20000), array[5, 6, 7, 8]::bigint[],
  'B: ids 5, 6, 7, 8 are readable through the parent again');
select is(pg_get_expr(c.relpartbound, c.oid), 'FOR VALUES FROM (''0'') TO (''10000'')', 'B: re-attached on its own bounds')
  from pg_class c where c.oid = :'b_oid'::oid;
select is((select array_agg(conname::text order by conname) from pg_constraint where conrelid = :'b_oid'::oid),
  :'b_cons'::text[], 'B: the CHECK the concurrent detach added is gone again; its constraints are what they were');
select is(pgpm_test194.actions('public.rr194b', '0'), array['retain_detach', 'retain_recall', 'retain_reattach'],
  'B: logged as exactly retain_detach, retain_recall, retain_reattach');
select is((select retiring_at from pgpm.part where parent_table = 'public.rr194b'::regclass and child_name = :'b_doomed'),
  null, 'B: the retiring marker is cleared with the re-attach');
select is(pgpm_test194.armed(), 'select 1', 'B: the standing job stays idle, so it does not detach the partition again');
select command from cron.job where jobname = 'pgpm_detach' \gexec
select ok(pgpm_test194.attached('public.rr194b', :'b_doomed'), 'B: and a further cron tick leaves it attached');
select lives_ok($$ insert into public.rr194b values (9, 'i') $$, 'B: a write into the range lands');
select lives_ok($$ insert into public.rr194b_ref values (2, 6) $$, 'LIVENESS: (B) a referencing row can point into the re-attached range');
select throws_ok($$ delete from public.rr194b where id = 6 $$, '23503', null,
  'B: and the incoming foreign key is enforced on the re-attached partition');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'public.rr194b'::regclass $$,
  $$ values (0::bigint, 0::bigint) $$, 'B: status() reports nothing failed and nothing detaching');

-- ============== PART C: the frontier moves back with no set_retain; the tick does the recall ==============
create table public.rr194c (id bigint primary key, payload text);
insert into public.rr194c values (11, 'k'), (12, 'l');
call pgpm.transmute('public.rr194c', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194c', '60000');
insert into public.rr194c values (30005, 'second'), (50005, 'frontier');
create table public.rr194c_ref (id bigint primary key, p_id bigint references public.rr194c(id));
insert into public.rr194c_ref values (1, 30005);
select child_name as c_doomed, hi as c_hi from pgpm.part
 where parent_table = 'public.rr194c'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194c', :'c_doomed'), 'fixture: (C) retire() dispatches the detach');
select is(pgpm_test194.armed(), format('alter table public.rr194c detach partition public.%I concurrently', :'c_doomed'),
  'LIVENESS: (C) the standing job is armed');
delete from public.rr194c where id = 50005;   -- the frontier moves back to 30005: horizon 20000 -> 0
select ok(not pgpm_test194.reached('public.rr194c', :'c_hi'), 'LIVENESS: (C) retention no longer reaches the partition');
select is((select retain from pgpm.config where parent_table = 'public.rr194c'::regclass), '25000',
  'LIVENESS: (C) retain itself was never changed, so set_retain cannot be what recalls it');

call pgpm.maintain('public.rr194c');
select is(pgpm_test194.armed(), 'select 1', 'C: the tick recalls the armed detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
call pgpm.maintain('public.rr194c');
select ok(pgpm_test194.attached('public.rr194c', :'c_doomed'), 'C: the partition is still attached');
select is(pgpm_test194.ids('public.rr194c', 20000), array[11, 12]::bigint[], 'C: ids 11, 12 are readable through the parent');
select is(pgpm_test194.actions('public.rr194c', '0'), array['retain_detach', 'retain_recall'],
  'C: logged as exactly retain_detach, retain_recall');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'public.rr194c'::regclass $$,
  $$ values (0::bigint, 0::bigint) $$, 'C: status() reports nothing failed, and the marker is gone after the second tick');

-- ========= PART D: a loosening that still reaches the partition recalls nothing (one-directional) =========
-- frontier 30005, retain 20000: horizon 10000, which reaches only the monolith [0, 10000)
create table public.rr194d (id bigint primary key, payload text);
insert into public.rr194d values (21, 'u'), (22, 'v'), (23, 'w');
call pgpm.transmute('public.rr194d', 'id', 10000::bigint, p_retain => 20000, p_paused => false);
select pgpm.extend_to('public.rr194d', '40000');
insert into public.rr194d values (30005, 'frontier');
create table public.rr194d_ref (id bigint primary key, p_id bigint references public.rr194d(id));
insert into public.rr194d_ref values (1, 30005);
select child_name as d_doomed, hi as d_hi, child_oid as d_oid from pgpm.part
 where parent_table = 'public.rr194d'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194d', :'d_doomed'), 'fixture: (D) retire() dispatches the detach');
select pgpm.set_retain('public.rr194d', '20004');   -- longer, but the horizon still floors to 10000
select is((select retain from pgpm.config where parent_table = 'public.rr194d'::regclass), '20004',
  'LIVENESS: (D) the loosening was accepted');
select ok(pgpm_test194.reached('public.rr194d', :'d_hi'), 'LIVENESS: (D) retention still reaches the partition');
select is(pgpm_test194.armed(), format('alter table public.rr194d detach partition public.%I concurrently', :'d_doomed'),
  'D: the job is still armed with this partition''s detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
call pgpm.maintain('public.rr194d');
select ok(not exists (select 1 from pg_class where oid = :'d_oid'::oid), 'D: the retirement completed: the partition is dropped');
select is(pgpm_test194.actions('public.rr194d', '0'), array['retain_detach', 'retain_drop'],
  'D: logged as exactly retain_detach, retain_drop, with no recall');

-- ============== PART E: a re-attach that cannot succeed is refused loudly, and drops nothing ==============
create table public.rr194e (id bigint primary key, payload text);
insert into public.rr194e values (31, 'x'), (32, 'y');
call pgpm.transmute('public.rr194e', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194e', '60000');
insert into public.rr194e values (50005, 'frontier');
create table public.rr194e_ref (id bigint primary key, p_id bigint references public.rr194e(id));
insert into public.rr194e_ref values (1, 50005);
select child_name as e_doomed, child_oid as e_oid from pgpm.part
 where parent_table = 'public.rr194e'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194e', :'e_doomed'), 'fixture: (E) retire() dispatches the detach');
select pgpm_test194.armed() as e_cmd \gset
select pgpm.set_retain('public.rr194e', '45000');
select :'e_cmd' \gexec
-- something else now holds the range in the parent, so the partition cannot go back
create table public.rr194e_squat partition of public.rr194e for values from (0) to (10000);
select ok(not pgpm_test194.attached('public.rr194e', :'e_doomed'), 'LIVENESS: (E) the late detach landed');

call pgpm.maintain('public.rr194e');
select is(pgpm_test194.actions('public.rr194e', '0'), array['retain_detach', 'retain_recall', 'fail_retain_reattach'],
  'E: the failed re-attach is logged as exactly fail_retain_reattach');
select is((select retain_drop_failures from pgpm.status() where parent = 'public.rr194e'::regclass), 1::bigint,
  'E: and status() counts it in retain_drop_failures');
select is(pgpm_test194.ids(format('public.%I', :'e_doomed')), array[31, 32]::bigint[],
  'E: the detached table and its rows are left whole');
select is(pgpm_test194.armed(), 'select 1', 'E: the standing job stays idle');

select * from finish();
