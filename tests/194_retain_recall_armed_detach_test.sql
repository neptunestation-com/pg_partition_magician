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
--   PART E: a mark whose job no longer holds its detach (idled or unscheduled under it) is cleared, and the
--           partition never leaves the parent: the one state a loosening still saves it from. Not at once (#1451):
--           pg_cron can still launch a detach its cache held after the idle, so the first tick that reads the job
--           idle stamps the mark, a later one starts the clock, and the mark is cleared only a minute on.
--   PART F: a run pg_cron had already started when retention loosened, landing after the tick that saw the
--           loosening, is still recorded: the tick after it releases the table and counts it.
--   PART G: a dispatched detach a foreign key refuses for good (a reference added once retention stopped
--           reaching the rows) is not left silent: the tick logs fail_retain_crossing, counted, with the two ways
--           out, and does not take the detach back itself. The way out it spells (idle the job) works: the next
--           tick clears the mark and the partition, never detached, serves its rows.
--   PART H: the CHECK a concurrent detach leaves on the table it takes out is gone from a monolith handed back by
--           untransmute after it was released and put back with the remedy's ATTACH, and the table's own CHECK
--           stays.
--   PART I: a dispatched detach a DEFAULT partition refuses for good (PostgreSQL detaches no partition concurrently
--           while one exists) is logged fail_retain_crossing and counted like a foreign key's, naming the DEFAULT.
--           The first way out it spells works: with the DEFAULT detached, the detach lands and the table is released.
--   PART J: a reference check that could not run (a lock timeout behind a second session holding the referencing
--           table) proves no refusal: logged skip_retain_crossing, uncounted, never fail_retain_crossing, and the
--           detach lands on pg_cron's next run.
--   PART K: #1451 path 1. The job idled (a pgpm.schedule() re-run) in the transaction of set_retain and retain(),
--           while a pg_cron run sent before it still carries the detach. The recall only stamps the mark, and the
--           run that lands once the transaction commits is released and counted, never stranded unrecorded. The
--           transaction outlasts the minute, and the tick right after the commit (pg_cron's cache still holding the
--           detach) only starts the clock: a clock started by the stamp itself would already have run out.
--   PART L: #1451 path 2. A role pg_cron does not show the job to (the table's owner, the jobs scheduled by an
--           administrator) keeps the mark and logs fail_retain_recall, counted, naming itself: once with no access to
--           schema cron at all, once with access and the job hidden by row security. The detach then lands and a
--           superuser's tick releases the table.
--   PART M: the idle clock belongs to one dispatch. A retirement whose clock ran out while retention was loose,
--           reached again and re-dispatched, then loosened again with the job idled in that transaction, keeps
--           its mark: the re-dispatch reset the clock.
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

select plan(130);

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
create function pgpm_test194.idle_at(p_parent regclass, p_lo text) returns text language sql as $$
  select case when recall_idle_at is null then 'null' when recall_idle_at = '-infinity' then '-infinity'
              when isfinite(recall_idle_at) then 'started' else recall_idle_at::text end
    from pgpm.part where parent_table = p_parent and lo = p_lo
$$;
-- the minute the recall waits after reading the job idle, passed (#1451)
create function pgpm_test194.minute_passes(p_parent regclass, p_lo text) returns void language sql as $$
  update pgpm.part set recall_idle_at = recall_idle_at - interval '61 seconds'
   where parent_table = p_parent and lo = p_lo and isfinite(recall_idle_at)
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
select is(pgpm_test194.idle_at('public.rr194e', '0'), '-infinity',
  'E: the first tick that reads the job idle keeps the mark and stamps it (#1451)');
call pgpm.maintain('public.rr194e');
select is(pgpm_test194.idle_at('public.rr194e', '0'), 'started', 'E: a later tick, seeing the stamp, starts the clock');
call pgpm.maintain('public.rr194e');
select is(pgpm_test194.mark('public.rr194e', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194e'::regclass and lo = '0')),
  'E: within the minute the mark stands: pg_cron may still launch the detach its cache held');
select pgpm_test194.minute_passes('public.rr194e', '0');
call pgpm.maintain('public.rr194e');
select is(pgpm_test194.mark('public.rr194e', '0'), 'retiring_at null, dispatched null', 'E: a minute on, the tick clears the mark nothing will detach');
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

-- ====== PART G: a detach a foreign key refuses for good is logged and counted, with a way out ======
create table public.rr194g (id bigint primary key, payload text);
insert into public.rr194g values (61, 'u'), (62, 'v'), (63, 'w');
call pgpm.transmute('public.rr194g', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194g', '60000');
insert into public.rr194g values (50005, 'frontier');
create table public.rr194g_ref (id bigint primary key, p_id bigint references public.rr194g(id));
insert into public.rr194g_ref values (1, 50005);
select child_name as g_doomed, hi as g_hi from pgpm.part
 where parent_table = 'public.rr194g'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194g', :'g_doomed'), 'fixture: (G) retire() dispatches the detach');
select pgpm_test194.armed() as g_cmd \gset
select pgpm.set_retain('public.rr194g', '45000');
select ok(not pgpm_test194.reached('public.rr194g', :'g_hi'), 'LIVENESS: (G) retention no longer reaches the partition');
-- the rows are kept now, so a reference to one of them is ordinary
insert into public.rr194g_ref values (2, 62);
select ok(pgpm_test194.cron_run(:'g_cmd') = 'ERROR' and pgpm_test194.attached('public.rr194g', :'g_doomed'),
  'LIVENESS: (G) pg_cron''s run of the detach is refused, and the partition stays attached');
call pgpm.maintain('public.rr194g');
call pgpm.maintain('public.rr194g');
select is((select count(*) from pgpm.log where parent_table = 'public.rr194g'::regclass and lo = '0'
             and action = 'fail_retain_crossing'), 2::bigint, 'G: each tick logs fail_retain_crossing for the refused detach');
select ok((select method from pgpm.log where parent_table = 'public.rr194g'::regclass and lo = '0'
             and action = 'fail_retain_crossing' order by id desc limit 1) ~ 'Remove the references.*cron\.alter_job',
  'G: its method gives both ways out');
select ok((select retain_drop_failures from pgpm.status() where parent = 'public.rr194g'::regclass) > 0,
  'G: and status() counts it');
select is(pgpm_test194.armed(), :'g_cmd', 'G: the detach is not taken back: the job still holds it');
select is(pgpm_test194.mark('public.rr194g', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194g'::regclass and lo = '0')),
  'G: and the mark stands until the operator acts');
-- the operator takes the second way out, with the statement the row spells
select substring(method from $re$select cron\.alter_job\(jobid, command => 'select 1'\) from cron\.job where jobname = 'pgpm_detach' and command = '[^']*'$re$)
  from pgpm.log where parent_table = 'public.rr194g'::regclass and lo = '0' and action = 'fail_retain_crossing'
 order by id desc limit 1 \gexec
select is(pgpm_test194.armed(), 'select 1', 'LIVENESS: (G) the statement the row spells idled the job');
call pgpm.maintain('public.rr194g');
call pgpm.maintain('public.rr194g');
select pgpm_test194.minute_passes('public.rr194g', '0');
call pgpm.maintain('public.rr194g');
select is(pgpm_test194.mark('public.rr194g', '0'), 'retiring_at null, dispatched null', 'G: a minute after the idle, a tick clears the mark');
select is(pgpm_test194.ids('public.rr194g', 20000), array[61, 62, 63]::bigint[], 'G: and ids 61, 62, 63 are served by the parent');

-- ====== PART H: a released monolith put back by hand comes out of untransmute without the detach's CHECK ======
create table public.rr194h (id bigint primary key, payload text constraint rr194h_own check (payload <> 'forbidden'));
insert into public.rr194h values (71, 'x'), (72, 'y'), (73, 'z');
call pgpm.transmute('public.rr194h', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194h', '60000');
insert into public.rr194h values (50005, 'frontier');
create table public.rr194h_ref (id bigint primary key, p_id bigint references public.rr194h(id));
insert into public.rr194h_ref values (1, 50005);
select child_name as h_doomed from pgpm.part where parent_table = 'public.rr194h'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194h', :'h_doomed'), 'fixture: (H) retire() dispatches the monolith''s detach');
select pgpm_test194.armed() as h_cmd \gset
select pgpm.set_retain('public.rr194h', '45000');
select pgpm_test194.cron_run(:'h_cmd');
select ok(exists (select 1 from pg_constraint where conrelid = format('public.%I', :'h_doomed')::regclass
                   and contype = 'c' and conname <> 'rr194h_own'),
  'LIVENESS: (H) the landed concurrent detach left its CHECK on the monolith');
call pgpm.maintain('public.rr194h');
select coalesce(substring(method from 'alter table [^;]* attach partition [^;]*;'), '') as h_attach
  from pgpm.log where parent_table = 'public.rr194h'::regclass and lo = '0' and action = 'retain_disown' \gset
select :'h_attach' \gexec
select ok(pgpm_test194.attached('public.rr194h', :'h_doomed'), 'LIVENESS: (H) the remedy''s ATTACH put the monolith back');
drop table public.rr194h_ref;
delete from public.rr194h where id >= 10000;
select pgpm.untransmute('public.rr194h');
select lives_ok($$ insert into public.rr194h values (20000, 'past the old bound') $$,
  'H: the restored table takes an id past the monolith''s old bound');
select throws_ok($$ insert into public.rr194h values (20001, 'forbidden') $$, '23514', NULL,
  'H: and its own CHECK still holds');
select is(pgpm_test194.ids('public.rr194h'), array[71, 72, 73, 20000]::bigint[], 'H: the restored table holds ids 71, 72, 73 and 20000');

-- ====== PART I: a detach a DEFAULT partition refuses for good is logged and counted, naming the DEFAULT ======
create table public.rr194i (id bigint primary key, payload text);
insert into public.rr194i values (81, 'i'), (82, 'j'), (83, 'k');
call pgpm.transmute('public.rr194i', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194i', '60000');
insert into public.rr194i values (50005, 'frontier');
create table public.rr194i_ref (id bigint primary key, p_id bigint references public.rr194i(id));
insert into public.rr194i_ref values (1, 50005);
select child_name as i_doomed from pgpm.part where parent_table = 'public.rr194i'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194i', :'i_doomed'), 'fixture: (I) retire() dispatches the detach');
select pgpm_test194.armed() as i_cmd \gset
select pgpm.set_retain('public.rr194i', '45000');
-- the operator attaches a DEFAULT partition, which nothing in pgpm refuses
create table public.rr194i_def partition of public.rr194i default;
select ok(pgpm_test194.cron_run(:'i_cmd') = 'ERROR' and pgpm_test194.attached('public.rr194i', :'i_doomed'),
  'LIVENESS: (I) pg_cron''s run of the detach is refused, and the partition stays attached');
select ok(coalesce(array_length(pgpm._crossing_keys('public.rr194i', '0', '10000'), 1), 0) = 0,
  'LIVENESS: (I) no foreign key references the partition''s rows: the refusal is the DEFAULT''s');
call pgpm.maintain('public.rr194i');
call pgpm.maintain('public.rr194i');
select is((select count(*) from pgpm.log where parent_table = 'public.rr194i'::regclass and lo = '0'
             and action = 'fail_retain_crossing'), 2::bigint, 'I: each tick logs fail_retain_crossing for the refused detach');
select ok((select method from pgpm.log where parent_table = 'public.rr194i'::regclass and lo = '0'
             and action = 'fail_retain_crossing' order by id desc limit 1) ~ 'Detach the DEFAULT partition rr194i_def.*cron\.alter_job',
  'I: its method names the DEFAULT and gives both ways out');
select ok((select retain_drop_failures from pgpm.status() where parent = 'public.rr194i'::regclass) > 0,
  'I: and status() counts it');
select is(pgpm_test194.armed(), :'i_cmd', 'I: the detach is not taken back: the job still holds it');
-- the operator takes the first way out
alter table public.rr194i detach partition public.rr194i_def;
select ok(pgpm_test194.cron_run(:'i_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194i', :'i_doomed'),
  'LIVENESS: (I) with the DEFAULT detached, pg_cron''s run lands');
call pgpm.maintain('public.rr194i');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rr194i'::regclass and lo = '0' and action = 'fail_retain_reattach'),
  'I: the next tick releases the table, counted');
select is(pgpm_test194.ids(format('public.%I', :'i_doomed')), array[81, 82, 83]::bigint[], 'I: the released table keeps ids 81, 82, 83');

-- ====== PART J: a reference check that could not run is an uncounted skip, and the detach still lands ======
create table public.rr194j (id bigint primary key, payload text);
insert into public.rr194j values (91, 'l'), (92, 'm'), (93, 'n');
call pgpm.transmute('public.rr194j', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194j', '60000');
insert into public.rr194j values (50005, 'frontier');
create table public.rr194j_ref (id bigint primary key, p_id bigint references public.rr194j(id));
insert into public.rr194j_ref values (1, 50005);
select child_name as j_doomed from pgpm.part where parent_table = 'public.rr194j'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194j', :'j_doomed'), 'fixture: (J) retire() dispatches the detach');
select pgpm_test194.armed() as j_cmd \gset
select pgpm.set_retain('public.rr194j', '45000');
select ok(coalesce(array_length(pgpm._crossing_keys('public.rr194j', '0', '10000'), 1), 0) = 0,
  'LIVENESS: (J) no foreign key references the partition''s rows: nothing refuses the detach');
-- a second session holds the referencing table across the tick
select dblink_connect('j194', format('dbname=%s user=postgres', current_database())) is not null as j_conn \gset
select dblink_exec('j194', 'begin') is not null as j_begin \gset
select dblink_exec('j194', 'lock table public.rr194j_ref in access exclusive mode') is not null as j_lock \gset
select ok(exists (select 1 from pg_locks l where l.relation = 'public.rr194j_ref'::regclass
                   and l.mode = 'AccessExclusiveLock' and l.granted and l.pid <> pg_backend_pid()),
  'LIVENESS: (J) a second session holds the referencing table');
call pgpm.maintain('public.rr194j');
select is((select count(*) from pgpm.log where parent_table = 'public.rr194j'::regclass and lo = '0'
             and action = 'skip_retain_crossing'), 1::bigint, 'J: the tick logs one skip_retain_crossing');
select ok((select method from pgpm.log where parent_table = 'public.rr194j'::regclass and lo = '0'
             and action = 'skip_retain_crossing') ~ 'could not check.*lock timeout',
  'J: its method says the check could not run, and why');
select is((select count(*) from pgpm.log where parent_table = 'public.rr194j'::regclass and lo = '0'
             and action = 'fail_retain_crossing'), 0::bigint, 'J: and no fail_retain_crossing');
select results_eq($$ select retain_drop_failures from pgpm.status() where parent = 'public.rr194j'::regclass $$,
  $$ values (0::bigint) $$, 'J: status() counts nothing');
select is(pgpm_test194.armed(), :'j_cmd', 'J: the job still holds the detach');
select dblink_exec('j194', 'commit') is not null as j_commit \gset
select dblink_disconnect('j194') is not null as j_disc \gset
select ok(pgpm_test194.cron_run(:'j_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194j', :'j_doomed'),
  'J: pg_cron''s next run lands the detach');
call pgpm.maintain('public.rr194j');
select is(pgpm_test194.ids(format('public.%I', :'j_doomed')), array[91, 92, 93]::bigint[], 'J: and the next tick releases the table with ids 91, 92, 93');

-- ====== PART K: #1451 path 1, the job idled in the recall's own transaction while a run carries the detach ======
create table public.rr194k (id bigint primary key, payload text);
insert into public.rr194k values (101, 'a'), (102, 'b'), (103, 'c'), (104, 'd');
call pgpm.transmute('public.rr194k', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194k', '60000');
insert into public.rr194k values (50005, 'frontier');
create table public.rr194k_ref (id bigint primary key, p_id bigint references public.rr194k(id));
insert into public.rr194k_ref values (1, 50005);
select child_name as k_doomed, hi as k_hi from pgpm.part where parent_table = 'public.rr194k'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194k', :'k_doomed'), 'fixture: (K) retire() dispatches the detach');
-- the run pg_cron sent before the idle: the command it carries is the one its cache held, the armed one
select pgpm_test194.armed() as k_cmd \gset
begin;
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- pgpm.schedule() re-run: the job idled
select pgpm.set_retain('public.rr194k', '45000');
select ok(not pgpm_test194.reached('public.rr194k', :'k_hi'), 'LIVENESS: (K) retention no longer reaches the partition');
select is(pgpm_test194.armed(), 'select 1', 'LIVENESS: (K) the recall will read the job idle');
select pgpm.retain('public.rr194k');
select is(pgpm_test194.mark('public.rr194k', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194k'::regclass and lo = '0')),
  'K: the recall that reads the idle in its own transaction keeps the mark');
select is(pgpm_test194.idle_at('public.rr194k', '0'), '-infinity', 'K: and only stamps it');
select pgpm_test194.minute_passes('public.rr194k', '0');   -- the transaction outlasts the minute
commit;
call pgpm.maintain('public.rr194k');   -- the tick right after the commit, pg_cron's cache still holding the detach
select is(pgpm_test194.idle_at('public.rr194k', '0'), 'started', 'K: the tick right after the commit only starts the clock');
select is(pgpm_test194.mark('public.rr194k', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194k'::regclass and lo = '0')),
  'K: and keeps the mark, however long the idle''s transaction ran');
select ok(pgpm_test194.cron_run(:'k_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194k', :'k_doomed'),
  'LIVENESS: (K) the run that carried the detach lands once the idle has committed');
call pgpm.maintain('public.rr194k');
select ok(pgpm_test194.accounted('public.rr194k', :'k_doomed', '0'), 'K: the invariant holds: pgpm logged the partition out of the parent');
select is(pgpm_test194.actions('public.rr194k', '0'), array['retain_detach', 'retain_disown', 'fail_retain_reattach'],
  'K: the tick released the table it found detached');
select is(pgpm_test194.ids(format('public.%I', :'k_doomed')), array[101, 102, 103, 104]::bigint[], 'K: with ids 101, 102, 103, 104');
select ok((select retain_drop_failures from pgpm.status() where parent = 'public.rr194k'::regclass) > 0, 'K: and status() counts it');

-- ====== PART L: #1451 path 2, a role that cannot see the job keeps the mark, counted ======
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pgpm_test194_owner') then
    create role pgpm_test194_owner nosuperuser nobypassrls;
  end if;
end $$;
grant create, usage on schema public to pgpm_test194_owner;
grant usage on schema pgpm to pgpm_test194_owner;
grant all on all tables in schema pgpm to pgpm_test194_owner;
grant all on all sequences in schema pgpm to pgpm_test194_owner;
create table public.rr194l (id bigint primary key, payload text);
insert into public.rr194l values (111, 'e'), (112, 'f'), (113, 'g'), (114, 'h'), (115, 'i');
call pgpm.transmute('public.rr194l', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194l', '60000');
insert into public.rr194l values (50005, 'frontier');
create table public.rr194l_ref (id bigint primary key, p_id bigint references public.rr194l(id));
insert into public.rr194l_ref values (1, 50005);
select child_name as l_doomed, hi as l_hi from pgpm.part where parent_table = 'public.rr194l'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rr194l', :'l_doomed'), 'fixture: (L) retire() dispatches the detach');
select pgpm_test194.armed() as l_cmd \gset
-- the table is the role's: the administrator scheduled the jobs, the owner runs its own table's maintenance
select format('alter table %s owner to pgpm_test194_owner', r) from (
  select 'public.rr194l'::regclass r union all select 'public.rr194l_ref'::regclass
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rr194l'::regclass) t \gexec
select pgpm.set_retain('public.rr194l', '45000');
select ok(not pgpm_test194.reached('public.rr194l', :'l_hi'), 'LIVENESS: (L) retention no longer reaches the partition');
select ok(not rolsuper and not rolbypassrls, 'LIVENESS: (L) the role is neither a superuser nor exempt from row security')
  from pg_roles where rolname = 'pgpm_test194_owner';
-- pgTAP's bookkeeping is this session's temp objects, which the role cannot touch: observations go through
-- set_config and are asserted after reset role
set role pgpm_test194_owner;
select set_config('t194.l1_read', (select case when has_schema_privilege('cron', 'usage') then 'readable' else 'denied' end), false);
select pgpm.retain('public.rr194l');
reset role;
select is(current_setting('t194.l1_read'), 'denied', 'LIVENESS: (L) the role has no access to schema cron at all');
select is(pgpm_test194.armed(), :'l_cmd', 'LIVENESS: (L) the job still holds the detach, as the role cannot see');
select is(pgpm_test194.mark('public.rr194l', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194l'::regclass and lo = '0')),
  'L: a role that cannot read cron.job keeps the mark');
-- the role reads cron.job, and row security shows it nothing: pg_cron's own policy hides another role's job
grant usage on schema cron to pgpm_test194_owner;
grant select on cron.job to pgpm_test194_owner;
alter table cron.job enable row level security;
set role pgpm_test194_owner;
select set_config('t194.l2_seen', (select count(*)::text from cron.job), false);
select pgpm.retain('public.rr194l');
reset role;
select is(current_setting('t194.l2_seen'), '0', 'LIVENESS: (L) the role reads cron.job and sees no job in it');
select is(pgpm_test194.mark('public.rr194l', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194l'::regclass and lo = '0')),
  'L: a role row security hides the job from keeps the mark too');
select is(pgpm_test194.idle_at('public.rr194l', '0'), 'null', 'L: and starts no idle clock: it read nothing');
select is((select count(*) from pgpm.log where parent_table = 'public.rr194l'::regclass and lo = '0' and action = 'fail_retain_recall'),
  2::bigint, 'L: each of the two ticks logs fail_retain_recall');
select ok((select method from pgpm.log where parent_table = 'public.rr194l'::regclass and lo = '0' and action = 'fail_retain_recall'
            order by id desc limit 1) ~ 'role pgpm_test194_owner sees no pgpm_detach job.*pgpm\.schedule\(\)',
  'L: its method names the role and the way out');
select ok((select retain_drop_failures from pgpm.status() where parent = 'public.rr194l'::regclass) > 0, 'L: and status() counts it');
alter table cron.job disable row level security;
select ok(pgpm_test194.cron_run(:'l_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194l', :'l_doomed'),
  'LIVENESS: (L) pg_cron''s run lands the detach the role could not see');
call pgpm.maintain('public.rr194l');
select ok(pgpm_test194.accounted('public.rr194l', :'l_doomed', '0'), 'L: the invariant holds: pgpm logged the partition out of the parent');
select is(pgpm_test194.ids(format('public.%I', :'l_doomed')), array[111, 112, 113, 114, 115]::bigint[], 'L: and released it with ids 111 to 115');

-- ====== PART M: the idle clock belongs to one dispatch: a re-dispatch resets it ======
create table public.rr194m (id bigint primary key, payload text);
insert into public.rr194m values (121, 'j'), (122, 'k'), (123, 'l'), (124, 'm'), (125, 'n'), (126, 'o');
call pgpm.transmute('public.rr194m', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194m', '60000');
insert into public.rr194m values (50005, 'frontier');
create table public.rr194m_ref (id bigint primary key, p_id bigint references public.rr194m(id));
insert into public.rr194m_ref values (1, 50005);
select child_name as m_doomed, hi as m_hi from pgpm.part where parent_table = 'public.rr194m'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rr194m', :'m_doomed'), 'fixture: (M) retire() dispatches the detach');
select pgpm_test194.armed() as m_cmd \gset
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';
select pgpm.set_retain('public.rr194m', '45000');
select pgpm.retain('public.rr194m');
select pgpm.retain('public.rr194m');
select pgpm_test194.minute_passes('public.rr194m', '0');
select is(pgpm_test194.idle_at('public.rr194m', '0'), 'started', 'LIVENESS: (M) the first dispatch''s idle clock started, and ran out');
-- retention reaches the partition again before a tick clears it (a newer row moves the frontier on): retire()
-- re-dispatches
insert into public.rr194m values (55005, 'newer');
select ok(pgpm_test194.reached('public.rr194m', :'m_hi'), 'LIVENESS: (M) retention reaches the partition again');
call pgpm.maintain('public.rr194m');
select is(pgpm_test194.armed(), :'m_cmd', 'LIVENESS: (M) the tick re-dispatched the detach');
select is(pgpm_test194.idle_at('public.rr194m', '0'), 'null', 'M: and the re-dispatch reset the idle clock');
-- loosened again, the job idled in the same transaction while a run carries the detach
begin;
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';
delete from public.rr194m where id = 55005;   -- the frontier moves back
select pgpm.retain('public.rr194m');
select is(pgpm_test194.mark('public.rr194m', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194m'::regclass and lo = '0')),
  'M: the second loosening keeps the mark: the first dispatch''s clock does not carry over');
commit;
select ok(pgpm_test194.cron_run(:'m_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194m', :'m_doomed'),
  'LIVENESS: (M) the run that carried the detach lands');
call pgpm.maintain('public.rr194m');
select ok(pgpm_test194.accounted('public.rr194m', :'m_doomed', '0'), 'M: the invariant holds: pgpm logged the partition out of the parent');
select is(pgpm_test194.ids(format('public.%I', :'m_doomed')), array[121, 122, 123, 124, 125, 126]::bigint[], 'M: and released it with ids 121 to 126');

select * from finish();
