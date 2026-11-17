-- Loosened retention settles a retirement on a MOVED parent, in the partition's own schema (issues #778, #1438).
--
-- THE BUG. _retain_recall (#724) resolved a retiring partition as <the parent's CURRENT schema>.<child_name>
-- and built the detach command it disarms the same way, the one lifecycle step #727 left on the parent's
-- schema. ALTER TABLE <parent> SET SCHEMA moves the parent and leaves every partition where it was (pgpm
-- tracks the parent by oid, and docs/guide.md says the move is safe). retire() arms the standing pgpm_detach
-- job with <partition's own schema>.<child>, so after the move a loosening set_retain found nothing under
-- the parent's schema, logged fail_retain_identity ("oid nothing now"), and its conditional disarm named a
-- command the job did not hold: the detach stayed armed, pg_cron took the partition out of the parent, and
-- no tick put it back. The rows the loosened policy keeps vanished from every read of the parent and writes
-- into their range were refused.
--
-- THE CONTRACT. After the parent moves, _retain_recall works exactly as on an unmoved parent (tests/194):
--   PART A  set_retain leaves the dispatched detach armed (#1438: a dispatched detach is never taken back). Once
--           it lands, the tick idles the job and releases the table: retain_disown naming the partition in its own
--           schema, with the ATTACH that puts it back under the parent's new name, and fail_retain_reattach,
--           counted. The remedy's ATTACH, run as written, serves the rows again.
--   PART B  a run carrying the detach that lands after the tick finds nothing pgpm put back: the rows stay in
--           the released table, recorded as out of the parent.
--   PART C  the identity anchor still holds in the partition's own schema: a relation squatting on the
--           retiring partition's name there is refused (fail_retain_identity), the job is disarmed, and
--           neither the squatter nor the renamed partition is touched.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job and runs whatever the standing job holds at the top level, as tests/194 does.
--
-- ASYMMETRIC FIXTURES. Each part's doomed partition holds a different set of ids (A 1, 2, 3; B 5, 6, 7, 8;
-- C 11, 12), so a re-attach of the wrong relation, a lost row or a resurrected one cannot stand in for the
-- right answer.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

select plan(33);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

create schema pgpm_t204_old;
create schema pgpm_t204_new;

-- the ids a relation holds below a bound, null when it does not exist (a results_eq over a missing table
-- would raise and take the rest of the file with it, hiding the assertion count the guard checks)
create function pgpm_t204_old.ids(p_rel text, p_below bigint default null) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg(id order by id) from %s where id < %s', p_rel, coalesce(p_below, 9223372036854775807)) into v;
  return v;
end;
$$;
-- a pg_cron run: the command in a session of its own, top level as pg_cron sends it; its error (a late run of a
-- detach that has nothing left to take out) comes back as text rather than ending this file
create function pgpm_t204_old.cron_run(p_cmd text) returns text language sql as $$
  select case when p_cmd = 'select 1' then 'idle'   -- the idle job's command returns a row, which dblink_exec refuses
              else dblink_exec(format('dbname=%s user=postgres', current_database()), p_cmd, false) end
$$;
create function pgpm_t204_old.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
$$;
-- attached BY OID, so the answer cannot depend on which schema a name is looked up in
create function pgpm_t204_old.attached(p_parent regclass, p_oid oid) returns boolean language sql as $$
  select exists (select 1 from pg_inherits where inhparent = p_parent and inhrelid = p_oid and not inhdetachpending)
$$;
create function pgpm_t204_old.nsp_of(p_oid oid) returns text language sql as $$
  select n.nspname::text from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_oid
$$;
create function pgpm_t204_old.reached(p_parent regclass, p_hi text) returns boolean language sql as $$
  select not pgpm._native_gt(c.control_kind, p_hi, pgpm._retain_boundary(c))
    from pgpm.config c where c.parent_table = p_parent
$$;
create function pgpm_t204_old.actions(p_parent regclass, p_lo text) returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log
   where parent_table = p_parent and lo = p_lo
     and action in ('retain_detach', 'retain_recall', 'retain_reattach', 'fail_retain_reattach', 'retain_disown',
                    'retain_drop', 'fail_retain_drop', 'fail_retain_identity')
$$;

-- ========== PART A: on a moved parent, set_retain recalls the armed detach (the issue's reproduction) ==========
-- monolith [0, 10000) holds 1, 2, 3; the frontier at 50005 puts the retain 25000 horizon at 20000. The
-- referencing row points at the live frontier row, so nothing stops the detach.
create table pgpm_t204_old.rra (id bigint primary key, payload text);
insert into pgpm_t204_old.rra values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('pgpm_t204_old.rra', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t204_old.rra', '60000');
insert into pgpm_t204_old.rra values (50005, 'frontier');
create table public.rr204a_ref (id bigint primary key, p_id bigint references pgpm_t204_old.rra(id));
insert into public.rr204a_ref values (1, 50005);
select child_name as a_doomed, hi as a_hi, child_oid as a_oid from pgpm.part
 where parent_table = 'pgpm_t204_old.rra'::regclass and lo = '0' \gset

alter table pgpm_t204_old.rra set schema pgpm_t204_new;
select is(pgpm_t204_old.nsp_of(:'a_oid'::oid), 'pgpm_t204_old', 'LIVENESS: (A) the parent moved and its partition stayed in the old schema');

select ok(not pgpm.retire('pgpm_t204_new.rra', :'a_doomed'), 'fixture: (A) retire() dispatches the detach and returns false');
select is(pgpm_t204_old.armed(), format('alter table pgpm_t204_new.rra detach partition pgpm_t204_old.%I concurrently', :'a_doomed'),
  'LIVENESS: (A) the standing job is armed with the partition''s detach, named in its own schema');

select pgpm_t204_old.armed() as a_cmd \gset
select pgpm.set_retain('pgpm_t204_new.rra', '45000');   -- horizon 20000 -> 0
select ok(not pgpm_t204_old.reached('pgpm_t204_new.rra', :'a_hi'), 'LIVENESS: (A) after loosening, retention no longer reaches the partition');
select is(pgpm_t204_old.armed(), :'a_cmd', 'A: set_retain leaves the dispatched detach armed');
select is(pgpm_t204_old.actions('pgpm_t204_new.rra', '0'), array['retain_detach'], 'A: with no identity failure logged');

-- pg_cron's next run: whatever the standing job holds, at the top level; then a tick
select command from cron.job where jobname = 'pgpm_detach' \gexec
select ok(not pgpm_t204_old.attached('pgpm_t204_new.rra', :'a_oid'::oid), 'LIVENESS: (A) the detach landed');
call pgpm.maintain('pgpm_t204_new.rra');

select is(pgpm_t204_old.actions('pgpm_t204_new.rra', '0'), array['retain_detach', 'retain_disown', 'fail_retain_reattach'],
  'A: the release is logged as exactly retain_disown, then fail_retain_reattach');
select coalesce((select method from pgpm.log where parent_table = 'pgpm_t204_new.rra'::regclass and lo = '0' and action = 'retain_disown'), '') as a_method \gset
select ok(:'a_method' like format('retention no longer reaches pgpm_t204_old.%s (horizon 0)%%', :'a_doomed'),
  'A: the release names the partition in its own schema');
select ok(position(format('alter table pgpm_t204_new.rra attach partition pgpm_t204_old.%I for values from (''0'') to (''10000'');', :'a_doomed')
                   in :'a_method') > 0, 'A: and gives the ATTACH under the parent''s new name');
select is(pgpm_t204_old.armed(), 'select 1', 'A: the standing job is back to idle');
select is(pgpm_t204_old.ids(format('pgpm_t204_old.%I', :'a_doomed')), array[1, 2, 3]::bigint[], 'A: the released table keeps ids 1, 2, 3');
select is((select retiring_at from pgpm.part where parent_table = 'pgpm_t204_new.rra'::regclass and child_name = :'a_doomed'),
  null, 'A: the retiring marker is cleared');
select results_eq($$ select retain_drop_failures, retain_detaching from pgpm.status() where parent = 'pgpm_t204_new.rra'::regclass $$,
  $$ values (1::bigint, 0::bigint) $$, 'A: status() counts the release, with nothing detaching');
select substring(:'a_method' from 'alter table [^;]* attach partition [^;]*;') \gexec
select is(pgpm_t204_old.ids('pgpm_t204_new.rra', 20000), array[1, 2, 3]::bigint[], 'A: the remedy''s ATTACH serves ids 1, 2, 3 through the parent again');

-- ====== PART B: on a moved parent, a late run of the detach finds nothing pgpm put back ======
create table pgpm_t204_old.rrb (id bigint primary key, payload text);
insert into pgpm_t204_old.rrb values (5, 'e'), (6, 'f'), (7, 'g'), (8, 'h');
call pgpm.transmute('pgpm_t204_old.rrb', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t204_old.rrb', '60000');
insert into pgpm_t204_old.rrb values (50005, 'frontier');
create table public.rr204b_ref (id bigint primary key, p_id bigint references pgpm_t204_old.rrb(id));
insert into public.rr204b_ref values (1, 50005);
select child_name as b_doomed, hi as b_hi, child_oid as b_oid from pgpm.part
 where parent_table = 'pgpm_t204_old.rrb'::regclass and lo = '0' \gset

alter table pgpm_t204_old.rrb set schema pgpm_t204_new;
select ok(not pgpm.retire('pgpm_t204_new.rrb', :'b_doomed'), 'fixture: (B) retire() dispatches the detach');
select pgpm_t204_old.armed() as b_cmd \gset
select is(:'b_cmd', format('alter table pgpm_t204_new.rrb detach partition pgpm_t204_old.%I concurrently', :'b_doomed'),
  'LIVENESS: (B) the job holds this partition''s detach, in its own schema');
-- pgpm's own run lands
select :'b_cmd' \gexec
select ok(not pgpm_t204_old.attached('pgpm_t204_new.rrb', :'b_oid'::oid), 'LIVENESS: (B) the detach landed: the partition left the parent');
select pgpm.set_retain('pgpm_t204_new.rrb', '45000');
select ok(not pgpm_t204_old.reached('pgpm_t204_new.rrb', :'b_hi'), 'LIVENESS: (B) retention no longer reaches the partition');
call pgpm.maintain('pgpm_t204_new.rrb');
-- the run pg_cron started on that cadence, with the command it had already read, lands after the tick
select pgpm_t204_old.cron_run(:'b_cmd');
select ok(not pgpm_t204_old.attached('pgpm_t204_new.rrb', :'b_oid'::oid), 'B: pgpm re-attached nothing for the late run to take out');
select ok(exists (select 1 from pgpm.log where parent_table = 'pgpm_t204_new.rrb'::regclass and lo = '0' and action = 'fail_retain_reattach'),
  'B: and the range is recorded as out of the parent');
select is(pgpm_t204_old.nsp_of(:'b_oid'::oid), 'pgpm_t204_old', 'B: the released table is still in its own schema');
select is(pgpm_t204_old.ids(format('pgpm_t204_old.%I', :'b_doomed')), array[5, 6, 7, 8]::bigint[], 'B: and keeps ids 5, 6, 7, 8');
select is(pgpm_t204_old.actions('pgpm_t204_new.rrb', '0'), array['retain_detach', 'retain_disown', 'fail_retain_reattach'],
  'B: logged as exactly retain_detach, retain_disown, fail_retain_reattach');

-- ====== PART C: the identity anchor still holds in the partition's own schema on a moved parent ======
create table pgpm_t204_old.rrc (id bigint primary key, payload text);
insert into pgpm_t204_old.rrc values (11, 'k'), (12, 'l');
call pgpm.transmute('pgpm_t204_old.rrc', 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t204_old.rrc', '60000');
insert into pgpm_t204_old.rrc values (50005, 'frontier');
create table public.rr204c_ref (id bigint primary key, p_id bigint references pgpm_t204_old.rrc(id));
insert into public.rr204c_ref values (1, 50005);
select child_name as c_doomed, hi as c_hi, child_oid as c_oid from pgpm.part
 where parent_table = 'pgpm_t204_old.rrc'::regclass and lo = '0' \gset

alter table pgpm_t204_old.rrc set schema pgpm_t204_new;
select ok(not pgpm.retire('pgpm_t204_new.rrc', :'c_doomed'), 'fixture: (C) retire() dispatches the detach');
-- the partition is renamed aside and something else takes its name, in the partition's own schema
select format('alter table pgpm_t204_old.%I rename to rr204c_aside', :'c_doomed') \gexec
select format('create table pgpm_t204_old.%I (id bigint, payload text)', :'c_doomed') \gexec
select format('insert into pgpm_t204_old.%I values (99, ''squat'')', :'c_doomed') \gexec
select format('pgpm_t204_old.%I', :'c_doomed') as c_squat \gset
select isnt(to_regclass(:'c_squat')::oid, :'c_oid'::oid, 'LIVENESS: (C) the name now resolves to a different relation in the partition''s schema');
select is(pgpm_t204_old.armed(), format('alter table pgpm_t204_new.rrc detach partition pgpm_t204_old.%I concurrently', :'c_doomed'),
  'LIVENESS: (C) the standing job is armed with the detach of that name');

select pgpm.set_retain('pgpm_t204_new.rrc', '45000');
select ok(not pgpm_t204_old.reached('pgpm_t204_new.rrc', :'c_hi'), 'LIVENESS: (C) retention no longer reaches the partition');
select is(pgpm_t204_old.actions('pgpm_t204_new.rrc', '0'), array['retain_detach', 'fail_retain_identity'],
  'C: the substituted name is refused as exactly fail_retain_identity');
select is(pgpm_t204_old.armed(), 'select 1', 'C: and the command naming the squatter is disarmed');
select ok(pgpm_t204_old.attached('pgpm_t204_new.rrc', :'c_oid'::oid), 'C: the renamed partition is left attached');
select is(pgpm_t204_old.ids('pgpm_t204_new.rrc', 20000), array[11, 12]::bigint[], 'C: ids 11, 12 are still readable through the parent');
select is(pgpm_t204_old.ids(:'c_squat'), array[99]::bigint[], 'C: the squatter is left alone, outside the parent');

select * from finish();
