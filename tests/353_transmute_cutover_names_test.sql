-- transmute's cutover makes its names from the table's name as the table has it, and never acts through a schema
-- swapped while it waited (issue #1367, and the sibling sites of #1355's mechanism).
--
-- THE BUG. _transmute read the table's schema and name once, in its unlocked preflight, and the cutover built the
-- staging name, the monolith's name and the second RENAME from them after phases 1 and 2 had let go of the table:
-- a RENAME committed between phase 2 and the cutover was silently undone, the converted table coming back under the
-- old name. And a lock on the table pins its own name, never its schema's: the cutover renders names in the
-- schema it read (the monolith's and staging names, the captured triggers and policies, the identity sequences'
-- grants) after waiting for OTHER objects' locks (an outgoing key's referenced table, an incoming key's referencing
-- table, a sequence), so a schema swapped during such a wait sent those statements to a namesake. The incoming-key
-- statements on a referencing table were named before their own wait in the same way: restore_incoming_fks put the
-- key on a namesake and marked the record restored, after which _forget_dangling_fks forgot it.
--
-- THE CONTRACT.
--   PART A  the table renamed between phase 2 and the cutover: the cutover's first lock is taken through the name
--           the preflight read (pgpm._lock_named_or_raise), so it refuses; the table keeps the name the operator
--           gave it, with the claim and the validated bound, and the documented remedy, transmute re-run on that
--           name, converts it under it.
--   PART B  the table's schema swapped while the cutover waits for an outgoing key's referenced table (step 7a,
--           behind a writer of that table): the schema is asked again after the wait (pgpm._nsp_held_or_raise),
--           so the cutover refuses and rolls back; the namesake gets neither the trigger nor the policy the cutover
--           replays by name, and the re-run converts the table, its trigger and policy on the parent.
--   PART C  restore_incoming_fks's ADD waits behind a writer of the referencing table while that table's schema is
--           swapped: the ADD's effect is checked by oid (pgpm._con_effect_or_raise), so the re-add is rolled back,
--           fail_restore_incoming_fk is logged and the record stays suspended; the namesake carries no key, and the
--           next call re-adds the key on the table pgpm recorded.
-- Every concurrent order is set by a lock queue and a server-side poll of pg_locks, one statement per sample, its
-- snapshot cleared. The holders take table locks with LOCK TABLE (no transaction id, so no other file's snapshot
-- waits on them). transmute runs in its own dblink session ('c353').
--
-- ASYMMETRIC FIXTURES: A's table holds ids 1..5; B's ids 1, 2, 3 against referenced ids 1, 2, 3, 4, its namesake
-- id 7; C's parent ids 1, 2, 3, its referencing table ids 10, 11 and its namesake id 19. Every check names a
-- relation by oid. No throws_* here: every call of the committing procedure runs in the dblink session.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(35);

-- p_pid is waiting, ungranted, for p_mode on p_oid
create function pg_temp.waits_for(p_pid int, p_oid oid, p_mode text) returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'relation' and l.relation = p_oid and l.mode = p_mode
                  and l.pid = p_pid) then
      return true;
    end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

-- n sessions are waiting, ungranted, for a lock on p_oid
create function pg_temp.waiters(p_oid oid, p_n int) returns boolean language plpgsql as $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if (select count(*) from pg_locks l where not l.granted and l.locktype = 'relation' and l.relation = p_oid) >= p_n then
      return true;
    end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

-- the ids a relation holds, read by its oid
create function pg_temp.ids_of(p_oid oid) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if not exists (select 1 from pg_class where oid = p_oid) then return null; end if;
  execute format('select array_agg(id order by id) from %s', p_oid::regclass) into v;
  return v;
end $$;

-- the outcome of the call a dblink session is running: 'OK', or its error message
create function pg_temp.outcome(p_conn text) returns text language plpgsql as $$
declare v text;
begin
  perform count(*) from dblink_get_result(p_conn, false) as t(x text);
  v := dblink_error_message(p_conn);
  perform count(*) from dblink_get_result(p_conn, false) as t(x text);
  return v;
end $$;

create function public.t353_trg() returns trigger language plpgsql as $$ begin return new; end $$;

select dblink_connect('h353', format('dbname=%s user=postgres', current_database())) as h \gset
select dblink_connect('g353', format('dbname=%s user=postgres', current_database())) as g \gset
select dblink_connect('r353', format('dbname=%s user=postgres', current_database())) as r \gset
select dblink_connect('c353', format('dbname=%s user=postgres options=-ctimezone=UTC', current_database())) as c \gset
select pid as c_pid from dblink('c353', 'select pg_backend_pid()') as t(pid int) \gset

-- ======================= (A) the table renamed between phase 2 and the cutover =======================
create schema a353;
create table a353.t (id bigint, ts timestamptz not null, primary key (id, ts));
insert into a353.t select g, now() - make_interval(hours => g) from generate_series(1, 5) g;
select 'a353.t'::regclass::oid as a_oid \gset
-- h parks phase 1, g then parks phase 2, and the rename queues behind phase 2: it is granted the moment phase 2
-- commits, after the preflight read the name and before the cutover's first lock
select dblink_exec('h353', 'begin') as a1 \gset
select count(*) as a_rows from dblink('h353', 'select count(*) from a353.t') as t(n bigint) \gset
select dblink_send_query('c353', $q$call pgpm.transmute('a353.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as a2 \gset
select ok(pg_temp.waits_for(:c_pid, :'a_oid'::oid, 'AccessExclusiveLock'), 'fixture: A: phase 1 waits behind a reader');
select dblink_exec('g353', 'begin') as a3 \gset
select dblink_send_query('g353', 'lock table a353.t in share update exclusive mode') as a4 \gset
select ok(pg_temp.waiters(:'a_oid'::oid, 2), 'fixture: A: a SHARE UPDATE EXCLUSIVE holder is queued behind phase 1');
select dblink_exec('h353', 'commit') as a5 \gset
select ok(pg_temp.waits_for(:c_pid, :'a_oid'::oid, 'ShareUpdateExclusiveLock'), 'LIVENESS: A: phase 2 waits behind the holder');
select dblink_send_query('r353', 'alter table a353.t rename to t_renamed') as a6 \gset
select ok(pg_temp.waiters(:'a_oid'::oid, 2), 'fixture: A: the rename is queued behind phase 2');
select count(*) as a_g1 from dblink_get_result('g353', false) as t(x text) \gset
select count(*) as a_g2 from dblink_get_result('g353', false) as t(x text) \gset
select dblink_exec('g353', 'commit') as a7 \gset
select is(pg_temp.outcome('r353'), 'OK', 'LIVENESS: A: the operator''s rename to t_renamed committed');
select pg_temp.outcome('c353') as a_msg \gset

select ok(:'a_msg' like '%transmute could not take its access share lock on a353.t_renamed (oid %) under the name a353.t it read before%',
  'A: the cutover refused the renamed table, naming the name it read and the name the table has now');
select is(to_regclass('a353.t_renamed')::oid, :'a_oid'::oid, 'A: the table keeps the name the operator gave it');
select is(to_regclass('a353.t'), null, 'A: and nothing was put back under the old name');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table::oid = :'a_oid'::oid)
          and (select convalidated from pg_constraint where conrelid = :'a_oid'::oid and conname = 'pgpm_monolith_bound'),
  'A: the claim and the validated bound stand, the resumable state');
select dblink_send_query('c353', $q$call pgpm.transmute('a353.t_renamed'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as a8 \gset
select is(pg_temp.outcome('c353'), 'OK', 'A: the remedy, transmute re-run on the table''s name now, completes');
select is((select parent_table::text from pgpm.config where monolith_oid = :'a_oid'::oid), 'a353.t_renamed',
  'A: the table is converted under the name the operator gave it');
select is(pg_temp.ids_of(to_regclass('a353.t_renamed')::oid), array[1, 2, 3, 4, 5]::bigint[], 'A: holding ids 1..5');

-- ======================= (B) the schema swapped while the cutover waits for a referenced table =======================
create schema r353;
create table r353.ref (id bigint primary key);
insert into r353.ref select generate_series(1, 4);
create schema b353;
create table b353.t (id bigint, ts timestamptz not null, ref_id bigint references r353.ref (id), primary key (id, ts));
insert into b353.t select g, now() - make_interval(hours => g), g from generate_series(1, 3) g;
create trigger t353_b before insert on b353.t for each row execute function public.t353_trg();
create policy t353_p on b353.t using (true);
select 'b353.t'::regclass::oid as b_oid \gset
select 'r353.ref'::regclass::oid as ref_oid \gset
-- a writer's lock on the referenced table (LOCK TABLE: no transaction id): 7a's ADD FOREIGN KEY waits behind it
select dblink_exec('h353', 'begin') as b1 \gset
select dblink_exec('h353', 'lock table r353.ref in row exclusive mode') as b2 \gset
select dblink_send_query('c353', $q$call pgpm.transmute('b353.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as b3 \gset
select ok(pg_temp.waits_for(:c_pid, :'ref_oid'::oid, 'ShareRowExclusiveLock'),
  'LIVENESS: B: the cutover waits for the referenced table''s lock, re-adding the outgoing key at the parent (7a)');
select dblink_exec('g353', 'alter schema b353 rename to b353_aside') as b4 \gset
select dblink_exec('g353', 'create schema b353') as b5 \gset
select dblink_exec('g353', 'create table b353.t (id bigint, ts timestamptz not null, ref_id bigint)') as b6 \gset
select dblink_exec('g353', $q$insert into b353.t values (7, now(), null)$q$) as b7 \gset
select dblink_exec('h353', 'commit') as b8 \gset
select pg_temp.outcome('c353') as b_msg \gset
select 'b353.t'::regclass::oid as b_squat \gset

select ok(:'b_squat'::oid <> :'b_oid'::oid, 'LIVENESS: B: the table''s schema name denotes the namesake''s now');
select ok(:'b_msg' like '%transmute names the table''s objects in its schema b353 (oid %), which was renamed or dropped while it waited for a lock; rolled back%',
  'B: the cutover refused, rolled back, saying the schema was renamed while it waited');
select is((select count(*)::int from pg_trigger where tgrelid = :'b_squat'::oid and not tgisinternal), 0,
  'B: the namesake carries none of the table''s triggers');
select is((select count(*)::int from pg_policy where polrelid = :'b_squat'::oid), 0, 'B: nor its policy');
select is((select relkind::text from pg_class where oid = :'b_oid'::oid), 'r', 'B: the table is still the plain table');
select is((select array_agg(tgname::text) from pg_trigger where tgrelid = :'b_oid'::oid and not tgisinternal), array['t353_b'],
  'B: with its trigger');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table::oid = :'b_oid'::oid), 'B: and the claim, resumable');
select dblink_send_query('c353', $q$call pgpm.transmute('b353_aside.t'::regclass, 'ts', interval '1 month', p_lock_timeout => '60s')$q$) as b9 \gset
select is(pg_temp.outcome('c353'), 'OK', 'B: the re-run on the table''s name now completes');
select is((select parent_table::text from pgpm.config where monolith_oid = :'b_oid'::oid), 'b353_aside.t', 'B: the table is converted');
select is((select array_agg(tgname::text) from pg_trigger where tgrelid = to_regclass('b353_aside.t') and not tgisinternal and tgparentid = 0),
  array['t353_b'], 'B: its trigger is on the parent');
select is((select array_agg(polname::text) from pg_policy where polrelid = to_regclass('b353_aside.t')), array['t353_p'],
  'B: and its policy');
select is((select confrelid from pg_constraint where conrelid = to_regclass('b353_aside.t') and contype = 'f'), :'ref_oid'::oid,
  'B: and its outgoing key references the referenced table');
select is(pg_temp.ids_of(to_regclass('b353_aside.t')::oid) || pg_temp.ids_of(:'b_squat'::oid), array[1, 2, 3, 7]::bigint[],
  'B: the table holds ids 1..3, the namesake 7');

-- ======================= (C) restore_incoming_fks's ADD, the referencing table's schema swapped =======================
create schema p353;
create table p353.par (id bigint primary key, payload text);
insert into p353.par select g, 'p' from generate_series(1, 3) g;
create schema c353s;
create table c353s.child (id bigint primary key, par_id bigint references p353.par (id));
insert into c353s.child values (10, 1), (11, 2);
call pgpm.transmute('p353.par', 'id', 1000, p_obtain => 2, p_paused => true, p_incoming_fks => 'preserve');
select 'c353s.child'::regclass::oid as child_oid \gset
select ok(exists (select 1 from pgpm.dropped_fk where parent_table = 'p353.par'::regclass and referencing_table::oid = :'child_oid'::oid
                    and constraint_name = 'child_par_id_fkey' and restored_at is null),
  'LIVENESS: C: the conversion suspended the incoming key and recorded it');
select dblink_exec('h353', 'begin') as c1 \gset
select dblink_exec('h353', 'lock table c353s.child in row exclusive mode') as c2 \gset
select dblink_send_query('c353', $q$select pgpm.restore_incoming_fks('p353.par'::regclass)$q$) as c3 \gset
select ok(pg_temp.waits_for(:c_pid, :'child_oid'::oid, 'ShareRowExclusiveLock'),
  'LIVENESS: C: the re-add waits for the referencing table''s lock behind a writer');
select dblink_exec('g353', 'alter schema c353s rename to c353s_aside') as c4 \gset
select dblink_exec('g353', 'create schema c353s') as c5 \gset
select dblink_exec('g353', 'create table c353s.child (id bigint, par_id bigint)') as c6 \gset
select dblink_exec('g353', 'insert into c353s.child values (19, 3)') as c7 \gset
select dblink_exec('h353', 'commit') as c8 \gset
select coalesce((select string_agg(n::text, ',') from dblink_get_result('c353', false) as t(n int)), 'none') as c_ret \gset
select dblink_error_message('c353') as c_msg \gset
select count(*) as c_drained from dblink_get_result('c353', false) as t(x text) \gset
select 'c353s.child'::regclass::oid as c_squat \gset

select ok(:'c_squat'::oid <> :'child_oid'::oid, 'LIVENESS: C: the referencing table''s name denotes the namesake now');
select is(:'c_ret'::text, '0', 'C: restore_incoming_fks re-added nothing');
select ok(exists (select 1 from pgpm.log where parent_table = 'p353.par'::regclass and action = 'fail_restore_incoming_fk'
                    and method like 'child_par_id_fkey: %reached another relation%'),
  'C: and logged fail_restore_incoming_fk, saying the ADD reached another relation');
select is((select count(*)::int from pg_constraint where conrelid = :'c_squat'::oid and contype = 'f'), 0,
  'C: the namesake carries no foreign key');
select ok(exists (select 1 from pgpm.dropped_fk where referencing_table::oid = :'child_oid'::oid
                    and constraint_name = 'child_par_id_fkey' and restored_at is null),
  'C: the record stays suspended');
select is(pgpm.restore_incoming_fks('p353.par'::regclass), 1, 'C: the next call re-adds the key');
select is((select confrelid from pg_constraint where conrelid = :'child_oid'::oid and conname = 'child_par_id_fkey'),
  'p353.par'::regclass::oid, 'C: on the table pgpm recorded, referencing the managed parent');

select dblink_disconnect(n) from unnest(array['h353', 'g353', 'r353', 'c353']) n;
select * from finish();
