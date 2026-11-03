-- The write-block step anchors an older install's row by its retirement mark, and names, never lifts, a block an
-- older tick may have put on an operator's table under the row's old name (issue #1435).
--
-- THE GAP. v0.5.0 recorded a retirement's oid in retiring_oid alone, so its row has no child_oid. The write-block
-- step compared a name against child_oid only, so for such a row whose detached retirement the operator renamed, a
-- plain table of the operator's under the old name was taken for the partition and blocked. maintain() runs that
-- step before retain(), so the block went on in the first tick; retire()'s release (#1427) then anchored the row,
-- the step skipped it as detached by hand from then on, and nothing ever said why the operator's table refused
-- every write.
--
-- WHY NAME AND NOT LIFT. A pgpm block on a table that is no partition and that no pgpm.part row records is either
-- such a leftover or a block pgpm put on a partition the operator detached by hand and kept, row deleted, which the
-- docs promise stays. The catalog cannot tell them apart, so pgpm lifts neither: it names the block, with the
-- statement that lifts it, where the operator will read it.
--
-- THE CONTRACT.
--   PART A  maintain()'s own step order over three ticks: the operator's table is never blocked and stays
--           writable, the step logs exactly one fail_write_block_identity naming the mark's oid, and the renamed
--           table keeps its rows.
--   PART B  the operator's table already carries the block an earlier tick put on it: the tick refuses, keeps the
--           block, and names it with a drop trigger statement that, run as logged, makes the table writable.
--   PART D  an impostor ATTACHED to the parent under the name: refused, its block kept and not named (a relation
--           under the parent is not the operator's own table, as under #429).
--   PART E  coverage recorded for the renamed table is not discarded because the operator's table under the name
--           carries no block (#518's rule, by the mark's oid).
--   PART G  retire() releases the mark with the block in place: its retain_disown remedy names the block (the
--           remedy's DROP deletes the row whose refusal would name it), later ticks leave it, and the named
--           statement lifts it.
--   PART I  as G, the renamed retirement moved to another schema: the release names the block in the parent's.
--   PART Q  as I, the parent in a schema whose name needs quoting: named, the schema quoted once.
--   PART R  the table under the old name is a partition of the operator's own partitioned table: named.
--   PART K  as G, the renamed retirement moved into a twin parent's schema, where the twin's partition of the same
--           name, detached by hand and recorded by its row, carries a block, and a tenant's blocked table of the
--           same name stands in a schema of its own: only the operator's table is named, and every block stays.
--   PART P  a v0.4.0 mark (no oid at all) on pgpm's own blocked retirement, detached under its name: the release
--           names nothing, so its remedy never invites lifting pgpm's own block.
--   PART H  a mark's oid shadows no stranger: a partition of the parent over another range holding the name is
--           refused as under #1365, never a raise.
--   PART C  the control: a marked row with no child_oid whose name still denotes the marked partition is
--           write-blocked as before. Last, because its mark holds the database's one retirement slot.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job and runs whatever the standing job holds at the top level, as tests/363 does.
--
-- ASYMMETRIC FIXTURES. Each part's doomed partition holds a different set of ids (A 1, 2; B 5, 6, 7; C 21, 22;
-- D 31, 32, 33; E 41, 42, 43, 44; G 51, 52; H 61, 62; I 71, 72, 73; Q 75, 76; R 77, 78; K 15, 16; the twin 17; P 11, 12), the operator's
-- tables A 98, B 99, E 95, G 93, I 91, Q 74, R 72 and K 88, and the impostor D 37, 38, so a write to the wrong relation or a lost
-- row cannot stand in for the right answer.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(84);

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
-- the drop trigger statements a log row names, as the operator would copy them
create function pgpm_t364.logged_drops(p_method text) returns setof text language sql as $$
  select m[1] from regexp_matches(p_method, '(drop trigger if exists pgpm_write_block on [^;]*;)', 'g') m
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
select ok(not pgpm.retire('pgpm_t364.a', :'a_doomed') and pgpm_t364.armed() <> 'select 1', 'fixture: A: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
-- the row an older install left: the mark's oid alone
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.a'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to a_kept', :'a_doomed') \gexec
select format('create table pgpm_t364.%I (id bigint, payload text)', :'a_doomed') \gexec
select format('insert into pgpm_t364.%I values (98, ''mine'')', :'a_doomed') \gexec
select format('pgpm_t364.%I', :'a_doomed') as a_sq \gset
select is(pgpm._disown_unvouched_retirements(), 0, 'GUARD: A: the upgrade''s pass leaves the row''s mark');
select ok((select child_oid is null and retiring_oid = :'a_oid'::oid and attached from pgpm.part
            where parent_table = 'pgpm_t364.a'::regclass and lo = '0'),
  'LIVENESS: A: the row is attached and records the retirement by its mark alone');
select ok(not exists (select 1 from pg_inherits where inhrelid = to_regclass(:'a_sq')::oid),
  'LIVENESS: A: a plain table of the operator''s, no partition, holds the old name');
select ok(pgpm_t364.reaches('pgpm_t364.a'), 'LIVENESS: A: retention reaches the range, so the step would block it');
call pgpm.maintain('pgpm_t364.a');
call pgpm.maintain('pgpm_t364.a');
call pgpm.maintain('pgpm_t364.a');
-- the ticks dispatched the next partition's detach into the database's one detach slot; free it for the parts below
update cron.job set command = 'select 1';
select ok(exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.a'::regclass and lo = '0' and action = 'retain_disown'),
  'LIVENESS: A: retain() reached the row and released it');
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
-- PART B: a block an earlier tick put on the operator's table is named, kept, and lifted by the logged statement
-- ============================================================================================================
create table pgpm_t364.b (id bigint primary key, payload text);
insert into pgpm_t364.b values (5, 'orig'), (6, 'orig'), (7, 'orig');
call pgpm.transmute('pgpm_t364.b'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.b'::regclass, '60000');
insert into pgpm_t364.b values (35005, 'frontier');
create table public.b364_ref (id bigint primary key, p_id bigint references pgpm_t364.b(id));
insert into public.b364_ref values (1, 35005);
select child_name as b_doomed, child_oid as b_oid from pgpm.part where parent_table = 'pgpm_t364.b'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t364.b', :'b_doomed') and pgpm_t364.armed() <> 'select 1', 'fixture: B: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.b'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to b_kept', :'b_doomed') \gexec
select format('create table pgpm_t364.%I (id bigint, payload text)', :'b_doomed') \gexec
select format('insert into pgpm_t364.%I values (99, ''mine'')', :'b_doomed') \gexec
select format('pgpm_t364.%I', :'b_doomed') as b_sq \gset
select pgpm_t364.lay_block(:'b_sq');
select throws_like(format('insert into %s values (96, ''mine'')', :'b_sq'), '%past its retention boundary%',
  'LIVENESS: B: the operator''s table is blocked before the tick');
select ok(pgpm_t364.reaches('pgpm_t364.b'), 'LIVENESS: B: retention reaches the range');
call pgpm.maintain('pgpm_t364.b');
update cron.job set command = 'select 1';
select ok(pgpm_t364.blocked(:'b_sq'), 'B: the tick keeps the block, which it cannot prove it laid');
select is((select array_agg(d) from pgpm.log, pgpm_t364.logged_drops(method) d
            where parent_table = 'pgpm_t364.b'::regclass and lo = '0' and action = 'fail_write_block_identity'),
          array[format('drop trigger if exists pgpm_write_block on %s;', :'b_sq')],
  'B: the refusal names the block on the operator''s table, as one statement');
select pgpm_t364.logged_drops(method) from pgpm.log
 where parent_table = 'pgpm_t364.b'::regclass and lo = '0' and action = 'fail_write_block_identity' \gexec
select ok(not pgpm_t364.blocked(:'b_sq'), 'B: run as logged, the statement lifts the block');
select lives_ok(format('insert into %s values (96, ''mine'')', :'b_sq'), 'B: the operator can write to their table again');
select is(pgpm_t364.ids(:'b_sq'), array[96, 99]::bigint[], 'B: the operator''s table holds exactly its own rows');
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
select ok(not pgpm.retire('pgpm_t364.d', :'d_doomed') and pgpm_t364.armed() <> 'select 1', 'fixture: D: retire() dispatches the detach');
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
  'LIVENESS: D: the impostor is a partition of the parent, by oid');
select ok(pgpm_t364.blocked(:'d_imp'), 'LIVENESS: D: the impostor carries a block');
select pgpm._install_write_block('pgpm_t364.d'::regclass, :'d_doomed');
select ok(exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.d'::regclass and lo = '0' and action = 'fail_write_block_identity'),
  'D: the impostor is refused');
select ok(pgpm_t364.blocked(:'d_imp'), 'D: the impostor keeps its block');
select ok(not exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.d'::regclass and lo = '0'
                       and action = 'fail_write_block_identity' and method like '%drop trigger%'),
  'D: the refusal names no block to lift');
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
select ok(not pgpm.retire('pgpm_t364.e', :'e_doomed') and pgpm_t364.armed() <> 'select 1', 'fixture: E: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.e'::regclass and lo = '0';
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid)
  values ('pgpm_t364.e'::regclass, '0', '5000', :'e_doomed', 4, :'e_oid'::oid);
select format('alter table pgpm_t364.%I rename to e_kept', :'e_doomed') \gexec
select format('create table pgpm_t364.%I (id bigint, payload text)', :'e_doomed') \gexec
select format('insert into pgpm_t364.%I values (95, ''mine'')', :'e_doomed') \gexec
select format('pgpm_t364.%I', :'e_doomed') as e_sq \gset
select ok(not pgpm_t364.blocked(:'e_sq'), 'LIVENESS: E: the table under the name carries no block, so coverage looks unguarded');
select ok(pgpm_t364.reaches('pgpm_t364.e'), 'LIVENESS: E: retention reaches the range');
select pgpm._enforce_write_blocks('pgpm_t364.e'::regclass);
select ok(not exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.e'::regclass and action = 'archive_coverage_reset'),
  'E: no coverage is discarded');
select is((select array_agg(hi) from pgpm.archive_ledger
            where parent_table = 'pgpm_t364.e'::regclass and child_oid = :'e_oid'::oid and retired_at is null),
          array['5000'], 'E: the renamed table''s chunk is still recorded');
select ok(not pgpm_t364.blocked(:'e_sq'), 'E: the operator''s table is not blocked');

-- ============================================================================================================
-- PART G: retire() releases the mark with the block in place; its remedy names the block, and nothing lifts it
-- ============================================================================================================
create table pgpm_t364.g (id bigint primary key, payload text);
insert into pgpm_t364.g values (51, 'orig'), (52, 'orig');
call pgpm.transmute('pgpm_t364.g'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.g'::regclass, '60000');
insert into pgpm_t364.g values (35005, 'frontier');
create table public.g364_ref (id bigint primary key, p_id bigint references pgpm_t364.g(id));
insert into public.g364_ref values (1, 35005);
select child_name as g_doomed, child_oid as g_oid from pgpm.part where parent_table = 'pgpm_t364.g'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t364.g', :'g_doomed') and pgpm_t364.armed() <> 'select 1', 'fixture: G: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.g'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to g_kept', :'g_doomed') \gexec
select format('create table pgpm_t364.%I (id bigint, payload text)', :'g_doomed') \gexec
select format('insert into pgpm_t364.%I values (93, ''mine'')', :'g_doomed') \gexec
select format('pgpm_t364.%I', :'g_doomed') as g_sq \gset
select pgpm_t364.lay_block(:'g_sq');   -- the block the older tick laid
select ok(pgpm_t364.blocked(:'g_sq'), 'LIVENESS: G: the operator''s table carries the older install''s block');
select ok(not pgpm.retire('pgpm_t364.g', :'g_doomed'), 'fixture: G: retire() runs before any tick');
select ok((select child_oid = :'g_oid'::oid and retiring_at is null from pgpm.part
            where parent_table = 'pgpm_t364.g'::regclass and lo = '0'),
  'LIVENESS: G: retire() released the mark and anchored the row to the renamed table');
select is((select array_agg(d) from pgpm.log, pgpm_t364.logged_drops(method) d
            where parent_table = 'pgpm_t364.g'::regclass and lo = '0' and action = 'retain_disown'),
          array[format('drop trigger if exists pgpm_write_block on %s;', :'g_sq')],
  'G: the release''s remedy names the block on the operator''s table, as one statement');
select ok(pgpm_t364.blocked(:'g_sq'), 'G: the release keeps the block');
call pgpm.maintain('pgpm_t364.g');
update cron.job set command = 'select 1';
select ok(pgpm_t364.blocked(:'g_sq'), 'G: and so does the next tick, the row now detached by hand');
select pgpm_t364.logged_drops(method) from pgpm.log
 where parent_table = 'pgpm_t364.g'::regclass and lo = '0' and action = 'retain_disown' \gexec
select ok(not pgpm_t364.blocked(:'g_sq'), 'G: run as logged, the statement lifts the block');
select lives_ok(format('insert into %s values (92, ''mine'')', :'g_sq'), 'G: the operator can write to their table again');
select is(pgpm_t364.ids(:'g_sq'), array[92, 93]::bigint[], 'G: the operator''s table holds exactly its own rows');
select is(pgpm_t364.ids('pgpm_t364.g_kept'), array[51, 52]::bigint[], 'G: the renamed table keeps ids 51, 52');

-- ============================================================================================================
-- PART I: as G, the renamed retirement moved to another schema; the release names the block in the parent's
-- ============================================================================================================
create schema pgpm_t364_keep;
create table pgpm_t364.i (id bigint primary key, payload text);
insert into pgpm_t364.i values (71, 'orig'), (72, 'orig'), (73, 'orig');
call pgpm.transmute('pgpm_t364.i'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.i'::regclass, '60000');
insert into pgpm_t364.i values (35005, 'frontier');
create table public.i364_ref (id bigint primary key, p_id bigint references pgpm_t364.i(id));
insert into public.i364_ref values (1, 35005);
select child_name as i_doomed, child_oid as i_oid from pgpm.part where parent_table = 'pgpm_t364.i'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t364.i', :'i_doomed') and pgpm_t364.armed() <> 'select 1', 'fixture: I: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.i'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to i_kept', :'i_doomed') \gexec
alter table pgpm_t364.i_kept set schema pgpm_t364_keep;
select format('create table pgpm_t364.%I (id bigint, payload text)', :'i_doomed') \gexec
select format('insert into pgpm_t364.%I values (91, ''mine'')', :'i_doomed') \gexec
select format('pgpm_t364.%I', :'i_doomed') as i_sq \gset
select pgpm_t364.lay_block(:'i_sq');
select ok(not pgpm.retire('pgpm_t364.i', :'i_doomed'), 'fixture: I: retire() runs before any tick');
select ok((select child_oid = :'i_oid'::oid from pgpm.part where parent_table = 'pgpm_t364.i'::regclass and lo = '0')
          and to_regclass('pgpm_t364_keep.i_kept')::oid = :'i_oid'::oid,
  'LIVENESS: I: the row is anchored to the renamed table, now in another schema');
select ok(pgpm_t364.blocked(:'i_sq'), 'I: the block in the parent''s schema stays');
select is((select array_agg(d) from pgpm.log, pgpm_t364.logged_drops(method) d
            where parent_table = 'pgpm_t364.i'::regclass and lo = '0' and action = 'retain_disown'),
          array[format('drop trigger if exists pgpm_write_block on %s;', :'i_sq')],
  'I: the release''s remedy names it, in the parent''s schema');
select pgpm_t364.logged_drops(method) from pgpm.log
 where parent_table = 'pgpm_t364.i'::regclass and lo = '0' and action = 'retain_disown' \gexec
select lives_ok(format('insert into %s values (90, ''mine'')', :'i_sq'), 'I: run as logged, the operator can write to their table again');
select is(pgpm_t364.ids('pgpm_t364_keep.i_kept'), array[71, 72, 73]::bigint[], 'I: the moved table keeps ids 71, 72, 73');

-- ============================================================================================================
-- PART Q: as I, the parent in a schema whose name needs quoting; the release still names the block there
-- ============================================================================================================
create schema "pgpm T364 Q";
create table "pgpm T364 Q".q (id bigint primary key, payload text);
insert into "pgpm T364 Q".q values (75, 'orig'), (76, 'orig');
call pgpm.transmute('"pgpm T364 Q".q'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('"pgpm T364 Q".q'::regclass, '60000');
insert into "pgpm T364 Q".q values (35005, 'frontier');
create table public.q364_ref (id bigint primary key, p_id bigint references "pgpm T364 Q".q(id));
insert into public.q364_ref values (1, 35005);
select child_name as q_doomed, child_oid as q_oid from pgpm.part where parent_table = '"pgpm T364 Q".q'::regclass and lo = '0' \gset
select ok(not pgpm.retire('"pgpm T364 Q".q', :'q_doomed') and pgpm_t364.armed() <> 'select 1', 'fixture: Q: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = '"pgpm T364 Q".q'::regclass and lo = '0';
select format('alter table "pgpm T364 Q".%I rename to q_kept', :'q_doomed') \gexec
alter table "pgpm T364 Q".q_kept set schema pgpm_t364_keep;
select format('create table "pgpm T364 Q".%I (id bigint, payload text)', :'q_doomed') \gexec
select format('insert into "pgpm T364 Q".%I values (74, ''mine'')', :'q_doomed') \gexec
select format('%I.%I', 'pgpm T364 Q', :'q_doomed') as q_sq \gset
select pgpm_t364.lay_block(:'q_sq');
select ok(not pgpm.retire('"pgpm T364 Q".q', :'q_doomed'), 'fixture: Q: retire() runs before any tick');
select ok(pgpm_t364.blocked(:'q_sq') and to_regclass('pgpm_t364_keep.q_kept')::oid = :'q_oid'::oid,
  'LIVENESS: Q: the block stands in the parent''s quoted schema, the renamed retirement in another');
select is((select array_agg(d) from pgpm.log, pgpm_t364.logged_drops(method) d
            where parent_table = '"pgpm T364 Q".q'::regclass and lo = '0' and action = 'retain_disown'),
          array[format('drop trigger if exists pgpm_write_block on %s;', :'q_sq')],
  'Q: the release''s remedy names it, the schema quoted once');
select pgpm_t364.logged_drops(method) from pgpm.log
 where parent_table = '"pgpm T364 Q".q'::regclass and lo = '0' and action = 'retain_disown' \gexec
select lives_ok(format('insert into %s values (73, ''mine'')', :'q_sq'), 'Q: run as logged, the operator can write to their table again');

-- ============================================================================================================
-- PART R: the table under the old name is a partition of the operator's own partitioned table; the refusal names it
-- ============================================================================================================
create table pgpm_t364.r (id bigint primary key, payload text);
insert into pgpm_t364.r values (77, 'orig'), (78, 'orig');
call pgpm.transmute('pgpm_t364.r'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.r'::regclass, '60000');
insert into pgpm_t364.r values (35005, 'frontier');
create table public.r364_ref (id bigint primary key, p_id bigint references pgpm_t364.r(id));
insert into public.r364_ref values (1, 35005);
select child_name as r_doomed, child_oid as r_oid from pgpm.part where parent_table = 'pgpm_t364.r'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t364.r', :'r_doomed') and pgpm_t364.armed() <> 'select 1', 'fixture: R: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.r'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to r_kept', :'r_doomed') \gexec
create table pgpm_t364.r_mine (id bigint, payload text) partition by range (id);
select format('create table pgpm_t364.%I partition of pgpm_t364.r_mine for values from (0) to (1000)', :'r_doomed') \gexec
insert into pgpm_t364.r_mine values (72, 'mine');
select format('pgpm_t364.%I', :'r_doomed') as r_sq \gset
select pgpm_t364.lay_block(:'r_sq');
select ok(pgpm_t364.blocked(:'r_sq') and exists (select 1 from pg_inherits where inhrelid = to_regclass(:'r_sq')::oid
                                                   and inhparent = 'pgpm_t364.r_mine'::regclass),
  'LIVENESS: R: the table under the old name is a blocked partition of the operator''s own partitioned table');
select pgpm._install_write_block('pgpm_t364.r'::regclass, :'r_doomed');
select is((select array_agg(d) from pgpm.log, pgpm_t364.logged_drops(method) d
            where parent_table = 'pgpm_t364.r'::regclass and lo = '0' and action = 'fail_write_block_identity'),
          array[format('drop trigger if exists pgpm_write_block on %s;', :'r_sq')],
  'R: the refusal names the block on the operator''s partition');
select ok(pgpm_t364.blocked(:'r_sq'), 'R: and keeps it');
select pgpm_t364.logged_drops(method) from pgpm.log
 where parent_table = 'pgpm_t364.r'::regclass and lo = '0' and action = 'fail_write_block_identity' \gexec
select lives_ok('insert into pgpm_t364.r_mine values (71, ''mine'')', 'R: run as logged, the operator can write through their own parent again');

-- ============================================================================================================
-- PART K: the release names only the operator's table; a twin's partition and a tenant's table are not named
-- ============================================================================================================
create schema pgpm_t364_twin;
create table pgpm_t364.k (id bigint primary key, payload text);
insert into pgpm_t364.k values (15, 'orig'), (16, 'orig');
call pgpm.transmute('pgpm_t364.k'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.k'::regclass, '60000');
insert into pgpm_t364.k values (35005, 'frontier');
create table public.k364_ref (id bigint primary key, p_id bigint references pgpm_t364.k(id));
insert into public.k364_ref values (1, 35005);
create table pgpm_t364_twin.k (id bigint primary key, payload text);
insert into pgpm_t364_twin.k values (17, 'twin');
call pgpm.transmute('pgpm_t364_twin.k'::regclass, 'id', 10000::bigint, p_paused => true);
select child_name as k_doomed, child_oid as k_oid from pgpm.part where parent_table = 'pgpm_t364.k'::regclass and lo = '0' \gset
select child_oid as twin_oid from pgpm.part where parent_table = 'pgpm_t364_twin.k'::regclass and lo = '0' \gset
select format('alter table pgpm_t364_twin.k detach partition pgpm_t364_twin.%I', :'k_doomed') \gexec
select format('pgpm_t364_twin.%I', :'k_doomed') as twin_rel \gset
select pgpm_t364.lay_block(:'twin_rel');   -- the block a table detached by hand keeps (#705)
select ok(not pgpm.retire('pgpm_t364.k', :'k_doomed') and pgpm_t364.armed() <> 'select 1', 'fixture: K: retire() dispatches the detach');
select command from cron.job where jobname = 'pgpm_detach' \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, detach_dispatched_oid = null where parent_table = 'pgpm_t364.k'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to k_kept', :'k_doomed') \gexec
alter table pgpm_t364.k_kept set schema pgpm_t364_twin;   -- the twin's schema is K's family's too from here
create schema pgpm_t364_tenant;
select format('create table pgpm_t364_tenant.%I (id bigint, payload text)', :'k_doomed') \gexec
select format('pgpm_t364_tenant.%I', :'k_doomed') as tenant_rel \gset
select pgpm_t364.lay_block(:'tenant_rel');   -- a tenant's kept table: detached by hand, its row deleted, its block kept
select format('create table pgpm_t364.%I (id bigint, payload text)', :'k_doomed') \gexec
select format('insert into pgpm_t364.%I values (88, ''mine'')', :'k_doomed') \gexec
select format('pgpm_t364.%I', :'k_doomed') as k_sq \gset
select pgpm_t364.lay_block(:'k_sq');
select ok(pgpm_t364.blocked(:'k_sq'), 'LIVENESS: K: the operator''s table carries the older install''s block');
select ok(pgpm_t364.blocked(:'twin_rel') and to_regclass(:'twin_rel')::oid = :'twin_oid'::oid
          and not exists (select 1 from pg_inherits where inhrelid = :'twin_oid'::oid),
  'LIVENESS: K: the twin parent''s partition of the same name, detached and recorded by its row, carries a block too');
select ok(pgpm_t364.blocked(:'tenant_rel') and to_regclass('pgpm_t364_twin.k_kept')::oid = :'k_oid'::oid,
  'LIVENESS: K: a tenant''s table of the same name carries a block, and the renamed retirement stands in the twin''s schema');
select ok(not pgpm.retire('pgpm_t364.k', :'k_doomed'), 'fixture: K: retire() runs before any tick');
select ok((select child_oid = :'k_oid'::oid and retiring_at is null from pgpm.part
            where parent_table = 'pgpm_t364.k'::regclass and lo = '0'),
  'LIVENESS: K: retire() released the mark and anchored the row to the renamed table');
select is((select array_agg(d) from pgpm.log, pgpm_t364.logged_drops(method) d
            where parent_table = 'pgpm_t364.k'::regclass and lo = '0' and action = 'retain_disown'),
          array[format('drop trigger if exists pgpm_write_block on %s;', :'k_sq')],
  'K: the release''s remedy names the operator''s table, and only it');
select ok(pgpm_t364.blocked(:'k_sq') and pgpm_t364.blocked(:'twin_rel') and pgpm_t364.blocked(:'tenant_rel'),
  'K: the release lifts none of the three blocks');
select is(pgpm_t364.ids('pgpm_t364_twin.k_kept'), array[15, 16]::bigint[], 'K: the renamed table keeps ids 15, 16');

-- ============================================================================================================
-- PART P: a v0.4.0 mark (no oid) on pgpm's own blocked retirement: the release names no block
-- ============================================================================================================
create table pgpm_t364.p (id bigint primary key, payload text);
insert into pgpm_t364.p values (11, 'orig'), (12, 'orig');
call pgpm.transmute('pgpm_t364.p'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.p'::regclass, '60000');
insert into pgpm_t364.p values (35005, 'frontier');
select child_name as p_doomed, child_oid as p_oid from pgpm.part where parent_table = 'pgpm_t364.p'::regclass and lo = '0' \gset
select format('pgpm_t364.%I', :'p_doomed') as p_sq \gset
select pgpm._enforce_write_blocks('pgpm_t364.p'::regclass);
update pgpm.part set retiring_at = now(), retiring_oid = null, child_oid = null, detach_dispatched_oid = null
 where parent_table = 'pgpm_t364.p'::regclass and lo = '0';
select format('alter table pgpm_t364.p detach partition pgpm_t364.%I', :'p_doomed') \gexec
select ok(pgpm_t364.blocked(:'p_sq') and to_regclass(:'p_sq')::oid = :'p_oid'::oid
          and not exists (select 1 from pg_inherits where inhrelid = :'p_oid'::oid),
  'LIVENESS: P: pgpm''s own block stands on its retirement, detached under the row''s name');
select ok(pgpm._disown_retirement('pgpm_t364.p', :'p_doomed', 'P: released'), 'LIVENESS: P: the release ran');
select ok(pgpm_t364.blocked(:'p_sq'), 'P: the retirement keeps its block (#705)');
select ok((select method not like '%drop trigger%' from pgpm.log
            where parent_table = 'pgpm_t364.p'::regclass and lo = '0' and action = 'retain_disown'),
  'P: and the release''s remedy names no block to lift');
select is(pgpm_t364.ids(:'p_sq'), array[11, 12]::bigint[], 'P: the retirement keeps ids 11, 12');

-- ============================================================================================================
-- PART H: a mark's oid shadows no stranger: a partition over another range under the name is still refused (#1365)
-- ============================================================================================================
create table pgpm_t364.h (id bigint primary key, payload text);
insert into pgpm_t364.h values (61, 'orig'), (62, 'orig');
call pgpm.transmute('pgpm_t364.h'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t364.h'::regclass, '60000');
select child_name as h_doomed, child_oid as h_oid from pgpm.part where parent_table = 'pgpm_t364.h'::regclass and lo = '0' \gset
select child_name as h_next from pgpm.part where parent_table = 'pgpm_t364.h'::regclass and lo = '10000' \gset
-- an older install's mark on the partition, then the name moved to its neighbour over [10000, 20000)
update pgpm.part set retiring_at = now(), retiring_oid = child_oid, child_oid = null
 where parent_table = 'pgpm_t364.h'::regclass and lo = '0';
select format('alter table pgpm_t364.%I rename to h_aside', :'h_doomed') \gexec
select format('alter table pgpm_t364.%I rename to %I', :'h_next', :'h_doomed') \gexec
select format('pgpm_t364.%I', :'h_doomed') as h_str \gset
select ok(exists (select 1 from pg_inherits where inhparent = 'pgpm_t364.h'::regclass and inhrelid = to_regclass(:'h_str')::oid)
          and to_regclass(:'h_str')::oid <> :'h_oid'::oid,
  'LIVENESS: H: the row''s name denotes another partition of the parent');
select lives_ok(format('select pgpm._install_write_block(%L::regclass, %L)', 'pgpm_t364.h', :'h_doomed'),
  'H: the step does not raise');
select ok(exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.h'::regclass and lo = '0'
                   and action = 'fail_write_block_identity' and method like '%over another range%'),
  'H: it refuses the stranger as a partition over another range');
select ok(not pgpm_t364.blocked(:'h_str'), 'H: and blocks nothing');

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
  'LIVENESS: C: the row records the partition by its mark alone');
select ok(not pgpm_t364.blocked(format('pgpm_t364.%I', :'c_doomed')), 'LIVENESS: C: the partition is not blocked yet');
select pgpm._install_write_block('pgpm_t364.c'::regclass, :'c_doomed');
select ok(exists (select 1 from pg_trigger where tgrelid = :'c_oid'::oid and tgname = 'pgpm_write_block' and tgenabled = 'A'),
  'C: the marked partition, by its oid, is write-blocked');
select ok(not exists (select 1 from pgpm.log where parent_table = 'pgpm_t364.c'::regclass and action = 'fail_write_block_identity'),
  'C: no identity refusal');

select * from finish();
