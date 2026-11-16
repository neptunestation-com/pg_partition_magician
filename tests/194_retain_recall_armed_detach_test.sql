-- Loosening retention never strands a partition with nothing in pgpm saying so (issues #724, #1438).
--
-- THE BUG (#724). Retiring a REFERENCED partition is two-step: retire() marks it (pgpm.part.retiring_at) and
-- points the standing pgpm_detach cron job at its concurrent detach, and a later call DROPs it. When retention
-- was loosened in between (set_retain to a longer value, or an id table's frontier moving back because its newest
-- rows were deleted), nothing looked at the armed command again. Cron detached the partition, retire() was never
-- called on it again (retain() walks only what the horizon reaches), and its rows vanished from every read of the
-- parent with pgpm.part still saying attached and status() counting no failure.
--
-- THE BUG (#1438). #724's fix took the dispatch back: it idled the job and, for a partition the detach had already
-- taken out, re-attached it. But pg_cron reads a job's command from a cache only a commit refreshes, so a run that
-- started while the recall was uncommitted still carried the detach, and took the partition out again once the
-- recall committed, the mark by then cleared: the same stranded rows, the log ending at retain_reattach.
--
-- THE CONTRACT. A dispatched detach is never taken back; it lands, and the table is released to the operator.
--   PART A: set_retain after the dispatch leaves the job armed. Once the detach lands, the tick idles the job and
--           releases the table with its rows: the mark cleared, retain_disown logged with the ATTACH that puts it
--           back and the warning not to drop it, fail_retain_reattach logged and counted in
--           status().retain_drop_failures. The remedy's ATTACH, run as written, serves the rows again, and the
--           idle job leaves it attached.
--   PART B: #1438's race, no operator. A run carrying the detach that lands AFTER the tick finds nothing to take
--           out: pgpm re-attached nothing, so the late run cannot strand rows behind a cleared mark.
--   PART C: the frontier moving back, with no set_retain at all, is settled by the tick the same way.
--   PART D: one-directional. A loosening that still reaches the partition changes nothing: the retirement
--           completes with a DROP.
--   PART E: a mark whose job no longer holds its detach (idled or unscheduled under it) is cleared by the tick,
--           and the partition never leaves the parent: the one state a loosening still saves it from.
--   PART F: a run pg_cron had already started when retention loosened, landing after the tick that saw the
--           loosening, is still recorded: the tick after it releases the table and counts it.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in
-- for the two things pgpm touches (cron.job and cron.alter_job), and runs whatever the standing job holds
-- at the top level, exactly as pg_cron's worker would (tests/77 and the issue's reproduction do the same).
--
-- THE INVARIANT parts B and F assert after each late run: every row of the range is served by the parent, or pgpm
-- has logged the partition out of it (fail_retain_reattach). Rows out with neither is the defect, whichever path
-- led there.
--
-- ASYMMETRIC FIXTURES. Every part's doomed partition holds a different set of ids, so a re-attach of the
-- wrong relation, a lost row or a resurrected one cannot stand in for the right answer.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

select plan(54);

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
-- a pg_cron run: the command in a session of its own, top level as pg_cron sends it; its error (a late run of a
-- detach that has nothing left to take out) comes back as text rather than ending this file
create function pgpm_test194.cron_run(p_cmd text) returns text language sql as $$
  select case when p_cmd = 'select 1' then 'idle'   -- the idle job's command returns a row, which dblink_exec refuses
              else dblink_exec(format('dbname=%s user=postgres', current_database()), p_cmd, false) end
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
     and action in ('retain_detach', 'retain_recall', 'retain_reattach', 'fail_retain_reattach', 'retain_disown',
                    'retain_drop', 'fail_retain_drop', 'fail_retain_identity')
$$;
-- the invariant: the range's rows are served by the parent, or pgpm logged the partition out of it
create function pgpm_test194.accounted(p_parent regclass, p_child name, p_lo text) returns boolean language sql as $$
  select pgpm_test194.attached(p_parent, p_child)
      or exists (select 1 from pgpm.log where parent_table = p_parent and lo = p_lo and action = 'fail_retain_reattach')
$$;
create function pgpm_test194.mark(p_parent regclass, p_lo text) returns text language sql as $$
  select format('retiring_at %s, dispatched %s', case when retiring_at is null then 'null' else 'set' end,
                coalesce(detach_dispatched_oid::text, 'null'))
    from pgpm.part where parent_table = p_parent and lo = p_lo
$$;

-- ============ PART A: set_retain after the dispatch; the detach lands and the table is released ============
-- monolith [0, 10000) holds 1, 2, 3; the frontier at 50005 puts the retain 25000 horizon at 20000. The
-- referencing row points at the live frontier row, so there is no crossing and nothing stops the detach.
create table public.rr194a (id bigint primary key, payload text);
insert into public.rr194a values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.rr194a', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194a', '60000');
insert into public.rr194a values (50005, 'frontier');
create table public.rr194a_ref (id bigint primary key, p_id bigint references public.rr194a(id));
insert into public.rr194a_ref values (1, 50005);
select child_name as a_doomed, hi as a_hi, child_oid as a_oid from pgpm.part
 where parent_table = 'public.rr194a'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194a', :'a_doomed'), 'fixture: (A) retire() dispatches the detach and returns false');
select pgpm_test194.armed() as a_cmd \gset
select is(:'a_cmd', format('alter table public.rr194a detach partition public.%I concurrently', :'a_doomed'),
  'LIVENESS: (A) the standing job is armed with this partition''s concurrent detach');

select pgpm.set_retain('public.rr194a', '45000');   -- horizon 20000 -> 0
select ok(not pgpm_test194.reached('public.rr194a', :'a_hi'), 'LIVENESS: (A) after loosening, retention no longer reaches the partition');
select is(pgpm_test194.armed(), :'a_cmd', 'A: set_retain does not take the dispatched detach back: the job stays armed');
select is(pgpm_test194.actions('public.rr194a', '0'), array['retain_detach'], 'A: and logs nothing over the range');

-- pg_cron's next run: run whatever the standing job holds, at the top level
select command from cron.job where jobname = 'pgpm_detach' \gexec
select ok(not pgpm_test194.attached('public.rr194a', :'a_doomed'), 'LIVENESS: (A) the dispatched detach landed');
call pgpm.maintain('public.rr194a');

select is(pgpm_test194.ids(format('public.%I', :'a_doomed')), array[1, 2, 3]::bigint[],
  'A: the detached table stands with ids 1, 2, 3');
select is(to_regclass(format('public.%I', :'a_doomed'))::oid, :'a_oid'::oid, 'A: and it is the partition''s own relation, by oid');
select ok(not pgpm_test194.attached('public.rr194a', :'a_doomed'), 'A: pgpm does not re-attach it');
select is(pgpm_test194.actions('public.rr194a', '0'), array['retain_detach', 'retain_disown', 'fail_retain_reattach'],
  'A: the release is logged as exactly retain_disown, then fail_retain_reattach');
select is(pgpm_test194.mark('public.rr194a', '0'), 'retiring_at null, dispatched null', 'A: the retirement''s mark is cleared');
select is(pgpm_test194.armed(), 'select 1', 'A: the standing job is back to idle');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'public.rr194a'::regclass $$,
  $$ values (1::bigint, 0::bigint) $$, 'A: status() counts the release in retain_drop_failures, with nothing detaching');
select coalesce((select method from pgpm.log where parent_table = 'public.rr194a'::regclass and lo = '0' and action = 'retain_disown'), '') as a_method \gset
select ok(position(format('alter table public.rr194a attach partition public.%I for values from (''0'') to (''10000'');', :'a_doomed')
                   in :'a_method') > 0, 'A: the retain_disown row gives the ATTACH that puts it back, on its own bounds');
select ok(:'a_method' like '%Do not drop it%', 'A: and says not to drop it');
-- the operator follows the remedy as written
select substring(:'a_method' from 'alter table [^;]* attach partition [^;]*;') \gexec
select is(pgpm_test194.ids('public.rr194a', 20000), array[1, 2, 3]::bigint[], 'A: the remedy''s ATTACH serves ids 1, 2, 3 through the parent again');
select pgpm_test194.cron_run(pgpm_test194.armed());
call pgpm.maintain('public.rr194a');
select ok(pgpm_test194.attached('public.rr194a', :'a_doomed'), 'A: and a cron run and a tick after it leave it attached');
select lives_ok($$ insert into public.rr194a values (4, 'd') $$, 'A: a write into the range lands');

-- ====== PART B: #1438's race, no operator: a late run of the detach finds nothing pgpm put back ======
create table public.rr194b (id bigint primary key, payload text);
insert into public.rr194b values (5, 'e'), (6, 'f'), (7, 'g'), (8, 'h');
call pgpm.transmute('public.rr194b', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194b', '60000');
insert into public.rr194b values (50005, 'frontier');
create table public.rr194b_ref (id bigint primary key, p_id bigint references public.rr194b(id));
insert into public.rr194b_ref values (1, 50005);
select child_name as b_doomed, hi as b_hi, child_oid as b_oid from pgpm.part
 where parent_table = 'public.rr194b'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194b', :'b_doomed'), 'fixture: (B) retire() dispatches the detach');
select pgpm_test194.armed() as b_cmd \gset
-- pgpm's own run lands
select :'b_cmd' \gexec
select ok(not pgpm_test194.attached('public.rr194b', :'b_doomed'), 'LIVENESS: (B) pgpm''s own run detached the partition');
select pgpm.set_retain('public.rr194b', '45000');
select ok(not pgpm_test194.reached('public.rr194b', :'b_hi'), 'LIVENESS: (B) retention no longer reaches the partition');
select is(pgpm_test194.armed(), :'b_cmd', 'LIVENESS: (B) the job still holds the detach, so pg_cron''s next run carries it');
call pgpm.maintain('public.rr194b');
-- the run pg_cron started on that cadence, with the command it had already read, lands after the tick
select pgpm_test194.cron_run(:'b_cmd');
select ok(pgpm_test194.accounted('public.rr194b', :'b_doomed', '0'),
  'B: after the late run, the range''s rows are served by the parent or logged out of it');
select ok(not pgpm_test194.attached('public.rr194b', :'b_doomed'), 'B: pgpm re-attached nothing for the late run to take out');
select is(pgpm_test194.ids(format('public.%I', :'b_doomed')), array[5, 6, 7, 8]::bigint[], 'B: the released table keeps ids 5, 6, 7, 8');
select is(pgpm_test194.actions('public.rr194b', '0'), array['retain_detach', 'retain_disown', 'fail_retain_reattach'],
  'B: logged as exactly retain_detach, retain_disown, fail_retain_reattach');
select is(pgpm_test194.armed(), 'select 1', 'B: the standing job is back to idle');

-- ============== PART C: the frontier moves back with no set_retain; the tick settles it ==============
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
select pgpm_test194.armed() as c_cmd \gset
delete from public.rr194c where id = 50005;   -- the frontier moves back to 30005: horizon 20000 -> 0
select ok(not pgpm_test194.reached('public.rr194c', :'c_hi'), 'LIVENESS: (C) retention no longer reaches the partition');
select is((select retain from pgpm.config where parent_table = 'public.rr194c'::regclass), '25000',
  'LIVENESS: (C) retain itself was never changed, so set_retain cannot be what settles it');
call pgpm.maintain('public.rr194c');
select is(pgpm_test194.armed(), :'c_cmd', 'C: the tick leaves the dispatched detach armed');
select command from cron.job where jobname = 'pgpm_detach' \gexec
call pgpm.maintain('public.rr194c');
select is(pgpm_test194.ids(format('public.%I', :'c_doomed')), array[11, 12]::bigint[], 'C: the released table keeps ids 11, 12');
select is(pgpm_test194.actions('public.rr194c', '0'), array['retain_detach', 'retain_disown', 'fail_retain_reattach'],
  'C: logged as exactly retain_detach, retain_disown, fail_retain_reattach');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'public.rr194c'::regclass $$,
  $$ values (1::bigint, 0::bigint) $$, 'C: status() counts it, with nothing detaching');

-- ========= PART D: a loosening that still reaches the partition changes nothing (one-directional) =========
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
  'D: logged as exactly retain_detach, retain_drop, with no release');

-- ======= PART E: a mark whose job no longer holds its detach is cleared, and the partition stays =======
create table public.rr194e (id bigint primary key, payload text);
insert into public.rr194e values (31, 'x'), (32, 'y');
call pgpm.transmute('public.rr194e', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194e', '60000');
insert into public.rr194e values (50005, 'frontier');
create table public.rr194e_ref (id bigint primary key, p_id bigint references public.rr194e(id));
insert into public.rr194e_ref values (1, 50005);
select child_name as e_doomed, hi as e_hi from pgpm.part
 where parent_table = 'public.rr194e'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194e', :'e_doomed'), 'fixture: (E) retire() dispatches the detach');
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- the job idled under it (schedule() re-run)
select pgpm.set_retain('public.rr194e', '45000');
select ok(not pgpm_test194.reached('public.rr194e', :'e_hi'), 'LIVENESS: (E) retention no longer reaches the partition');
select is(pgpm_test194.mark('public.rr194e', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194e'::regclass and lo = '0')),
  'LIVENESS: (E) the mark and pgpm''s dispatch record are still there before the tick');
call pgpm.maintain('public.rr194e');
select is(pgpm_test194.mark('public.rr194e', '0'), 'retiring_at null, dispatched null', 'E: the tick clears the mark nothing will detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
call pgpm.maintain('public.rr194e');
select ok(pgpm_test194.attached('public.rr194e', :'e_doomed'), 'E: the partition never left the parent');
select is(pgpm_test194.ids('public.rr194e', 20000), array[31, 32]::bigint[], 'E: ids 31, 32 are readable through the parent');
select is(pgpm_test194.actions('public.rr194e', '0'), array['retain_detach'], 'E: and nothing is logged over the range');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'public.rr194e'::regclass $$,
  $$ values (0::bigint, 0::bigint) $$, 'E: status() reports nothing failed and nothing detaching');

-- ====== PART F: a run already started when retention loosened lands after the tick, and is recorded ======
create table public.rr194f (id bigint primary key, payload text);
insert into public.rr194f values (41, 'p'), (42, 'q'), (43, 'r'), (44, 's'), (45, 't');
call pgpm.transmute('public.rr194f', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194f', '60000');
insert into public.rr194f values (50005, 'frontier');
create table public.rr194f_ref (id bigint primary key, p_id bigint references public.rr194f(id));
insert into public.rr194f_ref values (1, 50005);
select child_name as f_doomed, hi as f_hi from pgpm.part
 where parent_table = 'public.rr194f'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194f', :'f_doomed'), 'fixture: (F) retire() dispatches the detach');
-- pg_cron starts a run: its command is read now
select pgpm_test194.armed() as f_cmd \gset
select pgpm.set_retain('public.rr194f', '45000');
call pgpm.maintain('public.rr194f');
select ok(pgpm_test194.attached('public.rr194f', :'f_doomed'), 'LIVENESS: (F) the partition is still attached after the tick that saw the loosening');
-- the run lands
select :'f_cmd' \gexec
select ok(not pgpm_test194.attached('public.rr194f', :'f_doomed'), 'LIVENESS: (F) the late run took it out of the parent');
call pgpm.maintain('public.rr194f');
select ok(pgpm_test194.accounted('public.rr194f', :'f_doomed', '0'),
  'F: the range''s rows are served by the parent or logged out of it');
select is(pgpm_test194.ids(format('public.%I', :'f_doomed')), array[41, 42, 43, 44, 45]::bigint[], 'F: the released table keeps ids 41 to 45');
select results_eq($$ select retain_drop_failures from pgpm.status() where parent = 'public.rr194f'::regclass $$,
  $$ values (1::bigint) $$, 'F: and status() counts it');

select * from finish();
