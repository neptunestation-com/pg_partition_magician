-- An unanchored retirement mark is judged by the relation it marks, never by a squatter under its name, and one with
-- no oid at all is reported rather than skipped (issues #1429 and #1430).
--
-- THE GAPS. Both are older installs' rows, upgraded, whose retirement's detach landed and whose detached table the
-- operator renamed.
--   #1429  v0.5.0 recorded retiring_oid but neither child_oid nor detach_dispatched_oid. The pass every install.sql
--          run makes (_disown_unvouched_retirements) found such a row's relation by NAME, so a table created under
--          the old name after the rename was disowned as the retirement's ("detached from the parent"), and the
--          logged retain_disown remedy spelled an ATTACH of that squatter. The renamed retirement was never named.
--   #1430  v0.4.0 recorded the mark as retiring_at alone. With no oid to follow and nothing under the name, the
--          recall skipped the row on every tick and logged nothing: no retain_disown, no fail_retain_identity, the
--          mark kept and status() reporting retain_detaching 1 and retain_drop_failures 0 for good.
--
-- THE CONTRACT.
--   PART A  (#1429) a v0.5.0 row whose mark records the renamed table, with a squatter under the old name: the
--           install pass leaves it alone (nothing logged, the mark kept, neither table touched); the recall then
--           releases it by the recorded oid, its remedy naming the renamed table, never the squatter.
--   PART B  a v0.5.0 row whose mark and name agree (no rename): the install pass disowns it, as before, once,
--           its remedy naming the partition.
--   PART C  a v0.5.0 row whose mark records a NAMESAKE in another schema (#1365): the mark is on another relation
--           than the one under the name, so the install pass leaves it alone too (nothing logged, the mark kept,
--           neither table touched), and a later tick refuses it as exactly fail_retain_identity.
--   PART F  a v0.5.0 row whose detached retirement was MOVED to another schema under its own name, a squatter then
--           created under the name in the old one: catalog-alike to C, and left alone the same way, so the squatter
--           is never disowned in its place.
--   PART E  a v0.4.0 row, no oid at all, NOT renamed: nothing tells its detached table from one created under the
--           name since, so the install pass leaves it (nothing logged, the mark kept) for retire() and the recall
--           to refuse (#1432, tests/365).
--   PART G  a v0.4.0 row, no oid at all, whose partition is still ATTACHED with its detach armed in the job and not
--           yet run: the name denotes a partition of the parent, so the install pass still judges it and gives
--           it its dispatch record (detach_dispatched_oid), so the detach that lands is pgpm's own. Nothing logged.
--   PART D  (#1430) a v0.4.0 row, no oid at all, its detached table renamed: the recall logs exactly
--           fail_retain_identity, which status() counts, disarms the job, keeps the mark, and spells the repair
--           (rename back, ATTACH); run, the repair puts the rows back in the parent and the next tick clears the mark.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job and runs whatever the standing job holds at the top level, as tests/361 does.
--
-- ASYMMETRIC FIXTURES. Each part's doomed partition holds a different set of ids (A 1, 2, 3; B 5, 6; C 11, 12, 13,
-- 14; D 21; E 31, 32; F 41, 42; G 51, 52, 53), the squatters A 98 and F 97 and the namesake C 77, so a disown or re-attach of the wrong relation, or a lost
-- row, cannot stand in for the right answer.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(50);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');
create table cron.job_run_details (jobid bigint, runid bigserial, database text, username text, command text,
                                   status text, start_time timestamptz, end_time timestamptz);

create schema pgpm_t362;
create schema pgpm_t362_else;

create function pgpm_t362.ids(p_rel text, p_below bigint default null) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg(id order by id) from %s where id < %s', p_rel, coalesce(p_below, 9223372036854775807)) into v;
  return v;
end;
$$;
-- a run of the standing job, recorded in cron.job_run_details as pg_cron's launcher records one (#1438); \gexec runs it
create function pgpm_t362.ran() returns text language sql as $$
  insert into cron.job_run_details (jobid, database, username, command, status, start_time, end_time)
  select jobid, database, current_user, command, 'succeeded', clock_timestamp(), clock_timestamp()
    from cron.job where jobname = 'pgpm_detach'
  returning command
$$;
create function pgpm_t362.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
$$;
-- a partition of anything, BY OID: the answer cannot depend on a name
create function pgpm_t362.is_partition(p_oid oid) returns boolean language sql as $$
  select exists (select 1 from pg_inherits where inhrelid = p_oid)
$$;
create function pgpm_t362.actions(p_parent regclass, p_lo text) returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log
   where parent_table = p_parent and lo = p_lo
     and action in ('retain_detach', 'retain_recall', 'retain_reattach', 'fail_retain_reattach', 'retain_disown',
                    'retain_drop', 'fail_retain_drop', 'fail_retain_identity')
$$;
create function pgpm_t362.disown_method(p_parent regclass) returns text language sql as $$
  select method from pgpm.log where parent_table = p_parent and lo = '0' and action = 'retain_disown'
$$;

-- one referenced table per part, its detach dispatched and landed: monolith [0, 10000), frontier 50005, retain
-- 25000 puts the horizon at 20000; set_retain 45000 moves it to 0, past the partition's hi
create procedure pgpm_t362.landed(p_tab text, p_ids bigint[]) language plpgsql as $$
begin
  execute format('create table pgpm_t362.%I (id bigint primary key, payload text)', p_tab);
  execute format('insert into pgpm_t362.%I select i, ''row'' from unnest(%L::bigint[]) i', p_tab, p_ids);
  commit;
  call pgpm.transmute(format('pgpm_t362.%I', p_tab)::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
  perform pgpm.extend_to(format('pgpm_t362.%I', p_tab)::regclass, '60000');
  execute format('insert into pgpm_t362.%I values (50005, ''frontier'')', p_tab);
  execute format('create table public.%I (id bigint primary key, p_id bigint references pgpm_t362.%I(id))', p_tab || '_ref', p_tab);
  execute format('insert into public.%I values (1, 50005)', p_tab || '_ref');
end;
$$;

-- ========== the v0.5.0 and v0.4.0 rows, each detached by its retirement's own dispatched detach ==========
call pgpm_t362.landed('ua', array[1, 2, 3]);
call pgpm_t362.landed('ub', array[5, 6]);
call pgpm_t362.landed('uc', array[11, 12, 13, 14]);
call pgpm_t362.landed('ue', array[31, 32]);
call pgpm_t362.landed('uf', array[41, 42]);
call pgpm_t362.landed('ug', array[51, 52, 53]);
select child_name as a_doomed, child_oid as a_oid from pgpm.part where parent_table = 'pgpm_t362.ua'::regclass and lo = '0' \gset
select child_name as b_doomed, child_oid as b_oid from pgpm.part where parent_table = 'pgpm_t362.ub'::regclass and lo = '0' \gset
select child_name as c_doomed, child_oid as c_oid from pgpm.part where parent_table = 'pgpm_t362.uc'::regclass and lo = '0' \gset
select child_name as e_doomed, child_oid as e_oid from pgpm.part where parent_table = 'pgpm_t362.ue'::regclass and lo = '0' \gset
select child_name as f_doomed, child_oid as f_oid from pgpm.part where parent_table = 'pgpm_t362.uf'::regclass and lo = '0' \gset
select child_name as g_doomed, child_oid as g_oid from pgpm.part where parent_table = 'pgpm_t362.ug'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t362.ua', :'a_doomed'), 'fixture: (A) retire() dispatches the detach');
select pgpm_t362.armed() \gexec
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- the job idle again for the next part
select ok(not pgpm.retire('pgpm_t362.ub', :'b_doomed'), 'fixture: (B) retire() dispatches the detach');
select pgpm_t362.armed() \gexec
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- the job idle again for the next part
select ok(not pgpm.retire('pgpm_t362.uc', :'c_doomed'), 'fixture: (C) retire() dispatches the detach');
select pgpm_t362.armed() \gexec
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- the job idle again for the next part
select ok(not pgpm.retire('pgpm_t362.ue', :'e_doomed'), 'fixture: (E) retire() dispatches the detach');
select pgpm_t362.armed() \gexec
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- the job idle again for the next part
select ok(not pgpm.retire('pgpm_t362.uf', :'f_doomed'), 'fixture: (F) retire() dispatches the detach');
select pgpm_t362.armed() \gexec
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- the job idle again for the next part
select ok(not pgpm_t362.is_partition(:'a_oid'::oid) and not pgpm_t362.is_partition(:'b_oid'::oid)
          and not pgpm_t362.is_partition(:'c_oid'::oid) and not pgpm_t362.is_partition(:'e_oid'::oid)
          and not pgpm_t362.is_partition(:'f_oid'::oid),
  'LIVENESS: the five detaches landed: each partition is out of its parent');
-- G last: its detach dispatched and NOT run, so the job holds it through the install pass
select ok(not pgpm.retire('pgpm_t362.ug', :'g_doomed'), 'fixture: (G) retire() dispatches the detach');

-- the state a v0.5.0 install leaves (it had retiring_oid but neither child_oid nor detach_dispatched_oid)
update pgpm.part set child_oid = null, detach_dispatched_oid = null
 where parent_table in ('pgpm_t362.ua'::regclass, 'pgpm_t362.ub'::regclass, 'pgpm_t362.uc'::regclass,
                        'pgpm_t362.uf'::regclass) and lo = '0';
-- A: renamed, and a squatter created under the old name
select format('alter table pgpm_t362.%I rename to ua_kept', :'a_doomed') \gexec
select format('create table pgpm_t362.%I (id bigint, payload text)', :'a_doomed') \gexec
select format('insert into pgpm_t362.%I values (98, ''squat'')', :'a_doomed') \gexec
select to_regclass(format('pgpm_t362.%I', :'a_doomed'))::oid as a_squat \gset
-- C: an older retire() recorded a namesake in another schema as the mark's relation (#1365)
select format('create table pgpm_t362_else.%I (id bigint, payload text)', :'c_doomed') \gexec
select format('insert into pgpm_t362_else.%I values (77, ''namesake'')', :'c_doomed') \gexec
update pgpm.part set retiring_oid = to_regclass(format('pgpm_t362_else.%I', :'c_doomed'))::oid
 where parent_table = 'pgpm_t362.uc'::regclass and lo = '0';
-- F: moved to another schema under its own name, and a squatter created under the name in the old one
select format('alter table pgpm_t362.%I set schema pgpm_t362_else', :'f_doomed') \gexec
select format('create table pgpm_t362.%I (id bigint, payload text)', :'f_doomed') \gexec
select format('insert into pgpm_t362.%I values (97, ''squat'')', :'f_doomed') \gexec
select to_regclass(format('pgpm_t362.%I', :'f_doomed'))::oid as f_squat \gset
-- E, G: the state a v0.4.0 install leaves, retiring_at alone
update pgpm.part set child_oid = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table in ('pgpm_t362.ue'::regclass, 'pgpm_t362.ug'::regclass) and lo = '0';

select ok((select child_oid is null and detach_dispatched_oid is null and retiring_oid = :'a_oid'::oid from pgpm.part
            where parent_table = 'pgpm_t362.ua'::regclass and lo = '0'),
  'LIVENESS: (A) the row records the retirement by its mark alone, on the renamed table');
select is(pgpm._part_rel('pgpm_t362.ua', :'a_doomed')::oid, :'a_squat'::oid,
  'LIVENESS: (A) the name resolves to the squatter, so a by-name pass would judge it');
select ok((select child_oid is null and detach_dispatched_oid is null and retiring_oid = :'b_oid'::oid from pgpm.part
            where parent_table = 'pgpm_t362.ub'::regclass and lo = '0'),
  'LIVENESS: (B) the row records the retirement by its mark alone, on the table under its name');
select isnt((select retiring_oid from pgpm.part where parent_table = 'pgpm_t362.uc'::regclass and lo = '0'), :'c_oid'::oid,
  'LIVENESS: (C) the mark records another relation than the one under the name');
select ok((select retiring_oid = :'f_oid'::oid from pgpm.part where parent_table = 'pgpm_t362.uf'::regclass and lo = '0')
          and to_regclass(format('pgpm_t362_else.%I', :'f_doomed'))::oid = :'f_oid'::oid,
  'LIVENESS: (F) the mark records the moved table, which carries the row''s name in the other schema');

-- ========== the install pass, as an upgrade runs it ==========
select ok((select retiring_at is not null and retiring_oid is null and child_oid is null from pgpm.part
            where parent_table = 'pgpm_t362.ue'::regclass and lo = '0'),
  'LIVENESS: (E) the mark records no oid');
select ok((select retiring_at is not null and retiring_oid is null and child_oid is null and detach_dispatched_oid is null
             from pgpm.part where parent_table = 'pgpm_t362.ug'::regclass and lo = '0')
          and pgpm_t362.is_partition(:'g_oid'::oid)
          and pgpm_t362.armed() like format('%%detach partition%%%s%%', :'g_doomed'),
  'LIVENESS: (G) the mark records no oid, the partition is attached, and the job holds its detach');
select is(pgpm._disown_unvouched_retirements(), 1, 'the install pass disowned exactly one mark (B; not A, C, E or F)');

-- PART A: left alone
select is(pgpm_t362.actions('pgpm_t362.ua', '0'), array['retain_detach'],
  'A: the install pass logged nothing for the row (no retain_disown naming the squatter)');
select is((select retiring_oid from pgpm.part where parent_table = 'pgpm_t362.ua'::regclass and lo = '0'), :'a_oid'::oid,
  'A: the mark is kept, on the renamed table');
select is(pgpm_t362.ids(format('pgpm_t362.%I', :'a_doomed')), array[98]::bigint[], 'A: the squatter is untouched');
select ok(not pgpm_t362.is_partition(:'a_squat'::oid), 'A: and attached to nothing');
select is(pgpm_t362.ids('pgpm_t362.ua_kept'), array[1, 2, 3]::bigint[], 'A: the renamed table keeps its rows');

-- PART B: disowned as before
select is(pgpm_t362.actions('pgpm_t362.ub', '0'), array['retain_detach', 'retain_disown'],
  'B: the install pass disowned the row whose name agrees with its mark, logged as exactly retain_disown');
select ok(pgpm_t362.disown_method('pgpm_t362.ub') like format('%%attach partition pgpm_t362.%s for values%%', :'b_doomed'),
  'B: its remedy ATTACH names the partition');
select is((select retiring_at from pgpm.part where parent_table = 'pgpm_t362.ub'::regclass and lo = '0'), null,
  'B: the mark is cleared');

-- PART C: the namesake case, left alone
select is(pgpm_t362.actions('pgpm_t362.uc', '0'), array['retain_detach'],
  'C: the install pass logged nothing for the row whose mark records a namesake');
select isnt((select retiring_at from pgpm.part where parent_table = 'pgpm_t362.uc'::regclass and lo = '0'), null,
  'C: the mark is kept');
select is(pgpm_t362.ids(format('pgpm_t362_else.%I', :'c_doomed')), array[77]::bigint[], 'C: the namesake is untouched');
select is(pgpm_t362.ids(format('pgpm_t362.%I', :'c_doomed')), array[11, 12, 13, 14]::bigint[],
  'C: the partition under the name keeps its rows');

-- PART F: the moved retirement, left alone; the squatter never disowned in its place
select is(pgpm_t362.actions('pgpm_t362.uf', '0'), array['retain_detach'],
  'F: the install pass logged nothing for the row (no retain_disown naming the squatter)');
select is((select retiring_oid from pgpm.part where parent_table = 'pgpm_t362.uf'::regclass and lo = '0'), :'f_oid'::oid,
  'F: the mark is kept, on the moved table');
select is(pgpm_t362.ids(format('pgpm_t362.%I', :'f_doomed')), array[97]::bigint[], 'F: the squatter is untouched');
select is(pgpm_t362.ids(format('pgpm_t362_else.%I', :'f_doomed')), array[41, 42]::bigint[], 'F: the moved table keeps its rows');

-- PART E: a v0.4.0 mark out of the parent is left to the paths that refuse it (#1432)
select is(pgpm_t362.actions('pgpm_t362.ue', '0'), array['retain_detach'],
  'E: the install pass logged nothing for the v0.4.0 row');
select ok((select retiring_at is not null and retiring_oid is null and child_oid is null from pgpm.part
            where parent_table = 'pgpm_t362.ue'::regclass and lo = '0'),
  'E: the mark is kept, recording no oid');

-- PART G: a v0.4.0 mark on a partition still attached gets its dispatch record
select is((select detach_dispatched_oid from pgpm.part where parent_table = 'pgpm_t362.ug'::regclass and lo = '0'),
          :'g_oid'::oid, 'G: the install pass recorded the dispatch, on the attached partition');
select is(pgpm_t362.actions('pgpm_t362.ug', '0'), array['retain_detach'],
  'G: and logged nothing for the row (no retain_disown)');
select is(pgpm_t362.ids('pgpm_t362.ug'), array[51, 52, 53, 50005]::bigint[], 'G: the parent still reads the rows');
select pgpm_t362.armed() \gexec
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';   -- G's detach landed, the slot free for D

-- PART A, continued: the recall judges the row by its mark's oid
select pgpm.set_retain('pgpm_t362.ua', '45000');
select is(pgpm_t362.actions('pgpm_t362.ua', '0'), array['retain_detach', 'retain_disown'],
  'A: once retention no longer reaches it, the recall releases it, logged as exactly retain_disown');
select ok(pgpm_t362.disown_method('pgpm_t362.ua') like '%attach partition pgpm_t362.ua_kept for values%',
  'A: the release''s remedy ATTACH names the renamed table');
select ok(pgpm_t362.disown_method('pgpm_t362.ua') not like format('%%attach partition pgpm_t362.%s for values%%', :'a_doomed'),
  'A: and never the squatter');

-- ========== PART D: a v0.4.0 row, no oid at all, its detached table renamed ==========
call pgpm_t362.landed('ud', array[21]);
select child_name as d_doomed, child_oid as d_oid from pgpm.part where parent_table = 'pgpm_t362.ud'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t362.ud', :'d_doomed'), 'fixture: (D) retire() dispatches the detach');
select pgpm_t362.armed() as d_cmd \gset
select pgpm_t362.armed() \gexec
-- the state a v0.4.0 install leaves: retiring_at alone
update pgpm.part set child_oid = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'pgpm_t362.ud'::regclass and lo = '0';
select format('alter table pgpm_t362.%I rename to ud_kept', :'d_doomed') \gexec
select ok((select retiring_at is not null and child_oid is null and retiring_oid is null and detach_dispatched_oid is null
             from pgpm.part where parent_table = 'pgpm_t362.ud'::regclass and lo = '0')
          and to_regclass(format('pgpm_t362.%I', :'d_doomed')) is null,
  'LIVENESS: (D) the mark records no oid, and its name denotes nothing');
select is(pgpm_t362.armed(), :'d_cmd', 'LIVENESS: (D) the job still holds the detach');
select pgpm.set_retain('pgpm_t362.ud', '45000');
call pgpm.maintain('pgpm_t362.ud');
select is(pgpm_t362.actions('pgpm_t362.ud', '0'), array['retain_detach', 'fail_retain_identity'],
  'D: the recall refuses it, logged as exactly fail_retain_identity (never skipped silently)');
select is((select retain_drop_failures from pgpm.status() where parent = 'pgpm_t362.ud'::regclass), 1::bigint,
  'D: status() counts it');
select isnt((select retiring_at from pgpm.part where parent_table = 'pgpm_t362.ud'::regclass and lo = '0'), null,
  'D: the mark is kept');
select is(pgpm_t362.armed(), 'select 1', 'D: the job is disarmed');
select is(pgpm_t362.ids('pgpm_t362.ud_kept'), array[21]::bigint[], 'D: the renamed table keeps its row');

-- the repair the method spells, run as written
select format('alter table pgpm_t362.ud_kept rename to %I', :'d_doomed') \gexec
select substring(method from '(alter table \S+ attach partition [^;]*;)') from pgpm.log
 where parent_table = 'pgpm_t362.ud'::regclass and lo = '0' and action = 'fail_retain_identity' \gexec
call pgpm.maintain('pgpm_t362.ud');
-- #1438: the recall keeps the mark until pg_cron shows a run of the idle job started after a later tick saw it
select pgpm_t362.ran() \gexec
call pgpm.maintain('pgpm_t362.ud');
select pgpm_t362.ran() \gexec
call pgpm.maintain('pgpm_t362.ud');
select is((select retiring_at from pgpm.part where parent_table = 'pgpm_t362.ud'::regclass and lo = '0'), null,
  'D: once repaired, and pg_cron shows a run of the idle job since, a tick clears the mark');
select is(pgpm_t362.ids('pgpm_t362.ud', 100), array[21]::bigint[], 'D: and the row is served through the parent again');

-- PART C, continued, last (its tick retires the next partition, and one detach is in flight at a time): retention
-- still reaches it, and retire() judges the mark by its oid
call pgpm.maintain('pgpm_t362.uc');
select is(pgpm_t362.actions('pgpm_t362.uc', '0'), array['retain_detach', 'fail_retain_identity'],
  'C: a later tick refuses it as exactly fail_retain_identity, counted, never a disown of either table');

select * from finish();
