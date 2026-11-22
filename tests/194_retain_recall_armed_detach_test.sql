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
--   PART N: the clock starts only in a later transaction than the one that first read the idle. Two retain() calls in
--           the idle's own transaction, held open past the minute, leave it unstarted, and the tick right after the
--           commit only starts it (round 1 of PR #1459, P1-02).
--   PART O: a role that runs pgpm.schedule() too has a pgpm_detach job of its own. Seeing that one idle is no reading
--           of the administrator's, which holds the detach: the owner's tick keeps the mark, counted, naming the role
--           that dispatched (PR #1459 round 1, V-01).
--   PART P: a mark with no record of pgpm's dispatch (an upgrade from v0.6.0 run by a role that could not read the
--           job) is kept, counted, by a non-superuser's tick, never cleared at once (PR #1459 round 1, V-02).
--   PART Q: the role that dispatched its own job's detach reads it: its ticks wait out the idle and clear the mark,
--           with nothing refused.
--   PART R: a mark this release made whose dispatch was refused (the owner has no job of its own) is held by no job,
--           and the owner's tick clears it at once, as before #1451.
--   PART S: a superuser's re-dispatch of the owner's detach arms the administrator's job too, so the owner's own idle
--           job is no reading any more: its ticks keep the mark, counted, past the minute.
--   PART T: a role with no access to schema cron at all, whose own dispatch was refused, still clears that mark at
--           once: nothing holds it (PR #1459 round 2, P1-01).
--   PART U: the administrator's job lands the detach; the owner's tick, which cannot read that job and so could not
--           idle it, keeps the mark and the table out of the parent, counted, rather than release it into a job still
--           armed; a superuser's tick then releases it and idles the job (PR #1459 round 2, V-01).
--   PART V: a mark with no record of pgpm's dispatch (an upgrade from v0.6.0 run by a role that could not read the
--           job) waits out the idle under a superuser's tick too: the recall in the idle's own transaction only
--           stamps it, and the run that lands after the commit is logged out of the parent (PR #1459 round 3,
--           V-01).
--   PART W: a landed detach under such a mark is not released by the owner's tick, which cannot read the job that may
--           hold it, nor disowned by the owner's install pass; a superuser's tick idles the job and releases the table
--           (PR #1459 round 4, V-01).
--   PART X: the same mark on a partition its interrupted detach left pending: the owner's retire() refuses it, counted,
--           pending and once the owner's reap has finished the detach, and the reap keeps the mark; a superuser's
--           retire() idles the job and releases the table, never dropping it.
--   PART Y: a stamp past the cluster's xid counter (pgpm.part restored into a younger cluster) is of no live
--           transaction: the clock starts and retain() does not fail (PR #1459 round 4, P1-01).
--   PART Z: with no pg_cron, nothing can run a detach, and an older mark is cleared at once (PR #1459 round 4, P1-02).
--   PART AA: a role granted cron.job's other columns but not its command reads the table and not the job: its
--           ticks keep the owner's own dispatched mark, counted (PR #1492, Codex P2).
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

select plan(232);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text,
                       username text not null default current_user);
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
  select command from cron.job where jobname = 'pgpm_detach' and jobid = 1   -- the administrator's job
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
  select case when recall_idle_xact is null and recall_idle_at is null then 'null'
              when recall_idle_at is null then 'stamped' when recall_idle_xact is not null then 'started'
              else 'clock with no stamp' end
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
select pgpm_formal.baseline('public.rr194a');   -- the invariant oracle's row ledger (docs/formal/phase3-design.md)
call pgpm.transmute('public.rr194a', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194a', '60000');
insert into public.rr194a values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194a', 'id = 50005');
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
select pgpm_formal.wrote('public.rr194a', 'id = 4');

-- ====== PART B: #1438's race, no operator: a late run of the detach finds nothing pgpm put back ======
create table public.rr194b (id bigint primary key, payload text);
insert into public.rr194b values (5, 'e'), (6, 'f'), (7, 'g'), (8, 'h');
select pgpm_formal.baseline('public.rr194b');
call pgpm.transmute('public.rr194b', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194b', '60000');
insert into public.rr194b values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194b', 'id = 50005');
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
select pgpm_formal.baseline('public.rr194c');
call pgpm.transmute('public.rr194c', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194c', '60000');
insert into public.rr194c values (30005, 'second'), (50005, 'frontier');
select pgpm_formal.wrote('public.rr194c', 'id in (30005, 50005)');
create table public.rr194c_ref (id bigint primary key, p_id bigint references public.rr194c(id));
insert into public.rr194c_ref values (1, 30005);
select child_name as c_doomed, hi as c_hi from pgpm.part
 where parent_table = 'public.rr194c'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194c', :'c_doomed'), 'fixture: (C) retire() dispatches the detach');
select pgpm_test194.armed() as c_cmd \gset
delete from public.rr194c where id = 50005;   -- the frontier moves back to 30005: horizon 20000 -> 0
select pgpm_formal.deleted('public.rr194c', 'id = 50005');
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
select pgpm_formal.baseline('public.rr194d');
call pgpm.transmute('public.rr194d', 'id', 10000::bigint, p_retain => 20000, p_paused => false);
select pgpm.extend_to('public.rr194d', '40000');
insert into public.rr194d values (30005, 'frontier');
select pgpm_formal.wrote('public.rr194d', 'id = 30005');
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
select pgpm_formal.baseline('public.rr194e');
call pgpm.transmute('public.rr194e', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194e', '60000');
insert into public.rr194e values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194e', 'id = 50005');
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
select is(pgpm_test194.idle_at('public.rr194e', '0'), 'stamped',
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
select pgpm_formal.baseline('public.rr194f');
call pgpm.transmute('public.rr194f', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194f', '60000');
insert into public.rr194f values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194f', 'id = 50005');
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
select pgpm_formal.baseline('public.rr194g');
call pgpm.transmute('public.rr194g', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194g', '60000');
insert into public.rr194g values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194g', 'id = 50005');
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
select pgpm_formal.baseline('public.rr194h');
call pgpm.transmute('public.rr194h', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194h', '60000');
insert into public.rr194h values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194h', 'id = 50005');
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
select pgpm_formal.deleted('public.rr194h', 'id >= 10000');
select pgpm.untransmute('public.rr194h');
select lives_ok($$ insert into public.rr194h values (20000, 'past the old bound') $$,
  'H: the restored table takes an id past the monolith''s old bound');
select pgpm_formal.wrote('public.rr194h', 'id = 20000');
select throws_ok($$ insert into public.rr194h values (20001, 'forbidden') $$, '23514', NULL,
  'H: and its own CHECK still holds');
select is(pgpm_test194.ids('public.rr194h'), array[71, 72, 73, 20000]::bigint[], 'H: the restored table holds ids 71, 72, 73 and 20000');

-- ====== PART I: a detach a DEFAULT partition refuses for good is logged and counted, naming the DEFAULT ======
create table public.rr194i (id bigint primary key, payload text);
insert into public.rr194i values (81, 'i'), (82, 'j'), (83, 'k');
select pgpm_formal.baseline('public.rr194i');
call pgpm.transmute('public.rr194i', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194i', '60000');
insert into public.rr194i values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194i', 'id = 50005');
create table public.rr194i_ref (id bigint primary key, p_id bigint references public.rr194i(id));
insert into public.rr194i_ref values (1, 50005);
select child_name as i_doomed from pgpm.part where parent_table = 'public.rr194i'::regclass and lo = '0' \gset

select ok(not pgpm.retire('public.rr194i', :'i_doomed'), 'fixture: (I) retire() dispatches the detach');
select pgpm_test194.armed() as i_cmd \gset
select pgpm.set_retain('public.rr194i', '45000');
-- the operator attaches a DEFAULT partition, which nothing in pgpm refuses
create table public.rr194i_def partition of public.rr194i default;
select pgpm_formal.operator_owns('public.rr194i_def');
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
select pgpm_formal.baseline('public.rr194j');
call pgpm.transmute('public.rr194j', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194j', '60000');
insert into public.rr194j values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194j', 'id = 50005');
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
select pgpm_formal.baseline('public.rr194k');
call pgpm.transmute('public.rr194k', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194k', '60000');
insert into public.rr194k values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194k', 'id = 50005');
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
select is(pgpm_test194.idle_at('public.rr194k', '0'), 'stamped', 'K: and only stamps it');
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
select pgpm_formal.baseline('public.rr194l');
call pgpm.transmute('public.rr194l', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194l', '60000');
insert into public.rr194l values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194l', 'id = 50005');
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
            order by id desc limit 1) ~ 'dispatched as role postgres, but role pgpm_test194_owner cannot read the pgpm_detach job.*Run maintenance as role postgres',
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
select pgpm_formal.baseline('public.rr194m');
call pgpm.transmute('public.rr194m', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194m', '60000');
insert into public.rr194m values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194m', 'id = 50005');
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
select pgpm_formal.wrote('public.rr194m', 'id = 55005');
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
select pgpm_formal.deleted('public.rr194m', 'id = 55005');
select ok(pgpm_test194.cron_run(:'m_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194m', :'m_doomed'),
  'LIVENESS: (M) the run that carried the detach lands');
call pgpm.maintain('public.rr194m');
select ok(pgpm_test194.accounted('public.rr194m', :'m_doomed', '0'), 'M: the invariant holds: pgpm logged the partition out of the parent');
select is(pgpm_test194.ids(format('public.%I', :'m_doomed')), array[121, 122, 123, 124, 125, 126]::bigint[], 'M: and released it with ids 121 to 126');

-- ====== PART N: the clock starts only in a later transaction than the one that read the idle ======
create table public.rr194n (id bigint primary key, payload text);
insert into public.rr194n select g, 'n' from generate_series(131, 137) g;
select pgpm_formal.baseline('public.rr194n');
call pgpm.transmute('public.rr194n', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194n', '60000');
insert into public.rr194n values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194n', 'id = 50005');
create table public.rr194n_ref (id bigint primary key, p_id bigint references public.rr194n(id));
insert into public.rr194n_ref values (1, 50005);
select child_name as n_doomed from pgpm.part where parent_table = 'public.rr194n'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rr194n', :'n_doomed'), 'fixture: (N) retire() dispatches the detach');
select pgpm_test194.armed() as n_cmd \gset
begin;
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- pgpm.schedule() re-run
select pgpm.set_retain('public.rr194n', '45000');
select pgpm.retain('public.rr194n');
select pgpm.retain('public.rr194n');
select is(pgpm_test194.idle_at('public.rr194n', '0'), 'stamped',
  'N: a second tick in the idle''s own transaction does not start the clock');
select pgpm_test194.minute_passes('public.rr194n', '0');   -- the transaction outlasts the minute
commit;
call pgpm.maintain('public.rr194n');   -- the tick right after the commit, pg_cron's cache still holding the detach
select is(pgpm_test194.mark('public.rr194n', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194n'::regclass and lo = '0')),
  'N: the tick right after the commit keeps the mark');
select is(pgpm_test194.idle_at('public.rr194n', '0'), 'started', 'N: and only starts the clock');
select ok(pgpm_test194.cron_run(:'n_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194n', :'n_doomed'),
  'LIVENESS: (N) the run that carried the detach lands');
call pgpm.maintain('public.rr194n');
select ok(pgpm_test194.accounted('public.rr194n', :'n_doomed', '0'), 'N: the invariant holds: pgpm logged the partition out of the parent');
select is(pgpm_test194.ids(format('public.%I', :'n_doomed')), array[131, 132, 133, 134, 135, 136, 137]::bigint[], 'N: and released it with ids 131 to 137');

-- pg_cron's own row security: a role sees only the jobs it scheduled (parts O, P, Q)
create policy pgpm_test194_own on cron.job using (username = current_user);
alter table cron.job enable row level security;
grant update on cron.job to pgpm_test194_owner;

-- ====== PART O: the owner's own idle job is no reading of the administrator's ======
create table public.rr194o (id bigint primary key, payload text);
insert into public.rr194o select g, 'o' from generate_series(141, 148) g;
select pgpm_formal.baseline('public.rr194o');
call pgpm.transmute('public.rr194o', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194o', '60000');
insert into public.rr194o values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194o', 'id = 50005');
create table public.rr194o_ref (id bigint primary key, p_id bigint references public.rr194o(id));
insert into public.rr194o_ref values (1, 50005);
select child_name as o_doomed, hi as o_hi from pgpm.part where parent_table = 'public.rr194o'::regclass and lo = '0' \gset
select format('alter table %s owner to pgpm_test194_owner', r) from (
  select 'public.rr194o'::regclass r union all select 'public.rr194o_ref'::regclass
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rr194o'::regclass) t \gexec
-- the owner ran pgpm.schedule() too: a pgpm_detach job of its own, idle
insert into cron.job values (2, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test194_owner');
select ok(not pgpm.retire('public.rr194o', :'o_doomed'), 'fixture: (O) the administrator''s tick dispatches the detach');
select pgpm_test194.armed() as o_cmd \gset
update cron.job set command = 'select 1' where jobid = 2;   -- the owner's re-run of pgpm.schedule() idles its own job
select pgpm.set_retain('public.rr194o', '45000');
set role pgpm_test194_owner;
select set_config('t194.o_seen', (select string_agg(format('%s:%s', username, command), ',') from cron.job), false);
select pgpm.retain('public.rr194o');
select pgpm.retain('public.rr194o');
reset role;
select is(current_setting('t194.o_seen'), 'pgpm_test194_owner:select 1', 'LIVENESS: (O) the owner sees one pgpm_detach job, its own, idle');
select is(pgpm_test194.armed(), :'o_cmd', 'LIVENESS: (O) the administrator''s job holds the detach');
select is(pgpm_test194.mark('public.rr194o', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194o'::regclass and lo = '0')),
  'O: the owner''s ticks keep the mark');
select is(pgpm_test194.idle_at('public.rr194o', '0'), 'null', 'O: and read no idle: its own job is not the one');
select ok((select count(*) from pgpm.log where parent_table = 'public.rr194o'::regclass and lo = '0' and action = 'fail_retain_recall') = 2
          and (select method from pgpm.log where parent_table = 'public.rr194o'::regclass and lo = '0' and action = 'fail_retain_recall'
                order by id desc limit 1) ~ 'Run maintenance as role postgres',
  'O: each tick logs fail_retain_recall, naming the role that dispatched');
select ok(pgpm_test194.cron_run(:'o_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194o', :'o_doomed'),
  'LIVENESS: (O) the administrator''s job lands the detach');
call pgpm.maintain('public.rr194o');
select ok(pgpm_test194.accounted('public.rr194o', :'o_doomed', '0'), 'O: the invariant holds: pgpm logged the partition out of the parent');
select is(pgpm_test194.ids(format('public.%I', :'o_doomed')), array[141, 142, 143, 144, 145, 146, 147, 148]::bigint[], 'O: and released it with ids 141 to 148');
delete from cron.job where jobid = 2;

-- ====== PART P: a mark with no record of pgpm's dispatch is kept by a non-superuser's tick ======
create table public.rr194p (id bigint primary key, payload text);
insert into public.rr194p select g, 'p' from generate_series(151, 159) g;
select pgpm_formal.baseline('public.rr194p');
call pgpm.transmute('public.rr194p', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194p', '60000');
insert into public.rr194p values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194p', 'id = 50005');
create table public.rr194p_ref (id bigint primary key, p_id bigint references public.rr194p(id));
insert into public.rr194p_ref values (1, 50005);
select child_name as p_doomed from pgpm.part where parent_table = 'public.rr194p'::regclass and lo = '0' \gset
select format('alter table %s owner to pgpm_test194_owner', r) from (
  select 'public.rr194p'::regclass r union all select 'public.rr194p_ref'::regclass
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rr194p'::regclass) t \gexec
select ok(not pgpm.retire('public.rr194p', :'p_doomed'), 'fixture: (P) the administrator''s tick dispatches the detach');
select pgpm_test194.armed() as p_cmd \gset
-- what an upgrade from v0.6.0 leaves when the role running it cannot read the job: the mark with no record
update pgpm.part set detach_dispatched_oid = null, retiring_by = null
 where parent_table = 'public.rr194p'::regclass and lo = '0';
-- the owner's tick retries the dispatch while retention still reaches it, and sees no job to arm
set role pgpm_test194_owner;
select set_config('t194.p_retry', (pgpm.retire('public.rr194p', :'p_doomed'))::text, false);
reset role;
select ok(current_setting('t194.p_retry') = 'false'
          and (select action from pgpm.log where parent_table = 'public.rr194p'::regclass and lo = '0' order by id desc limit 1) = 'fail_retain_detach',
  'LIVENESS: (P) the owner''s retry ran and its dispatch was refused');
select is((select coalesce(retiring_by::text, 'null') from pgpm.part where parent_table = 'public.rr194p'::regclass and lo = '0'), 'null',
  'P: the retry does not claim the older mark for its role');
select pgpm.set_retain('public.rr194p', '45000');
set role pgpm_test194_owner;
select pgpm.retain('public.rr194p');
reset role;
select is(pgpm_test194.armed(), :'p_cmd', 'LIVENESS: (P) the job still holds the detach');
select is(pgpm_test194.mark('public.rr194p', '0'), 'retiring_at set, dispatched null', 'P: the owner''s tick keeps the unrecorded mark');
select ok((select method from pgpm.log where parent_table = 'public.rr194p'::regclass and lo = '0' and action = 'fail_retain_recall')
            ~ 'a pgpm older than this release may have dispatched',
  'P: and logs fail_retain_recall, saying an older pgpm may have dispatched it');
select ok(pgpm_test194.cron_run(:'p_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194p', :'p_doomed'),
  'LIVENESS: (P) the job lands the detach');
call pgpm.maintain('public.rr194p');
select ok('retain_disown' = any(pgpm_test194.actions('public.rr194p', '0')), 'P: the landed detach is logged out of the parent (retain_disown)');
select is(pgpm_test194.ids(format('public.%I', :'p_doomed')), array[151, 152, 153, 154, 155, 156, 157, 158, 159]::bigint[], 'P: with ids 151 to 159');

-- ====== PART Q: the role that dispatched its own job's detach reads it ======
insert into cron.job values (3, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test194_owner');
set role pgpm_test194_owner;
create table public.rr194q (id bigint primary key, payload text);
insert into public.rr194q select g, 'q' from generate_series(161, 170) g;
reset role;   -- the ledger is the test harness's, not the owner's
select pgpm_formal.baseline('public.rr194q');
set role pgpm_test194_owner;
call pgpm.transmute('public.rr194q', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194q', '60000');
insert into public.rr194q values (50005, 'frontier');
create table public.rr194q_ref (id bigint primary key, p_id bigint references public.rr194q(id));
insert into public.rr194q_ref values (1, 50005);
select child_name as q_doomed from pgpm.part where parent_table = 'public.rr194q'::regclass and lo = '0' \gset
select set_config('t194.q_retire', (pgpm.retire('public.rr194q', :'q_doomed'))::text, false);
reset role;
select pgpm_formal.wrote('public.rr194q', 'id = 50005');
select is(current_setting('t194.q_retire'), 'false', 'fixture: (Q) the owner''s own tick dispatches the detach');
select ok((select command from cron.job where jobid = 3) ~ 'detach partition' and pgpm_test194.armed() = 'select 1',
  'LIVENESS: (Q) the owner''s job holds the detach, the administrator''s does not');
select is((select retiring_by::text from pgpm.part where parent_table = 'public.rr194q'::regclass and lo = '0'),
  'pgpm_test194_owner', 'Q: the dispatch records its role');
update cron.job set command = 'select 1' where jobid = 3;   -- the owner idles its own job
select pgpm.set_retain('public.rr194q', '45000');
set role pgpm_test194_owner;
select pgpm.retain('public.rr194q');
select pgpm.retain('public.rr194q');
select set_config('t194.q_idle', (select case when recall_idle_at is not null then 'started' else 'not started' end
  from pgpm.part where parent_table = 'public.rr194q'::regclass and lo = '0'), false);
reset role;
select is(current_setting('t194.q_idle'), 'started', 'Q: the owner''s ticks read its own idle job and start the clock');
select pgpm_test194.minute_passes('public.rr194q', '0');
set role pgpm_test194_owner;
select pgpm.retain('public.rr194q');
reset role;
select is(pgpm_test194.mark('public.rr194q', '0'), 'retiring_at null, dispatched null', 'Q: a minute on, the owner''s tick clears the mark');
select is((select count(*) from pgpm.log where parent_table = 'public.rr194q'::regclass and action = 'fail_retain_recall'), 0::bigint,
  'Q: and nothing was refused');
select ok(pgpm_test194.attached('public.rr194q', :'q_doomed') and pgpm_test194.ids('public.rr194q', 20000) = array(select generate_series(161, 170)::bigint),
  'Q: the partition never left the parent: ids 161 to 170 are served');
delete from cron.job where jobid = 3;

-- ====== PART R: a mark whose dispatch this release refused is cleared at once ======
set role pgpm_test194_owner;
create table public.rr194r (id bigint primary key, payload text);
insert into public.rr194r select g, 'r' from generate_series(171, 181) g;
reset role;   -- the ledger is the test harness's, not the owner's
select pgpm_formal.baseline('public.rr194r');
set role pgpm_test194_owner;
call pgpm.transmute('public.rr194r', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194r', '60000');
insert into public.rr194r values (50005, 'frontier');
create table public.rr194r_ref (id bigint primary key, p_id bigint references public.rr194r(id));
insert into public.rr194r_ref values (1, 50005);
select child_name as r_doomed from pgpm.part where parent_table = 'public.rr194r'::regclass and lo = '0' \gset
select set_config('t194.r_retire', (pgpm.retire('public.rr194r', :'r_doomed'))::text, false);
reset role;
select pgpm_formal.wrote('public.rr194r', 'id = 50005');
select ok(current_setting('t194.r_retire') = 'false'
          and (select action from pgpm.log where parent_table = 'public.rr194r'::regclass and lo = '0' order by id desc limit 1) = 'fail_retain_detach'
          and pgpm_test194.mark('public.rr194r', '0') = 'retiring_at set, dispatched null',
  'LIVENESS: (R) the owner''s tick marked the partition and its dispatch was refused: it has no job of its own');
select is(pgpm_test194.armed(), 'select 1', 'LIVENESS: (R) and no job holds the detach');
select pgpm.set_retain('public.rr194r', '45000');
set role pgpm_test194_owner;
select pgpm.retain('public.rr194r');
reset role;
select is(pgpm_test194.mark('public.rr194r', '0'), 'retiring_at null, dispatched null', 'R: the owner''s tick clears the mark at once');
select is((select count(*) from pgpm.log where parent_table = 'public.rr194r'::regclass and action = 'fail_retain_recall'), 0::bigint,
  'R: with nothing refused');
select ok(pgpm_test194.attached('public.rr194r', :'r_doomed') and pgpm_test194.ids('public.rr194r', 20000) = array(select generate_series(171, 181)::bigint),
  'R: the partition never left the parent: ids 171 to 181 are served');

-- ====== PART S: a superuser's re-dispatch of the owner's detach is no longer the owner's to read ======
insert into cron.job values (4, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test194_owner');
set role pgpm_test194_owner;
create table public.rr194s (id bigint primary key, payload text);
insert into public.rr194s select g, 's' from generate_series(191, 202) g;
reset role;   -- the ledger is the test harness's, not the owner's
select pgpm_formal.baseline('public.rr194s');
set role pgpm_test194_owner;
call pgpm.transmute('public.rr194s', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194s', '60000');
insert into public.rr194s values (50005, 'frontier');
create table public.rr194s_ref (id bigint primary key, p_id bigint references public.rr194s(id));
insert into public.rr194s_ref values (1, 50005);
select child_name as s_doomed from pgpm.part where parent_table = 'public.rr194s'::regclass and lo = '0' \gset
select set_config('t194.s_retire', (pgpm.retire('public.rr194s', :'s_doomed'))::text, false);
reset role;
select pgpm_formal.wrote('public.rr194s', 'id = 50005');
select ok(current_setting('t194.s_retire') = 'false', 'fixture: (S) the owner''s tick dispatches through its own job');
select ok(not pgpm.retire('public.rr194s', :'s_doomed'), 'fixture: (S) the administrator''s tick dispatches it again');
select pgpm_test194.armed() as s_cmd \gset
select ok(:'s_cmd' ~ 'detach partition' and (select command from cron.job where jobid = 4) = :'s_cmd',
  'LIVENESS: (S) both jobs hold the detach');
select is((select coalesce(retiring_by::text, 'null') from pgpm.part where parent_table = 'public.rr194s'::regclass and lo = '0'), 'null',
  'S: the record no longer names one role');
update cron.job set command = 'select 1' where jobid = 4;   -- the owner idles its own job
select pgpm.set_retain('public.rr194s', '45000');
set role pgpm_test194_owner;
select pgpm.retain('public.rr194s');
select pgpm.retain('public.rr194s');
reset role;
update pgpm.part set recall_idle_at = clock_timestamp() - interval '61 seconds'   -- the minute, had a clock started
 where parent_table = 'public.rr194s'::regclass and lo = '0' and recall_idle_at is not null;
set role pgpm_test194_owner;
select pgpm.retain('public.rr194s');
reset role;
select is(pgpm_test194.mark('public.rr194s', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194s'::regclass and lo = '0')),
  'S: the owner''s ticks keep the mark while the administrator''s job holds the detach');
select ok((select count(*) from pgpm.log where parent_table = 'public.rr194s'::regclass and lo = '0' and action = 'fail_retain_recall') = 3
          and (select method from pgpm.log where parent_table = 'public.rr194s'::regclass and lo = '0' and action = 'fail_retain_recall'
                order by id desc limit 1) ~ 'Run maintenance as a superuser',
  'S: each logs fail_retain_recall, naming a superuser as the way out');
select ok(pgpm_test194.cron_run(:'s_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194s', :'s_doomed'),
  'LIVENESS: (S) the administrator''s job lands the detach');
call pgpm.maintain('public.rr194s');
select ok(pgpm_test194.accounted('public.rr194s', :'s_doomed', '0'), 'S: the invariant holds: pgpm logged the partition out of the parent');
select is(pgpm_test194.ids(format('public.%I', :'s_doomed')), array(select generate_series(191, 202)::bigint), 'S: and released it with ids 191 to 202');
delete from cron.job where jobid = 4;

-- ====== PART T: a refused dispatch by a role that cannot read cron at all is still cleared at once ======
set role pgpm_test194_owner;
create table public.rr194t (id bigint primary key, payload text);
insert into public.rr194t select g, 't' from generate_series(211, 223) g;
reset role;   -- the ledger is the test harness's, not the owner's
select pgpm_formal.baseline('public.rr194t');
set role pgpm_test194_owner;
call pgpm.transmute('public.rr194t', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194t', '60000');
insert into public.rr194t values (50005, 'frontier');
create table public.rr194t_ref (id bigint primary key, p_id bigint references public.rr194t(id));
insert into public.rr194t_ref values (1, 50005);
reset role;
select pgpm_formal.wrote('public.rr194t', 'id = 50005');
select child_name as t_doomed from pgpm.part where parent_table = 'public.rr194t'::regclass and lo = '0' \gset
revoke usage on schema cron from pgpm_test194_owner;
set role pgpm_test194_owner;
select set_config('t194.t_retire', (pgpm.retire('public.rr194t', :'t_doomed'))::text, false);
select pgpm.set_retain('public.rr194t', '45000');
select pgpm.retain('public.rr194t');
reset role;
grant usage on schema cron to pgpm_test194_owner;
select ok(current_setting('t194.t_retire') = 'false'
          and exists (select 1 from pgpm.log where parent_table = 'public.rr194t'::regclass and lo = '0' and action = 'fail_retain_detach'
                        and method ~ 'permission denied'),
  'LIVENESS: (T) the owner''s tick marked the partition and its dispatch was refused: it cannot read schema cron');
select is(pgpm_test194.mark('public.rr194t', '0'), 'retiring_at null, dispatched null', 'T: the owner''s tick clears that mark at once');
select is((select count(*) from pgpm.log where parent_table = 'public.rr194t'::regclass and action = 'fail_retain_recall'), 0::bigint,
  'T: with nothing refused');
select ok(pgpm_test194.attached('public.rr194t', :'t_doomed') and pgpm_test194.ids('public.rr194t', 20000) = array(select generate_series(211, 223)::bigint),
  'T: the partition never left the parent: ids 211 to 223 are served');

-- ====== PART U: the owner's tick does not release a landed detach whose job it cannot read ======
create table public.rr194u (id bigint primary key, payload text);
insert into public.rr194u select g, 'u' from generate_series(231, 244) g;
select pgpm_formal.baseline('public.rr194u');
call pgpm.transmute('public.rr194u', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194u', '60000');
insert into public.rr194u values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194u', 'id = 50005');
create table public.rr194u_ref (id bigint primary key, p_id bigint references public.rr194u(id));
insert into public.rr194u_ref values (1, 50005);
select child_name as u_doomed from pgpm.part where parent_table = 'public.rr194u'::regclass and lo = '0' \gset
select format('alter table %s owner to pgpm_test194_owner', r) from (
  select 'public.rr194u'::regclass r union all select 'public.rr194u_ref'::regclass
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rr194u'::regclass) t \gexec
select ok(not pgpm.retire('public.rr194u', :'u_doomed'), 'fixture: (U) the administrator''s tick dispatches the detach');
select pgpm_test194.armed() as u_cmd \gset
select ok(pgpm_test194.cron_run(:'u_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194u', :'u_doomed'),
  'LIVENESS: (U) the administrator''s job lands the detach');
select pgpm.set_retain('public.rr194u', '45000');
set role pgpm_test194_owner;
select pgpm.retain('public.rr194u');
reset role;
select is(pgpm_test194.armed(), :'u_cmd', 'LIVENESS: (U) the administrator''s job still holds the detach after the owner''s tick');
select is(pgpm_test194.mark('public.rr194u', '0'), format('retiring_at set, dispatched %s', (select child_oid from pgpm.part where parent_table = 'public.rr194u'::regclass and lo = '0')),
  'U: the owner''s tick keeps the mark on the landed detach');
select ok(not ('retain_disown' = any(pgpm_test194.actions('public.rr194u', '0')))
          and (select method from pgpm.log where parent_table = 'public.rr194u'::regclass and lo = '0' and action = 'fail_retain_recall')
                ~ 'stays marked and out of the parent. Run maintenance as role postgres or a superuser',
  'U: releases nothing, and logs fail_retain_recall naming the role to run as');
call pgpm.maintain('public.rr194u');
select is(pgpm_test194.armed(), 'select 1', 'U: the administrator''s tick returns the job to idle');
select ok('retain_disown' = any(pgpm_test194.actions('public.rr194u', '0')) and pgpm_test194.accounted('public.rr194u', :'u_doomed', '0'),
  'U: and releases the table, logged out of the parent');
select is(pgpm_test194.ids(format('public.%I', :'u_doomed')), array(select generate_series(231, 244)::bigint), 'U: with ids 231 to 244');
alter table cron.job disable row level security;

-- ====== PART V: a superuser's tick waits out the idle on a mark with no record of pgpm's dispatch ======
create table public.rr194v (id bigint primary key, payload text);
insert into public.rr194v select g, 'v' from generate_series(251, 257) g;
select pgpm_formal.baseline('public.rr194v');
call pgpm.transmute('public.rr194v', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194v', '60000');
insert into public.rr194v values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194v', 'id = 50005');
create table public.rr194v_ref (id bigint primary key, p_id bigint references public.rr194v(id));
insert into public.rr194v_ref values (1, 50005);
select child_name as v_doomed, hi as v_hi from pgpm.part where parent_table = 'public.rr194v'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rr194v', :'v_doomed'), 'fixture: (V) the administrator''s tick dispatches the detach');
select pgpm_test194.armed() as v_cmd \gset
-- what an upgrade from v0.6.0 leaves when the role running it cannot read the job: the mark with no record
update pgpm.part set detach_dispatched_oid = null, retiring_by = null
 where parent_table = 'public.rr194v'::regclass and lo = '0';
select ok(pgpm_test194.mark('public.rr194v', '0') = 'retiring_at set, dispatched null'
          and (select retiring_by from pgpm.part where parent_table = 'public.rr194v'::regclass and lo = '0') is null,
  'LIVENESS: (V) the mark records no dispatch and no role');
begin;
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- pgpm.schedule() re-run: the job idled
select pgpm.set_retain('public.rr194v', '45000');
select ok(not pgpm_test194.reached('public.rr194v', :'v_hi'), 'LIVENESS: (V) retention no longer reaches the partition');
select is(pgpm_test194.armed(), 'select 1', 'LIVENESS: (V) the superuser''s recall will read the job idle');
select pgpm.retain('public.rr194v');
select is(pgpm_test194.mark('public.rr194v', '0'), 'retiring_at set, dispatched null',
  'V: the superuser''s recall that reads the idle in its own transaction keeps the unrecorded mark');
select is(pgpm_test194.idle_at('public.rr194v', '0'), 'stamped', 'V: and only stamps it');
select pgpm_test194.minute_passes('public.rr194v', '0');
commit;
call pgpm.maintain('public.rr194v');   -- the tick right after the commit, pg_cron's cache still holding the detach
select is(pgpm_test194.idle_at('public.rr194v', '0'), 'started', 'V: the tick right after the commit only starts the clock');
select is(pgpm_test194.mark('public.rr194v', '0'), 'retiring_at set, dispatched null', 'V: and keeps the mark');
select ok(pgpm_test194.cron_run(:'v_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194v', :'v_doomed'),
  'LIVENESS: (V) the run that carried the detach lands once the idle has committed');
call pgpm.maintain('public.rr194v');
select ok('retain_disown' = any(pgpm_test194.actions('public.rr194v', '0'))
          and pgpm_test194.mark('public.rr194v', '0') = 'retiring_at null, dispatched null',
  'V: the landed detach is logged out of the parent (retain_disown), never left behind a cleared mark unlogged');
select is(pgpm_test194.ids(format('public.%I', :'v_doomed')), array(select generate_series(251, 257)::bigint), 'V: with ids 251 to 257');

-- ====== PART W: a landed detach under an older mark with no record is not released by a role that cannot read the job ======
create table public.rr194w (id bigint primary key, payload text);
insert into public.rr194w select g, 'w' from generate_series(261, 266) g;
select pgpm_formal.baseline('public.rr194w');
call pgpm.transmute('public.rr194w', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194w', '60000');
insert into public.rr194w values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194w', 'id = 50005');
create table public.rr194w_ref (id bigint primary key, p_id bigint references public.rr194w(id));
insert into public.rr194w_ref values (1, 50005);
select child_name as w_doomed from pgpm.part where parent_table = 'public.rr194w'::regclass and lo = '0' \gset
select format('alter table %s owner to pgpm_test194_owner', r) from (
  select 'public.rr194w'::regclass r union all select 'public.rr194w_ref'::regclass
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rr194w'::regclass) t \gexec
select ok(not pgpm.retire('public.rr194w', :'w_doomed'), 'fixture: (W) the administrator''s tick dispatches the detach');
select pgpm_test194.armed() as w_cmd \gset
-- what an upgrade from v0.6.0 leaves when the role running it cannot read the job: the mark with no record
update pgpm.part set detach_dispatched_oid = null, retiring_by = null
 where parent_table = 'public.rr194w'::regclass and lo = '0';
select ok(pgpm_test194.cron_run(:'w_cmd') <> 'ERROR' and not pgpm_test194.attached('public.rr194w', :'w_doomed'),
  'LIVENESS: (W) the administrator''s job lands the detach');
set role pgpm_test194_owner;
select pgpm._disown_unvouched_retirements();   -- the install's pass, as the owner's upgrade runs it
reset role;
select is(pgpm_test194.mark('public.rr194w', '0'), 'retiring_at set, dispatched null', 'W: the owner''s install pass leaves the older mark');
select pgpm.set_retain('public.rr194w', '45000');
set role pgpm_test194_owner;
select pgpm.retain('public.rr194w');
reset role;
select is(pgpm_test194.armed(), :'w_cmd', 'LIVENESS: (W) the administrator''s job still holds the detach after the owner''s tick');
select is(pgpm_test194.mark('public.rr194w', '0'), 'retiring_at set, dispatched null', 'W: the owner''s tick keeps the mark on the landed detach');
select ok(not ('retain_disown' = any(pgpm_test194.actions('public.rr194w', '0')))
          and (select method from pgpm.log where parent_table = 'public.rr194w'::regclass and lo = '0' and action = 'fail_retain_recall')
                ~ 'which a detach a pgpm older than this release may have dispatched has taken out of the parent',
  'W: releases nothing, and logs fail_retain_recall saying an older pgpm may have dispatched it');
call pgpm.maintain('public.rr194w');
select is(pgpm_test194.armed(), 'select 1', 'W: the superuser''s tick returns the job to idle');
select ok('retain_disown' = any(pgpm_test194.actions('public.rr194w', '0'))
          and pgpm_test194.mark('public.rr194w', '0') = 'retiring_at null, dispatched null',
  'W: and releases the table');
select is(pgpm_test194.ids(format('public.%I', :'w_doomed')), array(select generate_series(261, 266)::bigint), 'W: with ids 261 to 266');

-- ====== PART X: retire() and the reap leave an older mark with no record to a role that can read the job ======
-- the job's run of the detach, parked in its wait phase behind a reader of the parent, then killed: a detach left
-- pending (tests/327's fixture)
create function pg_temp.park_detach(p_parent text, p_cmd text) returns boolean language plpgsql as $f$
begin
  perform dblink_connect('t194x_r', format('dbname=%s user=postgres application_name=t194x_reader', current_database()));
  perform dblink_connect('t194x_d', format('dbname=%s user=postgres application_name=t194x_detach', current_database()));
  perform dblink_exec('t194x_r', 'begin isolation level repeatable read');
  perform * from dblink('t194x_r', format('select count(*) from %s', p_parent)) as t(n bigint);
  perform dblink_send_query('t194x_d', p_cmd);
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where datname = current_database() and application_name = 't194x_detach'
                and wait_event_type = 'Lock' and wait_event = 'virtualxid') then
      return true;
    end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $f$;
create function pg_temp.kill_detach() returns boolean language plpgsql as $f$
declare v_gone boolean := false;
begin
  perform pg_terminate_backend(pid) from pg_stat_activity
    where datname = current_database() and application_name = 't194x_detach';
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if not exists (select 1 from pg_stat_activity where datname = current_database() and application_name = 't194x_detach') then
      v_gone := true;
      exit;
    end if;
    perform pg_sleep(0.05);
  end loop;
  perform dblink_disconnect('t194x_d');
  perform dblink_exec('t194x_r', 'commit');
  perform dblink_disconnect('t194x_r');
  return v_gone;
end $f$;
create table public.rr194x (id bigint primary key, payload text);
insert into public.rr194x select g, 'x' from generate_series(271, 275) g;
select pgpm_formal.baseline('public.rr194x');
call pgpm.transmute('public.rr194x', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194x', '60000');
insert into public.rr194x values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194x', 'id = 50005');
create table public.rr194x_ref (id bigint primary key, p_id bigint references public.rr194x(id));
insert into public.rr194x_ref values (1, 50005);
select child_name as x_doomed from pgpm.part where parent_table = 'public.rr194x'::regclass and lo = '0' \gset
select format('alter table %s owner to pgpm_test194_owner', r) from (
  select 'public.rr194x'::regclass r union all select 'public.rr194x_ref'::regclass
  union all select inhrelid::regclass from pg_inherits where inhparent = 'public.rr194x'::regclass) t \gexec
select ok(not pgpm.retire('public.rr194x', :'x_doomed'), 'fixture: (X) the administrator''s tick dispatches the detach');
select pgpm_test194.armed() as x_cmd \gset
update pgpm.part set detach_dispatched_oid = null, retiring_by = null
 where parent_table = 'public.rr194x'::regclass and lo = '0';
-- each step its own statement: the pending flag is committed by the detach's first transaction, after the snapshot
-- of any statement that started before it
select pg_temp.park_detach('public.rr194x', :'x_cmd') as x_parked \gset
select pg_temp.kill_detach() as x_killed \gset
select ok(:'x_parked' and :'x_killed'
          and exists (select 1 from pg_inherits where inhparent = 'public.rr194x'::regclass
                       and inhrelid = to_regclass(format('public.%I', :'x_doomed')) and inhdetachpending),
  'LIVENESS: (X) the job''s run of the detach was interrupted, leaving the partition pending');
set role pgpm_test194_owner;
select set_config('t194.x_pending', (pgpm.retire('public.rr194x', :'x_doomed'))::text, false);
reset role;
select ok(current_setting('t194.x_pending') = 'false'
          and pgpm_test194.mark('public.rr194x', '0') = 'retiring_at set, dispatched null'
          and (select method from pgpm.log where parent_table = 'public.rr194x'::regclass and lo = '0' order by id desc limit 1)
                ~ 'pending a concurrent detach under a retirement mark a pgpm older than this release may have dispatched',
  'X: the owner''s retire() keeps the older mark on the pending partition, refused');
set role pgpm_test194_owner;
select pgpm._detach_reap();
reset role;
select ok(not exists (select 1 from pg_inherits where inhparent = 'public.rr194x'::regclass
                       and inhrelid = to_regclass(format('public.%I', :'x_doomed'))),
  'LIVENESS: (X) the owner''s reap finished the detach');
select is(pgpm_test194.mark('public.rr194x', '0'), 'retiring_at set, dispatched null', 'X: and kept the older mark');
set role pgpm_test194_owner;
select set_config('t194.x_detached', (pgpm.retire('public.rr194x', :'x_doomed'))::text, false);
reset role;
select ok(current_setting('t194.x_detached') = 'false'
          and pgpm_test194.mark('public.rr194x', '0') = 'retiring_at set, dispatched null'
          and not ('retain_disown' = any(pgpm_test194.actions('public.rr194x', '0')))
          and (select action || ': ' || method from pgpm.log where parent_table = 'public.rr194x'::regclass and lo = '0' order by id desc limit 1)
                ~ '^fail_retain_drop: .* is detached from the parent under a retirement mark a pgpm older',
  'X: the owner''s retire() keeps it on the detached partition too, refused and counted');
select ok(not pgpm.retire('public.rr194x', :'x_doomed'), 'X: the superuser''s retire() does not drop it');
select is(pgpm_test194.armed(), 'select 1', 'X: it returns the job to idle');
select ok('retain_disown' = any(pgpm_test194.actions('public.rr194x', '0'))
          and pgpm_test194.mark('public.rr194x', '0') = 'retiring_at null, dispatched null',
  'X: and releases the table');
select is(pgpm_test194.ids(format('public.%I', :'x_doomed')), array(select generate_series(271, 275)::bigint), 'X: with ids 271 to 275');

-- ====== PART Y: a stamp past the cluster's xid counter is of no live transaction ======
create table public.rr194y (id bigint primary key, payload text);
insert into public.rr194y select g, 'y' from generate_series(281, 288) g;
select pgpm_formal.baseline('public.rr194y');
call pgpm.transmute('public.rr194y', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194y', '60000');
insert into public.rr194y values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194y', 'id = 50005');
create table public.rr194y_ref (id bigint primary key, p_id bigint references public.rr194y(id));
insert into public.rr194y_ref values (1, 50005);
select child_name as y_doomed from pgpm.part where parent_table = 'public.rr194y'::regclass and lo = '0' \gset
select ok(not pgpm.retire('public.rr194y', :'y_doomed'), 'fixture: (Y) the tick dispatches the detach');
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';
select pgpm.set_retain('public.rr194y', '45000');
select pgpm.retain('public.rr194y');
select is(pgpm_test194.idle_at('public.rr194y', '0'), 'stamped', 'LIVENESS: (Y) the recall stamped the mark');
-- pgpm.part restored from a dump taken during the wait, into a cluster whose xid counter is younger
update pgpm.part set recall_idle_xact = (pg_current_xact_id()::text::bigint + 100000000)::text::xid8
 where parent_table = 'public.rr194y'::regclass and lo = '0';
select pgpm.retain('public.rr194y');
select is(pgpm_test194.idle_at('public.rr194y', '0'), 'started', 'Y: the next tick starts the clock');
select is((select count(*) from pgpm.log where parent_table = 'public.rr194y'::regclass and action = 'skip_retain'), 0::bigint,
  'Y: and retain() did not fail');
select pgpm_test194.minute_passes('public.rr194y', '0');
select pgpm.retain('public.rr194y');
select ok(pgpm_test194.mark('public.rr194y', '0') = 'retiring_at null, dispatched null'
          and pgpm_test194.attached('public.rr194y', :'y_doomed') and pgpm_test194.ids('public.rr194y', 20000) = array(select generate_series(281, 288)::bigint),
  'Y: a minute on the mark is cleared, and the partition never left the parent: ids 281 to 288 are served');

-- ====== PART Z: with no pg_cron, an older mark with no record is cleared at once ======
alter schema cron rename to cron_aside;
create table public.rr194z (id bigint primary key, payload text);
insert into public.rr194z select g, 'z' from generate_series(291, 293) g;
select pgpm_formal.baseline('public.rr194z');
call pgpm.transmute('public.rr194z', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194z', '60000');
insert into public.rr194z values (50005, 'frontier');
select pgpm_formal.wrote('public.rr194z', 'id = 50005');
create table public.rr194z_ref (id bigint primary key, p_id bigint references public.rr194z(id));
insert into public.rr194z_ref values (1, 50005);
select child_name as z_doomed from pgpm.part where parent_table = 'public.rr194z'::regclass and lo = '0' \gset
select pgpm.retire('public.rr194z', :'z_doomed');
update pgpm.part set detach_dispatched_oid = null, retiring_by = null
 where parent_table = 'public.rr194z'::regclass and lo = '0';
select is(pgpm_test194.mark('public.rr194z', '0'), 'retiring_at set, dispatched null', 'LIVENESS: (Z) an older mark with no record, and no pg_cron');
select pgpm.set_retain('public.rr194z', '45000');
select pgpm.retain('public.rr194z');
select is(pgpm_test194.mark('public.rr194z', '0'), 'retiring_at null, dispatched null', 'Z: the first tick clears it: nothing can run a detach');
select ok(pgpm_test194.attached('public.rr194z', :'z_doomed') and pgpm_test194.ids('public.rr194z', 20000) = array[291, 292, 293]::bigint[],
  'Z: the partition never left the parent: ids 291, 292, 293 are served');
alter schema cron_aside rename to cron;

-- ====== PART AA: a role that reads cron.job but not its command is no reading (PR #1492, Codex P2) ======
alter table cron.job enable row level security;
insert into cron.job values (5, 'pgpm_detach', current_database(), 'select 1', 'pgpm_test194_owner');
set role pgpm_test194_owner;
create table public.rr194aa (id bigint primary key, payload text);
insert into public.rr194aa select g, 'aa' from generate_series(301, 306) g;
reset role;   -- the ledger is the test harness's, not the owner's
select pgpm_formal.baseline('public.rr194aa');
set role pgpm_test194_owner;
call pgpm.transmute('public.rr194aa', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('public.rr194aa', '60000');
insert into public.rr194aa values (50005, 'frontier');
create table public.rr194aa_ref (id bigint primary key, p_id bigint references public.rr194aa(id));
insert into public.rr194aa_ref values (1, 50005);
select child_name as aa_doomed from pgpm.part where parent_table = 'public.rr194aa'::regclass and lo = '0' \gset
select set_config('t194.aa_retire', (pgpm.retire('public.rr194aa', :'aa_doomed'))::text, false);
reset role;
select pgpm_formal.wrote('public.rr194aa', 'id = 50005');
select ok(current_setting('t194.aa_retire') = 'false'
          and (select command from cron.job where jobid = 5) ~ 'detach partition'
          and (select retiring_by::text from pgpm.part where parent_table = 'public.rr194aa'::regclass and lo = '0') = 'pgpm_test194_owner',
  'LIVENESS: (AA) the owner''s own tick dispatched the detach to its own job, recorded as its own');
-- the owner keeps SELECT on cron.job's other columns, not on its command: the table reads, the command does not
revoke select on cron.job from pgpm_test194_owner;
grant select (jobid, jobname, database, username) on cron.job to pgpm_test194_owner;
set role pgpm_test194_owner;
select lives_ok('select jobid from cron.job', 'LIVENESS: (AA) the owner reads cron.job');
select throws_ok('select command from cron.job', '42501', NULL, 'LIVENESS: (AA) and not its command');
reset role;
select pgpm.set_retain('public.rr194aa', '45000');
set role pgpm_test194_owner;
select pgpm.retain('public.rr194aa');
select pgpm.retain('public.rr194aa');
reset role;
select pgpm_test194.minute_passes('public.rr194aa', '0');
set role pgpm_test194_owner;
select pgpm.retain('public.rr194aa');
reset role;
select ok(pgpm_test194.mark('public.rr194aa', '0') ~ '^retiring_at set, dispatched [0-9]+$',
  'AA: a minute on, the owner''s ticks keep the mark: a read of the job that raised is no reading of it');
select ok((select count(*) from pgpm.log where parent_table = 'public.rr194aa'::regclass and action = 'fail_retain_recall') > 0,
  'AA: refused, counted');
select ok((select command from cron.job where jobid = 5) ~ 'detach partition', 'LIVENESS: (AA) the owner''s job still holds the detach');
revoke select (jobid, jobname, database, username) on cron.job from pgpm_test194_owner;
grant select on cron.job to pgpm_test194_owner;
delete from cron.job where jobid = 5;
alter table cron.job disable row level security;

select * from finish();
