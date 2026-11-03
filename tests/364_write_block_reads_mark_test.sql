-- The write-block step anchors an older install's row by its retirement mark, and lifts a block it put on an
-- operator's table under the row's old name (issue #1435).
--
-- THE GAP. v0.5.0 recorded a retirement's oid in retiring_oid alone, so its row has no child_oid. The write-block
-- step compared a name against child_oid only, so for such a row whose detached retirement the operator renamed, a
-- plain table of the operator's under the old name was taken for the partition and blocked. maintain() runs that
-- step before retain(), so the block went on in the first tick; retire()'s release (#1427) then anchored the row,
-- the step skipped it as detached by hand from then on, and the block was never lifted: writes to the operator's
-- unrelated table refused for good.
--
-- THE CONTRACT.
--   PART A  maintain()'s own step order over three ticks: the operator's table is never blocked and stays
--           writable, the step logs exactly one fail_write_block_identity naming the mark's oid, and the renamed
--           table keeps its rows.
--   PART B  the operator's table already carries the block an earlier tick put on it: one tick lifts it, says so
--           in the refusal, and the table is writable again.
--   PART D  an impostor ATTACHED to the parent under the name: refused, and a block on it is kept (a relation
--           under the parent is not the operator's own table, as under #429).
--   PART E  coverage recorded for the renamed table is not discarded because the operator's table under the name
--           carries no block (#518's rule, by the mark's oid).
--   PART C  the control: a marked row with no child_oid whose name still denotes the marked partition is
--           write-blocked as before. Last, because its mark holds the database's one retirement slot.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job and runs whatever the standing job holds at the top level, as tests/363 does.
--
-- ASYMMETRIC FIXTURES. Each part's doomed partition holds a different set of ids (A 1, 2; B 5, 6, 7; C 21, 22;
-- D 31, 32, 33; E 41, 42, 43, 44), the operator's tables A 98, B 99 and E 95, and the impostor D 37, 38, so a write
-- to the wrong relation or a lost row cannot stand in for the right answer.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(37);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

create schema pgpm_t364;

create function pgpm_t364.ids(p_rel text) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg(id order by id) from %s where id < 10000', p_rel) into v;
  return v;
end;
$$;
create function pgpm_t364.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
$$;
create function pgpm_t364.blocked(p_rel text) returns boolean language sql as $$
  select exists (select 1 from pg_trigger where tgrelid = to_regclass(p_rel) and tgname = 'pgpm_write_block')
$$;
-- the block an earlier tick put on the operator's table, as _install_write_block lays it
create function pgpm_t364.lay_block(p_rel text) returns void language plpgsql as $$
begin
  execute format('create trigger pgpm_write_block before insert or update or delete on %s'
                 || ' for each row execute function pgpm._write_block_raise()', p_rel);
  execute format('alter table %s enable always trigger pgpm_write_block', p_rel);
end;
$$;
create function pgpm_t364.reaches(p_parent regclass) returns boolean language sql as $$
  select not pgpm._native_gt(c.control_kind, '10000', pgpm._retain_boundary(c)) from pgpm.config c where c.parent_table = p_parent
$$;

-- ============================================================================================================
-- PART A: maintain() over three ticks never blocks the operator's table under the old name
-- ============================================================================================================
create table pgpm_t364.a (id bigint primary key, payload text);
insert into pgpm_t364.a values (1, 'orig'), (2, 'orig');
call pgpm.transmute('pgpm_t364.a'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.a'::regclass, '60000');
insert into pgpm_t364.a values (35005, 'frontier');
create table public.a364_ref (id bigint primary key, p_id bigint references pgpm_t364.a(id));
insert into public.a364_ref values (1, 35005);
select child_name as a_doomed, child_oid as a_oid from pgpm.part where parent_table = 'pgpm_t364.a'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t364.a', :'a_doomed') and pgpm_t364.armed() <> 'select 1', 'A fixture: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
-- the row an older install left: the mark's oid alone
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.a'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to a_kept', :'a_doomed') \gexec
select format('create table pgpm_t364.%I (id bigint, payload text)', :'a_doomed') \gexec
select format('insert into pgpm_t364.%I values (98, ''mine'')', :'a_doomed') \gexec
select format('pgpm_t364.%I', :'a_doomed') as a_sq \gset
select is(pgpm._disown_unvouched_retirements(), 0, 'A GUARD: the upgrade''s pass leaves the row''s mark');
select ok((select child_oid is null and retiring_oid = :'a_oid'::oid and attached from pgpm.part
            where parent_table = 'pgpm_t364.a'::regclass and lo = '0'),
  'A LIVENESS: the row is attached and records the retirement by its mark alone');
select ok(not exists (select 1 from pg_inherits where inhrelid = to_regclass(:'a_sq')::oid),
  'A LIVENESS: a plain table of the operator''s, no partition, holds the old name');
select ok(pgpm_t364.reaches('pgpm_t364.a'), 'A LIVENESS: retention reaches the range, so the step would block it');
call pgpm.maintain('pgpm_t364.a');
call pgpm.maintain('pgpm_t364.a');
call pgpm.maintain('pgpm_t364.a');
-- the ticks dispatched the next partition's detach into the database's one detach slot; free it for the parts below
update cron.job set command = 'select 1';
select ok(exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.a'::regclass and lo = '0' and action = 'retain_disown'),
  'A LIVENESS: retain() reached the row and released it');
select ok(not pgpm_t364.blocked(:'a_sq'), 'A: the operator''s table carries no write block');
select lives_ok(format('insert into %s values (97, ''mine'')', :'a_sq'), 'A: the operator can write to their table');
select is(pgpm_t364.ids(:'a_sq'), array[97, 98]::bigint[], 'A: the operator''s table holds exactly its own rows');
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'pgpm_t364.a'::regclass and lo = '0' and action like '%write_block%'),
          array['fail_write_block_identity'],
  'A: the step logs exactly one refusal for the row, and nothing else about its block');
select ok((select method like '%not the oid ' || :'a_oid' || ' pgpm''s retirement recorded%' from pgpm.log
            where parent_table = 'pgpm_t364.a'::regclass and lo = '0' and action = 'fail_write_block_identity'),
  'A: the refusal names the oid the mark recorded');
select is(pgpm_t364.ids('pgpm_t364.a_kept'), array[1, 2]::bigint[], 'A: the renamed table keeps ids 1, 2');

-- ============================================================================================================
-- PART B: a block an earlier tick put on the operator's table is lifted
-- ============================================================================================================
create table pgpm_t364.b (id bigint primary key, payload text);
insert into pgpm_t364.b values (5, 'orig'), (6, 'orig'), (7, 'orig');
call pgpm.transmute('pgpm_t364.b'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.b'::regclass, '60000');
insert into pgpm_t364.b values (35005, 'frontier');
create table public.b364_ref (id bigint primary key, p_id bigint references pgpm_t364.b(id));
insert into public.b364_ref values (1, 35005);
select child_name as b_doomed, child_oid as b_oid from pgpm.part where parent_table = 'pgpm_t364.b'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t364.b', :'b_doomed') and pgpm_t364.armed() <> 'select 1', 'B fixture: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.b'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to b_kept', :'b_doomed') \gexec
select format('create table pgpm_t364.%I (id bigint, payload text)', :'b_doomed') \gexec
select format('insert into pgpm_t364.%I values (99, ''mine'')', :'b_doomed') \gexec
select format('pgpm_t364.%I', :'b_doomed') as b_sq \gset
select pgpm_t364.lay_block(:'b_sq');
select throws_like(format('insert into %s values (96, ''mine'')', :'b_sq'), '%past its retention boundary%',
  'B LIVENESS: the operator''s table is blocked before the tick');
select ok(pgpm_t364.reaches('pgpm_t364.b'), 'B LIVENESS: retention reaches the range');
call pgpm.maintain('pgpm_t364.b');
update cron.job set command = 'select 1';
select ok(not pgpm_t364.blocked(:'b_sq'), 'B: the block is lifted from the operator''s table');
select lives_ok(format('insert into %s values (96, ''mine'')', :'b_sq'), 'B: the operator can write to their table again');
select is(pgpm_t364.ids(:'b_sq'), array[96, 99]::bigint[], 'B: the operator''s table holds exactly its own rows');
select ok((select bool_and(method like '%lifting the write block an earlier tick put on it%') from pgpm.log
            where parent_table = 'pgpm_t364.b'::regclass and lo = '0' and action = 'fail_write_block_identity')
          and exists (select 1 from pgpm.log
                       where parent_table = 'pgpm_t364.b'::regclass and lo = '0' and action = 'fail_write_block_identity'),
  'B: the refusal says it lifted the block');
select is(pgpm_t364.ids('pgpm_t364.b_kept'), array[5, 6, 7]::bigint[], 'B: the renamed table keeps ids 5, 6, 7');

-- ============================================================================================================
-- PART D: an impostor attached under the name is refused, and its block is kept
-- ============================================================================================================
create table pgpm_t364.d (id bigint primary key, payload text);
insert into pgpm_t364.d values (31, 'orig'), (32, 'orig'), (33, 'orig');
call pgpm.transmute('pgpm_t364.d'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.d'::regclass, '60000');
insert into pgpm_t364.d values (35005, 'frontier');
create table public.d364_ref (id bigint primary key, p_id bigint references pgpm_t364.d(id));
insert into public.d364_ref values (1, 35005);
select child_name as d_doomed, child_oid as d_oid from pgpm.part where parent_table = 'pgpm_t364.d'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t364.d', :'d_doomed') and pgpm_t364.armed() <> 'select 1', 'D fixture: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.d'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to d_kept', :'d_doomed') \gexec
select format('create table pgpm_t364.%I (id bigint primary key, payload text)', :'d_doomed') \gexec
select format('insert into pgpm_t364.%I values (37, ''impostor''), (38, ''impostor'')', :'d_doomed') \gexec
select format('alter table pgpm_t364.d attach partition pgpm_t364.%I for values from (0) to (10000)', :'d_doomed') \gexec
select format('pgpm_t364.%I', :'d_doomed') as d_imp \gset
select pgpm_t364.lay_block(:'d_imp');
select ok(exists (select 1 from pg_inherits where inhparent = 'pgpm_t364.d'::regclass and inhrelid = to_regclass(:'d_imp')::oid),
  'D LIVENESS: the impostor is a partition of the parent, by oid');
select ok(pgpm_t364.blocked(:'d_imp'), 'D LIVENESS: the impostor carries a block');
select pgpm._install_write_block('pgpm_t364.d'::regclass, :'d_doomed');
select ok(exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.d'::regclass and lo = '0' and action = 'fail_write_block_identity'),
  'D: the impostor is refused');
select ok(pgpm_t364.blocked(:'d_imp'), 'D: the impostor keeps its block');
select ok(not exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.d'::regclass and lo = '0'
                       and action = 'fail_write_block_identity' and method like '%lifting%'),
  'D: the refusal lifts nothing');
select is(pgpm_t364.ids('pgpm_t364.d_kept'), array[31, 32, 33]::bigint[], 'D: the renamed table keeps ids 31, 32, 33');

-- ============================================================================================================
-- PART E: coverage recorded for the renamed table is not discarded because the operator's table is unblocked
-- ============================================================================================================
create table pgpm_t364.e (id bigint primary key, payload text);
insert into pgpm_t364.e values (41, 'orig'), (42, 'orig'), (43, 'orig'), (44, 'orig');
call pgpm.transmute('pgpm_t364.e'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.e'::regclass, '60000');
insert into pgpm_t364.e values (35005, 'frontier');
create table public.e364_ref (id bigint primary key, p_id bigint references pgpm_t364.e(id));
insert into public.e364_ref values (1, 35005);
select child_name as e_doomed, child_oid as e_oid from pgpm.part where parent_table = 'pgpm_t364.e'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t364.e', :'e_doomed') and pgpm_t364.armed() <> 'select 1', 'E fixture: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.e'::regclass and lo = '0';
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid)
  values ('pgpm_t364.e'::regclass, '0', '5000', :'e_doomed', 4, :'e_oid'::oid);
select format('alter table pgpm_t364.%I rename to e_kept', :'e_doomed') \gexec
select format('create table pgpm_t364.%I (id bigint, payload text)', :'e_doomed') \gexec
select format('insert into pgpm_t364.%I values (95, ''mine'')', :'e_doomed') \gexec
select format('pgpm_t364.%I', :'e_doomed') as e_sq \gset
select ok(not pgpm_t364.blocked(:'e_sq'), 'E LIVENESS: the table under the name carries no block, so coverage looks unguarded');
select ok(pgpm_t364.reaches('pgpm_t364.e'), 'E LIVENESS: retention reaches the range');
select pgpm._enforce_write_blocks('pgpm_t364.e'::regclass);
select ok(not exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.e'::regclass and action = 'archive_coverage_reset'),
  'E: no coverage is discarded');
select is((select array_agg(hi) from pgpm.archive_ledger
            where parent_table = 'pgpm_t364.e'::regclass and child_oid = :'e_oid'::oid and retired_at is null),
          array['5000'], 'E: the renamed table''s chunk is still recorded');
select ok(not pgpm_t364.blocked(:'e_sq'), 'E: the operator''s table is not blocked');

-- ============================================================================================================
-- PART C: control, a marked row with no child_oid whose name still denotes the marked partition is blocked
-- ============================================================================================================
create table pgpm_t364.c (id bigint primary key, payload text);
insert into pgpm_t364.c values (21, 'orig'), (22, 'orig');
call pgpm.transmute('pgpm_t364.c'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.c'::regclass, '60000');
insert into pgpm_t364.c values (35005, 'frontier');
select child_name as c_doomed, child_oid as c_oid from pgpm.part where parent_table = 'pgpm_t364.c'::regclass and lo = '0' \gset
update pgpm.part set retiring_at = now(), retiring_oid = child_oid, child_oid = null
 where parent_table = 'pgpm_t364.c'::regclass and lo = '0';
select ok((select child_oid is null and retiring_oid = :'c_oid'::oid from pgpm.part
            where parent_table = 'pgpm_t364.c'::regclass and lo = '0'),
  'C LIVENESS: the row records the partition by its mark alone');
select ok(not pgpm_t364.blocked(format('pgpm_t364.%I', :'c_doomed')), 'C LIVENESS: the partition is not blocked yet');
select pgpm._install_write_block('pgpm_t364.c'::regclass, :'c_doomed');
select ok(exists (select 1 from pg_trigger where tgrelid = :'c_oid'::oid and tgname = 'pgpm_write_block' and tgenabled = 'A'),
  'C: the marked partition, by its oid, is write-blocked');
select ok(not exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.c'::regclass and action = 'fail_write_block_identity'),
  'C: no identity refusal');

select * from finish();
