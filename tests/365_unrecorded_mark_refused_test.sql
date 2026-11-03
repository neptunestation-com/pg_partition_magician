-- A retirement mark that records no oid at all is refused, never judged by its name out of the parent, and the table
-- under its name is never write-blocked (issues #1432 and #1434).
--
-- THE GAPS. A pgpm older than v0.5.0 wrote a retirement mark as retiring_at alone: no retiring_oid, no child_oid, no
-- detach_dispatched_oid. Once its detach landed and the operator renamed the detached table to keep it:
--   #1434  with nothing under the old name, retire() passed every identity gate and raised out of the write block on
--          every tick (42P01), which retain() logged as an uncounted skip_retain, no remedy, the mark kept for ever.
--   #1432  with a table created under the old name since, the install pass, retire() and the recall each took that
--          table for the retirement, disowned the mark as its own and logged a remedy ATTACHing it, and the
--          write-block step blocked it.
-- With no oid nothing tells the retirement from a table created under its name, so every path now refuses such a
-- mark (fail_retain_identity, counted), keeps it, and spells both ways out (attach the right table; or clear the mark
-- and drop any block), and the write-block step leaves a table out of the parent alone. The maintainer chose this
-- over a disown with a hedged remedy: a genuine v0.4.0 retirement that was not renamed costs the operator one
-- statement, and pgpm never acts on a guess.
--
-- THE CONTRACT.
--   PART A  (#1434) nothing under the name, retention reaching the range: retire() returns false and logs exactly
--           fail_retain_identity, which status() counts, the job disarmed and the mark kept; maintain() logs no
--           skip_retain. The repair it spells (rename back, ATTACH), run as written, makes the row retire again.
--   PART D  (#1432, the install pass) a table created under the old name before the pass: the pass leaves the mark,
--           logs nothing, and touches neither table.
--   PART B  (#1432, retire()) the same through maintain(): exactly fail_retain_identity, the mark kept, no
--           retain_disown; the table under the name is neither attached nor blocked, and keeps its rows.
--   PART C  (#1432, the recall) the same once retention no longer reaches the range.
--   PART E  a genuine v0.4.0 retirement, not renamed, carrying the block an older tick put on it: refused the same
--           way, the remedy naming it; its clear-the-mark repair, run as written, leaves it a table detached by hand
--           (fail_retain_drop, never dropped) and writable, and no later tick blocks it again.
--   PART F  the control: a row with no oid whose name denotes a partition of the parent over its own range is
--           write-blocked as before.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job and runs whatever the standing job holds at the top level, as tests/364 does.
-- Retention reaches each parent's first partition only (frontier 35005, retain 25000), so no tick arms a second
-- detach in the database's one slot.
--
-- ASYMMETRIC FIXTURES. Each part's doomed partition holds a different set of ids (A 1, 2; B 5, 6, 7; C 11, 12, 13,
-- 14; D 21; E 31, 32, 33; F 41, 42), and the tables created under the old names B 99, C 98, D 97, so a disown,
-- attach or drop of the wrong relation, or a lost row, cannot stand in for the right answer.
create extension if not exists pgtap;
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

create schema pgpm_t365;

create function pgpm_t365.ids(p_rel text) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg(id order by id) from %s where id < 10000', p_rel) into v;
  return v;
end;
$$;
create function pgpm_t365.armed() returns text language sql as $$
  select command from cron.job where jobname = 'pgpm_detach'
$$;
create function pgpm_t365.blocked(p_rel text) returns boolean language sql as $$
  select exists (select 1 from pg_trigger where tgrelid = to_regclass(p_rel) and tgname = 'pgpm_write_block')
$$;
create function pgpm_t365.actions(p_parent regclass) returns text[] language sql as $$
  select coalesce(array_agg(action order by id), '{}') from pgpm.log
   where parent_table = p_parent and lo = '0'
     and action in ('retain_detach', 'retain_recall', 'retain_reattach', 'retain_disown', 'retain_drop',
                    'fail_retain_drop', 'fail_retain_identity', 'skip_retain')
$$;
create function pgpm_t365.method(p_parent regclass) returns text language sql as $$
  select method from pgpm.log where parent_table = p_parent and lo = '0' and action = 'fail_retain_identity'
   order by id desc limit 1
$$;
-- the mark a pgpm older than v0.5.0 wrote: retiring_at alone
create function pgpm_t365.unrecorded(p_parent regclass) returns boolean language sql as $$
  select retiring_at is not null and retiring_oid is null and child_oid is null and detach_dispatched_oid is null
    from pgpm.part where parent_table = p_parent and lo = '0'
$$;
create function pgpm_t365.reaches(p_parent regclass) returns boolean language sql as $$
  select not pgpm._native_gt(c.control_kind, '10000', pgpm._retain_boundary(c)) from pgpm.config c where c.parent_table = p_parent
$$;

-- ============================================================================================================
-- PART A (#1434): nothing under the name
-- ============================================================================================================
create table pgpm_t365.a (id bigint primary key, payload text);
insert into pgpm_t365.a values (1, 'orig'), (2, 'orig');
call pgpm.transmute('pgpm_t365.a'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t365.a'::regclass, '60000');
insert into pgpm_t365.a values (35005, 'frontier');
create table public.a365_ref (id bigint primary key, p_id bigint references pgpm_t365.a(id));
insert into public.a365_ref values (1, 35005);
select child_name as a_doomed from pgpm.part where parent_table = 'pgpm_t365.a'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t365.a', :'a_doomed') and pgpm_t365.armed() <> 'select 1', 'fixture: A: retire() dispatches the detach');
select pgpm_t365.armed() as a_cmd \gset
select pgpm_t365.armed() \gexec
update pgpm.part set child_oid = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'pgpm_t365.a'::regclass and lo = '0';
select format('alter table pgpm_t365.%I rename to a_kept', :'a_doomed') \gexec
select is(pgpm._disown_unvouched_retirements(), 0, 'GUARD: A: the install pass leaves the mark');
select ok(pgpm_t365.unrecorded('pgpm_t365.a') and to_regclass(format('pgpm_t365.%I', :'a_doomed')) is null,
  'LIVENESS: A: the mark records no oid, and its name denotes nothing');
select ok(pgpm_t365.reaches('pgpm_t365.a'), 'LIVENESS: A: retention reaches the range');
select is(pgpm_t365.armed(), :'a_cmd', 'LIVENESS: A: the job still holds the detach');
select ok(not pgpm.retire('pgpm_t365.a', :'a_doomed'), 'A: retire() returns false rather than raising');
select is(pgpm_t365.actions('pgpm_t365.a'), array['retain_detach', 'fail_retain_identity'],
  'A: logged as exactly fail_retain_identity');
select is((select retain_drop_failures from pgpm.status() where parent = 'pgpm_t365.a'::regclass), 1::bigint,
  'A: status() counts it');
select is(pgpm_t365.armed(), 'select 1', 'A: the job is disarmed');
select ok(pgpm_t365.unrecorded('pgpm_t365.a'), 'A: the mark is kept');
call pgpm.maintain('pgpm_t365.a');
select is(pgpm_t365.actions('pgpm_t365.a'), array['retain_detach', 'fail_retain_identity', 'fail_retain_identity'],
  'A: a maintain() tick refuses it again, and logs no skip_retain');
select is(pgpm_t365.ids('pgpm_t365.a_kept'), array[1, 2]::bigint[], 'A: the renamed table keeps its rows');
-- the repair the method spells, run as written
select format('alter table pgpm_t365.a_kept rename to %I', :'a_doomed') \gexec
select substring(pgpm_t365.method('pgpm_t365.a') from '(alter table \S+ attach partition [^;]*;)') \gexec
select ok(exists (select 1 from pg_inherits where inhparent = 'pgpm_t365.a'::regclass
                   and inhrelid = to_regclass(format('pgpm_t365.%I', :'a_doomed'))::oid),
  'A: the repair attaches the table under the row''s name');
select ok(not pgpm.retire('pgpm_t365.a', :'a_doomed') and pgpm_t365.armed() <> 'select 1',
  'A: once repaired, retire() retires it again (its detach dispatched)');
select pgpm_t365.armed() \gexec
update cron.job set command = 'select 1';

-- ============================================================================================================
-- PART D (#1432, the install pass): a table created under the old name before the pass
-- ============================================================================================================
create table pgpm_t365.d (id bigint primary key, payload text);
insert into pgpm_t365.d values (21, 'orig');
call pgpm.transmute('pgpm_t365.d'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t365.d'::regclass, '60000');
insert into pgpm_t365.d values (35005, 'frontier');
create table public.d365_ref (id bigint primary key, p_id bigint references pgpm_t365.d(id));
insert into public.d365_ref values (1, 35005);
select child_name as d_doomed from pgpm.part where parent_table = 'pgpm_t365.d'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t365.d', :'d_doomed') and pgpm_t365.armed() <> 'select 1', 'fixture: D: retire() dispatches the detach');
select pgpm_t365.armed() \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'pgpm_t365.d'::regclass and lo = '0';
select format('alter table pgpm_t365.%I rename to d_kept', :'d_doomed') \gexec
select format('create table pgpm_t365.%I (id bigint, payload text)', :'d_doomed') \gexec
select format('insert into pgpm_t365.%I values (97, ''mine'')', :'d_doomed') \gexec
select format('pgpm_t365.%I', :'d_doomed') as d_sq \gset
select ok(pgpm_t365.unrecorded('pgpm_t365.d') and not exists (select 1 from pg_inherits where inhrelid = to_regclass(:'d_sq')::oid),
  'LIVENESS: D: the mark records no oid, and a plain table holds its name');
select is(pgpm._disown_unvouched_retirements(), 0, 'D: the install pass disowns nothing');
select is(pgpm_t365.actions('pgpm_t365.d'), array['retain_detach'], 'D: and logs nothing for the row');
select ok(pgpm_t365.unrecorded('pgpm_t365.d'), 'D: the mark is kept');
select is(pgpm_t365.ids(:'d_sq'), array[97]::bigint[], 'D: the table under the name is untouched');
select is(pgpm_t365.ids('pgpm_t365.d_kept'), array[21]::bigint[], 'D: the renamed table keeps its row');

-- ============================================================================================================
-- PART B (#1432, retire() through maintain()): a table created under the old name
-- ============================================================================================================
create table pgpm_t365.b (id bigint primary key, payload text);
insert into pgpm_t365.b values (5, 'orig'), (6, 'orig'), (7, 'orig');
call pgpm.transmute('pgpm_t365.b'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t365.b'::regclass, '60000');
insert into pgpm_t365.b values (35005, 'frontier');
create table public.b365_ref (id bigint primary key, p_id bigint references pgpm_t365.b(id));
insert into public.b365_ref values (1, 35005);
select child_name as b_doomed from pgpm.part where parent_table = 'pgpm_t365.b'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t365.b', :'b_doomed') and pgpm_t365.armed() <> 'select 1', 'fixture: B: retire() dispatches the detach');
select pgpm_t365.armed() \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'pgpm_t365.b'::regclass and lo = '0';
select format('alter table pgpm_t365.%I rename to b_kept', :'b_doomed') \gexec
select format('create table pgpm_t365.%I (id bigint, payload text)', :'b_doomed') \gexec
select format('insert into pgpm_t365.%I values (99, ''mine'')', :'b_doomed') \gexec
select format('pgpm_t365.%I', :'b_doomed') as b_sq \gset
select ok(pgpm_t365.unrecorded('pgpm_t365.b') and pgpm_t365.reaches('pgpm_t365.b'),
  'LIVENESS: B: the mark records no oid, and retention reaches the range');
call pgpm.maintain('pgpm_t365.b');
select is(pgpm_t365.actions('pgpm_t365.b'), array['retain_detach', 'fail_retain_identity'],
  'B: retire() refuses it, logged as exactly fail_retain_identity (no retain_disown)');
select ok(pgpm_t365.method('pgpm_t365.b') like '%(oid ' || to_regclass(:'b_sq')::oid || '), no partition of%',
  'B: the refusal names the table under the name by its oid');
select ok(pgpm_t365.unrecorded('pgpm_t365.b'), 'B: the mark is kept');
select ok(not exists (select 1 from pg_inherits where inhrelid = to_regclass(:'b_sq')::oid),
  'B: the table under the name is attached to nothing');
select ok(not pgpm_t365.blocked(:'b_sq'), 'B: and carries no write block');
select lives_ok(format('insert into %s values (96, ''mine'')', :'b_sq'), 'B: and its owner can write to it');
select is(pgpm_t365.ids(:'b_sq'), array[96, 99]::bigint[], 'B: it holds exactly its own rows');
select is(pgpm_t365.ids('pgpm_t365.b_kept'), array[5, 6, 7]::bigint[], 'B: the renamed table keeps its rows');
update cron.job set command = 'select 1';

-- ============================================================================================================
-- PART C (#1432, the recall): as B, once retention no longer reaches the range
-- ============================================================================================================
create table pgpm_t365.c (id bigint primary key, payload text);
insert into pgpm_t365.c values (11, 'orig'), (12, 'orig'), (13, 'orig'), (14, 'orig');
call pgpm.transmute('pgpm_t365.c'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t365.c'::regclass, '60000');
insert into pgpm_t365.c values (35005, 'frontier');
create table public.c365_ref (id bigint primary key, p_id bigint references pgpm_t365.c(id));
insert into public.c365_ref values (1, 35005);
select child_name as c_doomed from pgpm.part where parent_table = 'pgpm_t365.c'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t365.c', :'c_doomed') and pgpm_t365.armed() <> 'select 1', 'fixture: C: retire() dispatches the detach');
select pgpm_t365.armed() \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'pgpm_t365.c'::regclass and lo = '0';
select format('alter table pgpm_t365.%I rename to c_kept', :'c_doomed') \gexec
select format('create table pgpm_t365.%I (id bigint, payload text)', :'c_doomed') \gexec
select format('insert into pgpm_t365.%I values (98, ''mine'')', :'c_doomed') \gexec
select format('pgpm_t365.%I', :'c_doomed') as c_sq \gset
-- the block a v0.4.0 tick put on the table under the name before the upgrade (#1437 verification V-01)
select format('create trigger pgpm_write_block before insert or update or delete on %s for each row execute function pgpm._write_block_raise()', :'c_sq') \gexec
select pgpm.set_retain('pgpm_t365.c', '45000');
select ok(pgpm_t365.unrecorded('pgpm_t365.c') and not pgpm_t365.reaches('pgpm_t365.c'),
  'LIVENESS: C: the mark records no oid, and retention no longer reaches the range');
select pgpm._retain_recall('pgpm_t365.c'::regclass, true);
select is(pgpm_t365.actions('pgpm_t365.c'), array['retain_detach', 'fail_retain_identity'],
  'C: the recall refuses it, logged as exactly fail_retain_identity (no retain_disown)');
select ok(pgpm_t365.unrecorded('pgpm_t365.c'), 'C: the mark is kept');
select ok(not exists (select 1 from pg_inherits where inhrelid = to_regclass(:'c_sq')::oid),
  'C: the table under the name is attached to nothing');
select is(pgpm_t365.ids(:'c_sq'), array[98]::bigint[], 'C: and keeps its row');
select is(pgpm_t365.ids('pgpm_t365.c_kept'), array[11, 12, 13, 14]::bigint[], 'C: the renamed table keeps its rows');
-- the repair the method spells for the other case, the renamed table holding the range: the table under the name
-- is moved aside, and the block an older tick left on it is named in that branch, not only in the keep-it branch
select ok(pgpm_t365.blocked(:'c_sq'), 'LIVENESS: C: the table under the name carries an older tick''s block');
select is(substring(pgpm_t365.method('pgpm_t365.c') from 'If it is another, [^;]*drop trigger if exists pgpm_write_block on ([^;]*);'), :'c_sq',
  'C: the move-aside branch names that table''s block');
select substring(pgpm_t365.method('pgpm_t365.c') from 'If it is another, [^;]*(drop trigger if exists pgpm_write_block on [^;]*;)') \gexec
select format('alter table %s rename to c_aside', :'c_sq') \gexec
select lives_ok('insert into pgpm_t365.c_aside values (97, ''mine'')', 'C: run as written, the moved-aside table is writable');

-- ============================================================================================================
-- PART E: a genuine v0.4.0 retirement, not renamed, still carrying an older tick's block
-- ============================================================================================================
create table pgpm_t365.e (id bigint primary key, payload text);
insert into pgpm_t365.e values (31, 'orig'), (32, 'orig'), (33, 'orig');
call pgpm.transmute('pgpm_t365.e'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t365.e'::regclass, '60000');
insert into pgpm_t365.e values (35005, 'frontier');
create table public.e365_ref (id bigint primary key, p_id bigint references pgpm_t365.e(id));
insert into public.e365_ref values (1, 35005);
select child_name as e_doomed, child_oid as e_oid from pgpm.part where parent_table = 'pgpm_t365.e'::regclass and lo = '0' \gset
select ok(not pgpm.retire('pgpm_t365.e', :'e_doomed') and pgpm_t365.armed() <> 'select 1', 'fixture: E: retire() dispatches the detach');
select pgpm_t365.armed() \gexec
update cron.job set command = 'select 1';
update pgpm.part set child_oid = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'pgpm_t365.e'::regclass and lo = '0';
select format('pgpm_t365.%I', :'e_doomed') as e_rel \gset
select ok(pgpm_t365.unrecorded('pgpm_t365.e') and to_regclass(:'e_rel')::oid = :'e_oid'::oid
          and not exists (select 1 from pg_inherits where inhrelid = :'e_oid'::oid),
  'LIVENESS: E: the mark records no oid, and the detached partition stands under its own name');
select ok(pgpm_t365.blocked(:'e_rel'), 'LIVENESS: E: it carries the block retire() put on it');
select is(pgpm._disown_unvouched_retirements(), 0, 'E: the install pass disowns nothing');
call pgpm.maintain('pgpm_t365.e');
select is(pgpm_t365.actions('pgpm_t365.e'), array['retain_detach', 'fail_retain_identity'],
  'E: retire() refuses it, logged as exactly fail_retain_identity');
select ok(pgpm_t365.method('pgpm_t365.e') like '%clear the mark%' and pgpm_t365.unrecorded('pgpm_t365.e'),
  'E: the mark is kept, and the refusal spells clearing it');
-- the repair the method spells for a table kept as the operator's own, run as written
select substring(pgpm_t365.method('pgpm_t365.e') from '(update pgpm\.part set retiring_at = null [^;]*;)') \gexec
select substring(pgpm_t365.method('pgpm_t365.e') from '(drop trigger if exists pgpm_write_block on [^;]*;)') \gexec
call pgpm.maintain('pgpm_t365.e');
select is(pgpm_t365.actions('pgpm_t365.e'), array['retain_detach', 'fail_retain_identity', 'fail_retain_drop'],
  'E: once the mark is cleared, it is refused as a table detached by hand');
select ok(not pgpm_t365.blocked(:'e_rel'), 'E: and no tick blocks it again');
select lives_ok(format('insert into %s values (34, ''mine'')', :'e_rel'), 'E: it is writable');
select is(pgpm_t365.ids(:'e_rel'), array[31, 32, 33, 34]::bigint[], 'E: and holds its rows');

-- ============================================================================================================
-- PART F: control, a row with no oid whose name denotes a partition of the parent is still blocked
-- ============================================================================================================
create table pgpm_t365.f (id bigint primary key, payload text);
insert into pgpm_t365.f values (41, 'orig'), (42, 'orig');
call pgpm.transmute('pgpm_t365.f'::regclass, 'id', 10000::bigint, p_retain => 25000, p_paused => false);
select pgpm.extend_to('pgpm_t365.f'::regclass, '60000');
select child_name as f_doomed, child_oid as f_oid from pgpm.part where parent_table = 'pgpm_t365.f'::regclass and lo = '0' \gset
update pgpm.part set child_oid = null where parent_table = 'pgpm_t365.f'::regclass and lo = '0';
select ok(exists (select 1 from pg_inherits where inhparent = 'pgpm_t365.f'::regclass and inhrelid = :'f_oid'::oid)
          and (select child_oid is null and retiring_oid is null from pgpm.part where parent_table = 'pgpm_t365.f'::regclass and lo = '0'),
  'LIVENESS: F: the row records no oid, and its name denotes its partition');
select ok(not pgpm_t365.blocked(format('pgpm_t365.%I', :'f_doomed')), 'LIVENESS: F: not blocked yet');
select pgpm._install_write_block('pgpm_t365.f'::regclass, :'f_doomed');
select ok(exists (select 1 from pg_trigger where tgrelid = :'f_oid'::oid and tgname = 'pgpm_write_block' and tgenabled = 'A'),
  'F: the partition, by its oid, is write-blocked');

select * from finish();
