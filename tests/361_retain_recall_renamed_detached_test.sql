-- Loosened retention RELEASES a detached retirement the operator renamed; it never re-attaches it (issue #1424).
--
-- THE GAP. _retain_recall (#724) takes back a retirement retention no longer reaches. It resolves the partition
-- by the name pgpm.part records, so once pgpm's detach had taken the partition out of the parent and the operator
-- renamed the detached table, the recall found nothing under the name and logged fail_retain_identity, again on
-- every tick, with the mark kept: a wedge that said "identity" about a table whose identity was never in doubt,
-- and no word of where its rows were. The formal model's question Q1 (docs/formal/record.md) asked what a hand
-- rename of a retirement in custody means; the maintainer decided it hands the table to the operator.
--
-- THE CONTRACT.
--   PART A  the recorded relation stands detached under another name: the recall releases it, logged once as
--           exactly retain_disown (never fail_retain_identity), the mark cleared and the job idle; the table is
--           NOT re-attached, by set_retain or by any later tick, and its rows are whole; the method names the
--           new name and spells the ATTACH that would put it back, which works when run.
--   PART B  a squatter took the old name after the rename: the renamed table is released all the same, and the
--           squatter is neither attached nor touched.
--   PART C  the recorded relation is GONE (dropped after its detach): nothing stands to hand over, so the
--           identity failure stands, as before.
--   PART D  the partition was renamed while still ATTACHED: it is no detached retirement, so it is refused as
--           before (fail_retain_identity), left attached and the mark kept (tests/204 part C, with a squatter).
--   PART E  the two anchors disagree (a mark recorded on another relation than the row's): the relation the mark
--           names is not handed over on its say alone; refused as before.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job and runs whatever the standing job holds at the top level, as tests/204 does.
--
-- ASYMMETRIC FIXTURES. Each part's doomed partition holds a different set of ids (A 1, 2; B 5, 6, 7; C 11;
-- D 21, 22; E 31, and E's foreign table 77), and B's squatter 99, so a re-attach of the wrong relation or a lost
-- row cannot stand in for the right answer.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(41);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

create schema pgpm_t361;

create function pgpm_t361.ids(p_rel text, p_below bigint default null) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg(id order by id) from %s where id < %s', p_rel, coalesce(p_below, 9223372036854775807)) into v;
  return v;
end;
$$;
create function pgpm_t361.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
$$;
-- a partition of anything, BY OID: the answer cannot depend on a name
create function pgpm_t361.is_partition(p_oid oid) returns boolean language sql as $$
  select exists (select 1 from pg_inherits where inhrelid = p_oid)
$$;
create function pgpm_t361.reached(p_parent regclass, p_hi text) returns boolean language sql as $$
  select not pgpm._native_gt(c.control_kind, p_hi, pgpm._retain_boundary(c))
    from pgpm.config c where c.parent_table = p_parent
$$;
create function pgpm_t361.actions(p_parent regclass, p_lo text) returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log
   where parent_table = p_parent and lo = p_lo
     and action in ('retain_detach', 'retain_recall', 'retain_reattach', 'fail_retain_reattach', 'retain_disown',
                    'retain_drop', 'fail_retain_drop', 'fail_retain_identity')
$$;

-- one referenced table per part, its detach dispatched and landed: monolith [0, 10000), frontier 50005, retain
-- 25000 puts the horizon at 20000; set_retain 45000 moves it to 0, past the partition's hi
create procedure pgpm_t361.landed(p_tab text, p_ids bigint[]) language plpgsql as $$
begin
  execute format('create table pgpm_t361.%I (id bigint primary key, payload text)', p_tab);
  execute format('insert into pgpm_t361.%I select i, ''row'' from unnest(%L::bigint[]) i', p_tab, p_ids);
  commit;
  call pgpm.transmute(format('pgpm_t361.%I', p_tab)::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
  perform pgpm.extend_to(format('pgpm_t361.%I', p_tab)::regclass, '60000');
  execute format('insert into pgpm_t361.%I values (50005, ''frontier'')', p_tab);
  execute format('create table public.%I (id bigint primary key, p_id bigint references pgpm_t361.%I(id))', p_tab || '_ref', p_tab);
  execute format('insert into public.%I values (1, 50005)', p_tab || '_ref');
end;
$$;

-- ========== PART A: the detached retirement, renamed by the operator, is released (the issue's reproduction) ==========
call pgpm_t361.landed('ra', array[1, 2]);
select child_name as a_doomed, hi as a_hi, child_oid as a_oid from pgpm.part
 where parent_table = 'pgpm_t361.ra'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t361.ra', :'a_doomed'), 'fixture: (A) retire() dispatches the detach');
select pgpm_t361.armed() \gexec
select ok(not pgpm_t361.is_partition(:'a_oid'::oid), 'LIVENESS: (A) pgpm''s detach landed: the partition is out of the parent');
select format('alter table pgpm_t361.%I rename to ra_kept', :'a_doomed') \gexec
select is(to_regclass('pgpm_t361.ra_kept')::oid, :'a_oid'::oid, 'LIVENESS: (A) the operator renamed the detached table');
select is(to_regclass(format('pgpm_t361.%I', :'a_doomed')), null, 'LIVENESS: (A) the recorded name denotes nothing now');
select isnt((select retiring_at from pgpm.part where parent_table = 'pgpm_t361.ra'::regclass and lo = '0'), null,
  'LIVENESS: (A) the retirement mark is still on the row');

select pgpm.set_retain('pgpm_t361.ra', '45000');
select ok(not pgpm_t361.reached('pgpm_t361.ra', :'a_hi'), 'LIVENESS: (A) retention no longer reaches the partition');
select is(pgpm_t361.actions('pgpm_t361.ra', '0'), array['retain_detach', 'retain_disown'],
  'A: the recall released it, logged as exactly retain_detach, retain_disown (no fail_retain_identity)');
select is((select retiring_at from pgpm.part where parent_table = 'pgpm_t361.ra'::regclass and lo = '0'), null,
  'A: the retirement mark is cleared');
select is(pgpm_t361.armed(), 'select 1', 'A: the standing job is idle');
select ok((select method from pgpm.log where parent_table = 'pgpm_t361.ra'::regclass and lo = '0' and action = 'retain_disown')
            like format('%%renamed to pgpm_t361.ra_kept (oid %s)%%', :'a_oid'),
  'A: the method names the table''s new name and oid');

call pgpm.maintain('pgpm_t361.ra');
call pgpm.maintain('pgpm_t361.ra');
select ok(not pgpm_t361.is_partition(:'a_oid'::oid), 'A: two ticks later the renamed table is still not re-attached');
select is(pgpm_t361.actions('pgpm_t361.ra', '0'), array['retain_detach', 'retain_disown'],
  'A: and nothing more was logged for it: the release is logged once, not every tick');
select is(pgpm_t361.ids('pgpm_t361.ra_kept'), array[1, 2]::bigint[], 'A: its rows, ids 1 and 2, are whole');
select is(pgpm_t361.ids('pgpm_t361.ra', 20000), null::bigint[], 'A: and not served through the parent');
select results_eq($$ select retain_drop_failures from pgpm.status() where parent = 'pgpm_t361.ra'::regclass $$,
  $$ values (0::bigint) $$, 'A: status() counts no failure');

-- the remedy the method spells is the operator's to run, and it works
-- (no retain_disown row: a statement that fails, so the file runs on to its count rather than stopping here)
select coalesce((select substring(method from 'alter table [^;]* attach partition [^;]*;') from pgpm.log
                  where parent_table = 'pgpm_t361.ra'::regclass and lo = '0' and action = 'retain_disown'),
                'select ''no retain_disown row, so no remedy'' :: int') as a_attach \gset
select ok(:'a_attach' like '%attach partition pgpm_t361.ra_kept %', 'A: the remedy''s ATTACH names the renamed table');
select lives_ok(:'a_attach', 'A: the remedy''s ATTACH runs');
select is(pgpm_t361.ids('pgpm_t361.ra', 20000), array[1, 2]::bigint[], 'A: and serves ids 1 and 2 through the parent again');

-- ========== PART B: a squatter took the old name; the renamed table is released all the same ==========
call pgpm_t361.landed('rb', array[5, 6, 7]);
select child_name as b_doomed, hi as b_hi, child_oid as b_oid from pgpm.part
 where parent_table = 'pgpm_t361.rb'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t361.rb', :'b_doomed'), 'fixture: (B) retire() dispatches the detach');
select pgpm_t361.armed() \gexec
select format('alter table pgpm_t361.%I rename to rb_kept', :'b_doomed') \gexec
select format('create table pgpm_t361.%I (id bigint, payload text)', :'b_doomed') \gexec
select format('insert into pgpm_t361.%I values (99, ''squat'')', :'b_doomed') \gexec
select format('pgpm_t361.%I', :'b_doomed') as b_squat \gset
select isnt(to_regclass(:'b_squat')::oid, :'b_oid'::oid, 'LIVENESS: (B) the old name denotes a different relation now');

select pgpm.set_retain('pgpm_t361.rb', '45000');
call pgpm.maintain('pgpm_t361.rb');
select ok(not pgpm_t361.reached('pgpm_t361.rb', :'b_hi'), 'LIVENESS: (B) retention no longer reaches the partition');
select is(pgpm_t361.actions('pgpm_t361.rb', '0'), array['retain_detach', 'retain_disown'],
  'B: the renamed table is released, logged as exactly retain_detach, retain_disown');
select ok(not pgpm_t361.is_partition(:'b_oid'::oid), 'B: the renamed table is not re-attached');
select ok(not pgpm_t361.is_partition(to_regclass(:'b_squat')::oid), 'B: nor is the squatter');
select is(pgpm_t361.ids('pgpm_t361.rb_kept'), array[5, 6, 7]::bigint[], 'B: the renamed table keeps ids 5, 6, 7');
select is(pgpm_t361.ids(:'b_squat'), array[99]::bigint[], 'B: the squatter is left alone');

-- ========== PART C: the recorded relation is gone; the identity failure stands ==========
call pgpm_t361.landed('rc', array[11]);
select child_name as c_doomed, hi as c_hi, child_oid as c_oid from pgpm.part
 where parent_table = 'pgpm_t361.rc'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t361.rc', :'c_doomed'), 'fixture: (C) retire() dispatches the detach');
select pgpm_t361.armed() \gexec
select format('drop table pgpm_t361.%I', :'c_doomed') \gexec
select ok(not exists (select 1 from pg_class where oid = :'c_oid'::oid), 'LIVENESS: (C) the detached table was dropped by hand');

select pgpm.set_retain('pgpm_t361.rc', '45000');
select ok(not pgpm_t361.reached('pgpm_t361.rc', :'c_hi'), 'LIVENESS: (C) retention no longer reaches the partition');
select is(pgpm_t361.actions('pgpm_t361.rc', '0'), array['retain_detach', 'fail_retain_identity'],
  'C: with nothing standing to hand over, it is refused as exactly fail_retain_identity');
select isnt((select retiring_at from pgpm.part where parent_table = 'pgpm_t361.rc'::regclass and lo = '0'), null,
  'C: and the mark is kept');

-- ========== PART D: renamed while still attached; no detached retirement to hand over ==========
call pgpm_t361.landed('rd', array[21, 22]);
select child_name as d_doomed, hi as d_hi, child_oid as d_oid from pgpm.part
 where parent_table = 'pgpm_t361.rd'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t361.rd', :'d_doomed'), 'fixture: (D) retire() dispatches the detach');
select format('alter table pgpm_t361.%I rename to rd_renamed', :'d_doomed') \gexec
select ok(pgpm_t361.is_partition(:'d_oid'::oid), 'LIVENESS: (D) the renamed partition is still attached (the detach never ran)');
select pgpm.set_retain('pgpm_t361.rd', '45000');
select ok(not pgpm_t361.reached('pgpm_t361.rd', :'d_hi'), 'LIVENESS: (D) retention no longer reaches the partition');
select is(pgpm_t361.actions('pgpm_t361.rd', '0'), array['retain_detach', 'fail_retain_identity'],
  'D: an attached partition renamed is refused as exactly fail_retain_identity, not released');
select isnt((select retiring_at from pgpm.part where parent_table = 'pgpm_t361.rd'::regclass and lo = '0'), null,
  'D: the mark is kept');
select is(pgpm_t361.ids('pgpm_t361.rd', 20000), array[21, 22]::bigint[], 'D: ids 21, 22 are still served through the parent');

-- ========== PART E: the anchors disagree; the relation the mark names is not handed over on its say alone ==========
call pgpm_t361.landed('re', array[31]);
select child_name as e_doomed, hi as e_hi, child_oid as e_oid from pgpm.part
 where parent_table = 'pgpm_t361.re'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t361.re', :'e_doomed'), 'fixture: (E) retire() dispatches the detach');
create table pgpm_t361.re_foreign (id bigint, payload text);
insert into pgpm_t361.re_foreign values (77, 'foreign');
update pgpm.part set retiring_oid = 'pgpm_t361.re_foreign'::regclass
 where parent_table = 'pgpm_t361.re'::regclass and lo = '0';
select isnt((select retiring_oid from pgpm.part where parent_table = 'pgpm_t361.re'::regclass and lo = '0'), :'e_oid'::oid,
  'LIVENESS: (E) the mark names another relation than the row''s anchor, one that stands detached');
select pgpm.set_retain('pgpm_t361.re', '45000');
select is(pgpm_t361.actions('pgpm_t361.re', '0'), array['retain_detach', 'fail_retain_identity'],
  'E: refused as exactly fail_retain_identity, the foreign relation not released');
select is(pgpm_t361.ids('pgpm_t361.re_foreign'), array[77]::bigint[], 'E: the foreign relation is untouched');

select * from finish();
