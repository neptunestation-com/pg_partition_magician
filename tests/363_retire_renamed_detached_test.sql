-- retire() RELEASES a detached retirement the operator renamed, while retention still reaches it, and from then on
-- refuses the row as a table detached by hand; it never drops it (issue #1427).
--
-- THE GAP. #1424 taught _retain_recall to release a detached retirement the operator renamed, once retention no
-- longer reaches it. While retention still does, retire() met the same table and refused it as
-- fail_retain_identity on every call: it resolves the partition by the name pgpm.part records, the name denotes
-- nothing now, and the message said "oid nothing" about a table whose identity was never in doubt, with the mark
-- kept and no word of where the rows were. Both paths now ask the same question (_renamed_retirement).
--
-- THE CONTRACT. Every part runs while retention REACHES the range (a liveness witness says so each time), so the
-- recall never runs and every effect below is retire()'s own.
--   PART A  pgpm's detach took the partition out and the operator renamed it: retire() releases it, logged once
--           as exactly retain_disown and then fail_retain_drop (never fail_retain_identity), the mark cleared and
--           the job idle; the table is not dropped and its rows are whole. A second call logs one more
--           fail_retain_drop and nothing else. The remedy the release spells (attach back, rename back) puts the
--           partition where retire() retires it again.
--   PART B  a squatter took the old name after the rename: the renamed table is released all the same, and the
--           squatter is neither dropped nor attached.
--   PART D  the operator detached the partition by hand, with no retirement mark, and renamed it: there is no mark
--           to release, and it is refused as one detached by hand (fail_retain_drop), not as an identity failure.
--   PART E  the row has no child_oid (an older install's: v0.5.0 recorded retiring_oid only) and a squatter took
--           the old name: the release's remedy ATTACH names the renamed table by the oid the mark recorded, never
--           the squatter.
--   PART F  the recorded relation is GONE (dropped after its detach): nothing stands to hand over, so the
--           identity failure stands, the mark kept.
--   PART C  the partition was renamed while still ATTACHED (its detach dispatched, never run): it is no detached
--           retirement, so it is refused as before (fail_retain_identity), left attached and the mark kept. Last,
--           because its armed detach holds the database's one detach slot.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job and runs whatever the standing job holds at the top level, as tests/361 does.
--
-- ASYMMETRIC FIXTURES. Each part's doomed partition holds a different set of ids (A 1, 2; B 5, 6, 7; C 21, 22;
-- D 31, 32, 33, 34; E 41, 42, 43; F 11), and the squatters B 99 and E 98, so a drop of the wrong relation or a
-- lost row cannot stand in for the right answer.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(60);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

create schema pgpm_t363;

create function pgpm_t363.ids(p_rel text, p_below bigint default null) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg(id order by id) from %s where id < %s', p_rel, coalesce(p_below, 9223372036854775807)) into v;
  return v;
end;
$$;
create function pgpm_t363.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
$$;
-- a partition of anything, BY OID: the answer cannot depend on a name
create function pgpm_t363.is_partition(p_oid oid) returns boolean language sql as $$
  select exists (select 1 from pg_inherits where inhrelid = p_oid)
$$;
create function pgpm_t363.reached(p_parent regclass, p_hi text) returns boolean language sql as $$
  select not pgpm._native_gt(c.control_kind, p_hi, pgpm._retain_boundary(c))
    from pgpm.config c where c.parent_table = p_parent
$$;
create function pgpm_t363.actions(p_parent regclass, p_lo text) returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log
   where parent_table = p_parent and lo = p_lo
     and action in ('retain_detach', 'retain_recall', 'retain_reattach', 'fail_retain_reattach', 'retain_disown',
                    'retain_drop', 'fail_retain_drop', 'fail_retain_identity')
$$;
create function pgpm_t363.method(p_parent regclass, p_action text) returns text language sql as $$
  select method from pgpm.log where parent_table = p_parent and lo = '0' and action = p_action order by id desc limit 1
$$;

-- one referenced table per part: monolith [0, 10000), frontier 50005, retain 25000 puts the horizon at 20000, so
-- retention reaches [0, 10000) and a call of retire() on it dispatches a detach
create procedure pgpm_t363.landed(p_tab text, p_ids bigint[]) language plpgsql as $$
begin
  execute format('create table pgpm_t363.%I (id bigint primary key, payload text)', p_tab);
  execute format('insert into pgpm_t363.%I select i, ''row'' from unnest(%L::bigint[]) i', p_tab, p_ids);
  commit;
  call pgpm.transmute(format('pgpm_t363.%I', p_tab)::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
  perform pgpm.extend_to(format('pgpm_t363.%I', p_tab)::regclass, '60000');
  execute format('insert into pgpm_t363.%I values (50005, ''frontier'')', p_tab);
  execute format('create table public.%I (id bigint primary key, p_id bigint references pgpm_t363.%I(id))', p_tab || '_ref', p_tab);
  execute format('insert into public.%I values (1, 50005)', p_tab || '_ref');
end;
$$;

-- ========== PART A: the detached retirement, renamed by the operator, is released (the issue's reproduction) ==========
call pgpm_t363.landed('ra', array[1, 2]);
select child_name as a_doomed, hi as a_hi, child_oid as a_oid from pgpm.part
 where parent_table = 'pgpm_t363.ra'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t363.ra', :'a_doomed'), 'fixture: (A) retire() dispatches the detach');
select pgpm_t363.armed() \gexec
select ok(not pgpm_t363.is_partition(:'a_oid'::oid), 'LIVENESS: (A) pgpm''s detach landed: the partition is out of the parent');
select format('alter table pgpm_t363.%I rename to ra_kept', :'a_doomed') \gexec
select is(to_regclass('pgpm_t363.ra_kept')::oid, :'a_oid'::oid, 'LIVENESS: (A) the operator renamed the detached table');
select is(to_regclass(format('pgpm_t363.%I', :'a_doomed')), null, 'LIVENESS: (A) the recorded name denotes nothing now');
select isnt((select retiring_at from pgpm.part where parent_table = 'pgpm_t363.ra'::regclass and lo = '0'), null,
  'LIVENESS: (A) the retirement mark is still on the row');
select isnt(pgpm_t363.armed(), 'select 1', 'LIVENESS: (A) the standing job still holds the landed detach');
select ok(pgpm_t363.reached('pgpm_t363.ra', :'a_hi'), 'LIVENESS: (A) retention reaches the partition');

-- the call runs with the table's schema ON the search_path, where a regclass renders unqualified: the methods
-- must name the new name schema-qualified all the same
set search_path = pgpm_t363, public;
select ok(not pgpm.retire('pgpm_t363.ra', :'a_doomed'), 'A: retire() does not drop it');
reset search_path;
select is(pgpm_t363.actions('pgpm_t363.ra', '0'), array['retain_detach', 'retain_disown', 'fail_retain_drop'],
  'A: released and refused as detached by hand, logged as exactly retain_detach, retain_disown, fail_retain_drop');
select is((select retiring_at from pgpm.part where parent_table = 'pgpm_t363.ra'::regclass and lo = '0'), null,
  'A: the retirement mark is cleared');
select is(pgpm_t363.armed(), 'select 1', 'A: the standing job is idle');
select ok(pgpm_t363.method('pgpm_t363.ra', 'retain_disown') like format('%%renamed to pgpm_t363.ra_kept (oid %s)%%', :'a_oid'),
  'A: the release names the table''s new name, schema-qualified though its schema is on the search_path, and oid');
select ok(pgpm_t363.method('pgpm_t363.ra', 'retain_disown') like '%Retention reaches its range%',
  'A: and spells the remedy for a range retention reaches');
select ok(pgpm_t363.method('pgpm_t363.ra', 'fail_retain_drop') like format('%%renamed to pgpm_t363.ra_kept (oid %s)%%', :'a_oid'),
  'A: the refusal names where the table is now');
select is(pgpm_t363.ids('pgpm_t363.ra_kept'), array[1, 2]::bigint[], 'A: the table stands, its rows, ids 1 and 2, whole');

select ok(not pgpm.retire('pgpm_t363.ra', :'a_doomed'), 'A: a second call does not drop it either');
select is(pgpm_t363.actions('pgpm_t363.ra', '0'), array['retain_detach', 'retain_disown', 'fail_retain_drop', 'fail_retain_drop'],
  'A: it logs one more fail_retain_drop and nothing else: the release is logged once, and never an identity failure');
select is(pgpm_t363.ids('pgpm_t363.ra_kept'), array[1, 2]::bigint[], 'A: ids 1 and 2 are still whole');

-- the remedy the release spells is the operator's to run, and it works: attached back and renamed back, the
-- partition is retire()'s to retire again
-- (no retain_disown row: a statement that fails, so the file runs on to its count rather than stopping here)
select coalesce(substring(pgpm_t363.method('pgpm_t363.ra', 'retain_disown') from 'alter table [^;]* attach partition [^;]*;'),
                'select ''no remedy ATTACH'' :: int') as a_attach \gset
select coalesce(substring(pgpm_t363.method('pgpm_t363.ra', 'retain_disown') from 'alter table [^;]* rename to [^;]*;'),
                'select ''no remedy rename'' :: int') as a_rename \gset
select lives_ok(:'a_attach', 'A: the remedy''s ATTACH runs');
select lives_ok(:'a_rename', 'A: the remedy''s rename back runs');
select is(pgpm_t363.ids('pgpm_t363.ra', 20000), array[1, 2]::bigint[], 'A: ids 1 and 2 are served through the parent again');
select ok(not pgpm.retire('pgpm_t363.ra', :'a_doomed'), 'A: retire() after the remedy');
select is(pgpm_t363.actions('pgpm_t363.ra', '0'),
          array['retain_detach', 'retain_disown', 'fail_retain_drop', 'fail_retain_drop', 'retain_detach'],
  'A: after the remedy, retire() dispatches the partition''s detach again, refusing nothing');
-- the job back to idle for the next part (its detach is not run: A's partition stays attached)
update cron.job set command = 'select 1';
update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'pgpm_t363.ra'::regclass and lo = '0';

-- ========== PART B: a squatter took the old name; the renamed table is released all the same ==========
call pgpm_t363.landed('rb', array[5, 6, 7]);
select child_name as b_doomed, hi as b_hi, child_oid as b_oid from pgpm.part
 where parent_table = 'pgpm_t363.rb'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t363.rb', :'b_doomed'), 'fixture: (B) retire() dispatches the detach');
select pgpm_t363.armed() \gexec
select format('alter table pgpm_t363.%I rename to rb_kept', :'b_doomed') \gexec
select format('create table pgpm_t363.%I (id bigint, payload text)', :'b_doomed') \gexec
select format('insert into pgpm_t363.%I values (99, ''squat'')', :'b_doomed') \gexec
select format('pgpm_t363.%I', :'b_doomed') as b_squat \gset
select isnt(to_regclass(:'b_squat')::oid, :'b_oid'::oid, 'LIVENESS: (B) the old name denotes a different relation now');
select ok(pgpm_t363.reached('pgpm_t363.rb', :'b_hi'), 'LIVENESS: (B) retention reaches the partition');

select ok(not pgpm.retire('pgpm_t363.rb', :'b_doomed'), 'B: retire() drops nothing');
select is(pgpm_t363.actions('pgpm_t363.rb', '0'), array['retain_detach', 'retain_disown', 'fail_retain_drop'],
  'B: the renamed table is released, logged as exactly retain_detach, retain_disown, fail_retain_drop');
select is(pgpm_t363.armed(), 'select 1', 'B: the standing job, which named the squatter''s name, is idle');
select is(pgpm_t363.ids('pgpm_t363.rb_kept'), array[5, 6, 7]::bigint[], 'B: the renamed table keeps ids 5, 6, 7');
select is(pgpm_t363.ids(:'b_squat'), array[99]::bigint[], 'B: the squatter is left alone');
select ok(not pgpm_t363.is_partition(to_regclass(:'b_squat')::oid), 'B: and not attached');
update cron.job set command = 'select 1';

-- ========== PART D: detached by hand with no mark, and renamed; refused as detached by hand ==========
call pgpm_t363.landed('rd', array[31, 32, 33, 34]);
select child_name as d_doomed, hi as d_hi, child_oid as d_oid from pgpm.part
 where parent_table = 'pgpm_t363.rd'::regclass and lo = '0' \gset
select format('alter table pgpm_t363.rd detach partition pgpm_t363.%I', :'d_doomed') \gexec
select format('alter table pgpm_t363.%I rename to rd_mine', :'d_doomed') \gexec
select ok(not pgpm_t363.is_partition(:'d_oid'::oid) and to_regclass('pgpm_t363.rd_mine')::oid = :'d_oid'::oid,
  'LIVENESS: (D) the operator detached the partition and renamed it');
select is((select retiring_at from pgpm.part where parent_table = 'pgpm_t363.rd'::regclass and lo = '0'), null,
  'LIVENESS: (D) no retirement mark is on the row');
select ok(pgpm_t363.reached('pgpm_t363.rd', :'d_hi'), 'LIVENESS: (D) retention reaches the partition');
select ok(not pgpm.retire('pgpm_t363.rd', :'d_doomed'), 'D: retire() drops nothing');
select is(pgpm_t363.actions('pgpm_t363.rd', '0'), array['fail_retain_drop'],
  'D: refused as exactly fail_retain_drop: detached by hand, not an identity failure, and nothing to release');
select is(pgpm_t363.ids('pgpm_t363.rd_mine'), array[31, 32, 33, 34]::bigint[], 'D: the table keeps ids 31 to 34');

-- ========== PART E: an older install's row, no child_oid; the remedy names the renamed table, not the squatter ==========
call pgpm_t363.landed('re', array[41, 42, 43]);
select child_name as e_doomed, hi as e_hi, child_oid as e_oid from pgpm.part
 where parent_table = 'pgpm_t363.re'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t363.re', :'e_doomed'), 'fixture: (E) retire() dispatches the detach');
select pgpm_t363.armed() \gexec
-- the state a v0.5.0 install leaves (it had retiring_oid but neither child_oid nor detach_dispatched_oid)
update pgpm.part set child_oid = null, detach_dispatched_oid = null
 where parent_table = 'pgpm_t363.re'::regclass and lo = '0';
select format('alter table pgpm_t363.%I rename to re_kept', :'e_doomed') \gexec
select format('create table pgpm_t363.%I (id bigint, payload text)', :'e_doomed') \gexec
select format('insert into pgpm_t363.%I values (98, ''squat'')', :'e_doomed') \gexec
select ok((select child_oid is null and retiring_oid = :'e_oid'::oid from pgpm.part
            where parent_table = 'pgpm_t363.re'::regclass and lo = '0'),
  'LIVENESS: (E) the row records the retirement by its mark alone, child_oid null');
select ok(pgpm_t363.reached('pgpm_t363.re', :'e_hi'), 'LIVENESS: (E) retention reaches the partition');
select ok(not pgpm.retire('pgpm_t363.re', :'e_doomed'), 'E: retire() drops nothing');
select is(pgpm_t363.actions('pgpm_t363.re', '0'), array['retain_detach', 'retain_disown', 'fail_retain_drop'],
  'E: the renamed table is released, logged as exactly retain_detach, retain_disown, fail_retain_drop');
select ok(pgpm_t363.method('pgpm_t363.re', 'retain_disown') like '%attach partition pgpm_t363.re_kept for values%',
  'E: the remedy ATTACH names the renamed table, by the oid the mark recorded');
select ok(pgpm_t363.method('pgpm_t363.re', 'retain_disown') not like format('%%attach partition pgpm_t363.%s for values%%', :'e_doomed'),
  'E: and never the squatter that holds the old name');
select is(pgpm_t363.ids('pgpm_t363.re_kept'), array[41, 42, 43]::bigint[], 'E: the renamed table keeps ids 41, 42, 43');
select is(pgpm_t363.ids(format('pgpm_t363.%I', :'e_doomed')), array[98]::bigint[], 'E: the squatter is left alone');
update cron.job set command = 'select 1';

-- ========== PART F: the recorded relation is gone; the identity failure stands ==========
call pgpm_t363.landed('rf', array[11]);
select child_name as f_doomed, hi as f_hi, child_oid as f_oid from pgpm.part
 where parent_table = 'pgpm_t363.rf'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t363.rf', :'f_doomed'), 'fixture: (F) retire() dispatches the detach');
select pgpm_t363.armed() \gexec
select format('drop table pgpm_t363.%I', :'f_doomed') \gexec
select ok(not exists (select 1 from pg_class where oid = :'f_oid'::oid), 'LIVENESS: (F) the detached table was dropped by hand');
select ok(pgpm_t363.reached('pgpm_t363.rf', :'f_hi'), 'LIVENESS: (F) retention reaches the partition');
select ok(not pgpm.retire('pgpm_t363.rf', :'f_doomed'), 'F: retire() returns false');
select is(pgpm_t363.actions('pgpm_t363.rf', '0'), array['retain_detach', 'fail_retain_identity'],
  'F: with nothing standing to hand over, it is refused as exactly fail_retain_identity');
select isnt((select retiring_at from pgpm.part where parent_table = 'pgpm_t363.rf'::regclass and lo = '0'), null,
  'F: and the mark is kept');
update cron.job set command = 'select 1';

-- ========== PART C: renamed while still attached; no detached retirement to hand over ==========
call pgpm_t363.landed('rc', array[21, 22]);
select child_name as c_doomed, hi as c_hi, child_oid as c_oid from pgpm.part
 where parent_table = 'pgpm_t363.rc'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t363.rc', :'c_doomed'), 'fixture: (C) retire() dispatches the detach');
select format('alter table pgpm_t363.%I rename to rc_renamed', :'c_doomed') \gexec
select ok(pgpm_t363.is_partition(:'c_oid'::oid), 'LIVENESS: (C) the renamed partition is still attached (the detach never ran)');
select ok(pgpm_t363.reached('pgpm_t363.rc', :'c_hi'), 'LIVENESS: (C) retention reaches the partition');
select ok(not pgpm.retire('pgpm_t363.rc', :'c_doomed'), 'C: retire() returns false');
select is(pgpm_t363.actions('pgpm_t363.rc', '0'), array['retain_detach', 'fail_retain_identity'],
  'C: an attached partition renamed is refused as exactly fail_retain_identity, not released');
select isnt((select retiring_at from pgpm.part where parent_table = 'pgpm_t363.rc'::regclass and lo = '0'), null,
  'C: the mark is kept');
select is(pgpm_t363.ids('pgpm_t363.rc', 20000), array[21, 22]::bigint[], 'C: ids 21, 22 are still served through the parent');

select * from finish();
