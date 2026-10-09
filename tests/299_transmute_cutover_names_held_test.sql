-- Issues #1080, #1104 and #1105 (bullet 1): the two names the cutover takes, the staging name <table>_pgpm_new
-- its CREATE TABLE builds the new parent under and the monolith's name <table>_p<lo>_to_<hi> its RENAME gives
-- the table, are refused in pgpm's words when something holds them by the time the cutover takes them.
--
-- Each was asked up front only (the staging name in the preflight, #344 as a relation and #671 as a type; the
-- monolith's in phase 1's transaction, #509 and #671). A relation or a type committed at either after that,
-- while phases 1 and 2 had let go of the table, or created by a transaction still open when the cutover
-- reached the name, made the cutover's CREATE or RENAME die raw (42P07, 42710, or 23505 on the catalog's name
-- index once the other transaction committed), after phases 1 and 2 had committed the write-rejecting bound
-- and the claim, naming neither pgpm nor the remedy. No lock on the table keeps a name in its schema free, so
-- the cutover now asks the up-front question again from the failure of the statement that takes the name,
-- when the holder is committed and visible, and refuses in the up-front words; the refusal rolls the cutover
-- back to the resumable phase-2 state.
--
-- Two kinds of window. A COMMITTED holder is made the way tests/283 opens its windows: an event trigger on
-- phase 1's ADD of pgpm_monolith_bound (after both up-front askings, in the transaction that commits the
-- bound) takes the name, in the transmuting session, so it commits with phase 1. An IN-FLIGHT holder is a
-- second dblink session (k299) that creates it in a transaction left open, waits server-side until a backend
-- holding the table waits on that transaction (the cutover's CREATE or RENAME), records that it saw the wait,
-- and commits. The transmute runs over dblink, as a top-level CALL whose phases can commit. Fixtures,
-- asymmetric on purpose:
--   (A) t299a: a TABLE public.t299a_pgpm_new arrives (committed), while a table of the same name in another
--       schema (s299.t299a_pgpm_new) has been there from the start; refused naming the public one; with it
--       dropped, the re-run converts, and the other schema's table is untouched;
--   (B) t299b: an enum TYPE public.t299b_pgpm_new arrives (committed); refused naming it as a type; with it
--       dropped, the re-run converts;
--   (C) t299c: a table at the monolith's name t299c_p<0>_to_<300> arrives (committed); refused naming it;
--       with it dropped, the re-run converts and the monolith takes that name;
--   (D) t299d: a table at the staging name is in flight when the cutover's CREATE reaches it; refused;
--       with it dropped, the re-run converts;
--   (E) t299e: a table at the monolith's name t299e_p<0>_to_<200> is in flight when the RENAME reaches it;
--       refused.
--   (F) t299f, from a session whose default_transaction_isolation is REPEATABLE READ, with a table at its
--       staging name in flight: refused up front (#1105), before anything is committed, because a second
--       asking from a snapshot older than the holder's commit would see nothing and let the raw error out;
--       from a READ COMMITTED session, once the holder is gone, the same call converts.
--   (G) t299g: an enum at the staging name's ARRAY type name, _t299g_pgpm_new, is in flight when the CREATE
--       reaches it (the CREATE takes that name for the new parent's array type); refused naming it; with it
--       dropped, the re-run converts;
--   (H) t299h: an enum at the monolith's array type name, _t299h_p<0>_to_<200>, is in flight when the RENAME
--       reaches it (the RENAME renames the table's array type to it); refused naming it.
--   (I) t299i: an enum at the table's OWN array type name, _t299i, is in flight when the RENAME reaches it
--       (creating it moved t299i's array type aside, so the RENAME's update of that row waits and then fails
--       "tuple concurrently updated"); refused naming it; with it dropped, the re-run converts.
--   (J) _t299j, a table whose name starts with an underscore: its staging name _t299j_pgpm_new is the
--       implicit array type name of a type called t299j_pgpm_new, and an enum of that name is in flight when
--       the CREATE reaches it; refused naming the array type; with the enum dropped, the re-run converts;
--   (K) _t299k: likewise its monolith's name is the array type name of an in-flight enum
--       t299k_p<0>_to_<200>, when the first RENAME reaches it; refused; with the enum dropped, the re-run
--       converts;
--   (L) t299l, a table whose own array type is NOT named _t299l (a type held that name when the table was
--       created, since dropped): an enum _t299l is in flight when the second RENAME (the new parent to
--       t299l) gives the new parent's array type that name; refused; with the enum dropped, the re-run
--       converts.
--   (M) not a name at all: t299m is converted first, so its monolith's implicit array type holds the name
--       _t299m's monolith will take (no obstacle: PostgreSQL steps around it); a GRANT on _t299m, in a
--       transaction left open, commits while _t299m's first RENAME waits on it, which fails that RENAME with
--       XX000 "tuple concurrently updated". The error goes out as it came, NOT blamed on that array type,
--       and the re-run converts _t299m with the array type left in place. On PostgreSQL 18 a GRANT takes
--       ACCESS SHARE on the table, so it queues behind the cutover's lock and cannot race the RENAME at all;
--       the file probes for that and skips the race's three assertions there (the discriminate and perf
--       tracks run on 17, where the race opens).
--   A COMMITTED type at either array name is no obstacle (PostgreSQL picks another array name past it), so
--   only the in-flight holder is refused, and only by the cutover.
-- Every refusal is pinned by its message (throws_like), and each is paired with witnesses that the window
-- opened (once), that its holder committed, and that phases 1 and 2 had committed before the refusal.
-- bench/transmute_cutover_names_held.sh runs this file against the mutants that drop each statement's second
-- asking (transmute_staging_name_preflight_only, transmute_monolith_name_preflight_only) and the one that
-- drops the isolation refusal (transmute_isolation_unchecked) and the one that drops the array-name half of
-- the general one in each naming statement's handler (transmute_create_held_names_unchecked,
-- transmute_rename_held_names_unchecked, transmute_final_rename_unhandled) and the one that drops the first
-- RENAME's XX000 arm (transmute_own_array_unchecked), and the one that lets that arm blame a holder that was
-- already there (transmute_xx000_blames_preexisting).
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(100);

set timezone = 'UTC';

create table public.t299a (id bigint primary key, v text not null);
insert into public.t299a select g, 'a' || g from generate_series(1, 150) g;   -- step 100: monolith [0, 200)
create table public.t299b (id bigint primary key, v text not null);
insert into public.t299b select g, 'b' || g from generate_series(1, 250) g;   -- step 100: monolith [0, 300)
create table public.t299c (id bigint primary key, v text not null);
insert into public.t299c select g, 'c' || g from generate_series(1, 250) g;   -- step 100: monolith [0, 300)
create table public.t299d (id bigint primary key, v text not null);
insert into public.t299d select g, 'd' || g from generate_series(1, 120) g;   -- step 100: monolith [0, 200)
create table public.t299e (id bigint primary key, v text not null);
insert into public.t299e select g, 'e' || g from generate_series(1, 150) g;   -- step 100: monolith [0, 200)
create table public.t299f (id bigint primary key, v text not null);
insert into public.t299f select g, 'f' || g from generate_series(1, 140) g;   -- step 100: monolith [0, 200)
create table public.t299g (id bigint primary key, v text not null);
insert into public.t299g select g, 'g' || g from generate_series(1, 110) g;   -- step 100: monolith [0, 200)
create table public.t299h (id bigint primary key, v text not null);
insert into public.t299h select g, 'h' || g from generate_series(1, 130) g;   -- step 100: monolith [0, 200)
create table public.t299i (id bigint primary key, v text not null);
insert into public.t299i select g, 'i' || g from generate_series(1, 170) g;   -- step 100: monolith [0, 200)
create table public."_t299j" (id bigint primary key, v text not null);
insert into public."_t299j" select g, 'j' || g from generate_series(1, 160) g;   -- step 100: monolith [0, 200)
create table public."_t299k" (id bigint primary key, v text not null);
insert into public."_t299k" select g, 'k' || g from generate_series(1, 120) g;   -- step 100: monolith [0, 200)
-- t299l's own array type is named past a type that held _t299l when it was created, and that type is gone
create type public."_t299l" as enum ('old');
create table public.t299l (id bigint primary key, v text not null);
insert into public.t299l select g, 'l' || g from generate_series(1, 180) g;   -- step 100: monolith [0, 200)
drop type public."_t299l";
create table public.t299m (id bigint primary key, v text not null);
insert into public.t299m select g, 'm' || g from generate_series(1, 150) g;   -- step 100: monolith [0, 200)
create table public."_t299m" (id bigint primary key, v text not null);
insert into public."_t299m" select g, 'n' || g from generate_series(1, 170) g;   -- step 100: monolith [0, 200)
create sequence public.w299m_seq;
-- roles are cluster-wide: created only when absent, dropped at the end with what they own
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't299_reader') then create role t299_reader; end if;
end $$;
-- (M)'s racer, run by k299 as ONE statement: GRANT on p_rel, wait until a backend holding p_rel's ACCESS
-- EXCLUSIVE waits on this transaction, record whether it was seen, and return, which commits the GRANT
create function public.t299_grant_hold(p_rel regclass, p_tag text) returns void language plpgsql as $$
declare v_saw boolean := false;
begin
  execute format('grant select on %s to t299_reader', p_rel);
  for i in 1 .. 1200 loop
    v_saw := exists (select 1 from pg_locks w join pg_locks h on h.pid = w.pid
                      where w.locktype = 'transactionid' and not w.granted
                        and w.transactionid = txid_current()::text::xid
                        and h.relation = p_rel and h.granted and h.mode = 'AccessExclusiveLock');
    exit when v_saw;
    perform pg_sleep(0.05);
  end loop;
  insert into public.w299_seen values (p_tag, v_saw);
end $$;

-- the same name in another schema, there from the start: the staging name is schema-qualified, so this one
-- never stands in the way, and must outlive both conversions
create schema s299;
create table s299.t299a_pgpm_new (keep int);
insert into s299.t299a_pgpm_new values (299);

-- a refusal rolls the cutover back but not a nextval, so each window witnesses on its own sequence
create sequence public.w299a_seq;
create sequence public.w299b_seq;
create sequence public.w299c_seq;

-- The in-flight holder, run by k299 as ONE statement (so its transaction is open until it returns): create
-- the name, wait until a backend that holds a lock on p_rel waits on this transaction, record whether it was
-- seen, and return, which commits the name. Polled server-side: pg_locks is read live on each iteration.
create table public.w299_seen (tag text primary key, saw boolean not null);
create function public.t299_hold(p_ddl text, p_rel regclass, p_tag text) returns void language plpgsql as $$
declare v_saw boolean := false;
begin
  execute p_ddl;
  for i in 1 .. 1200 loop
    v_saw := exists (select 1 from pg_locks w join pg_locks h on h.pid = w.pid
                      where w.locktype = 'transactionid' and not w.granted
                        and w.transactionid = txid_current()::text::xid
                        and h.relation = p_rel and h.granted);
    exit when v_saw;
    perform pg_sleep(0.05);
  end loop;
  insert into public.w299_seen values (p_tag, v_saw);
end $$;
-- and the main session's wait for k299 to have created its name and started polling
create function public.t299_await_hold(p_pid int) returns boolean language plpgsql as $$
begin
  for i in 1 .. 400 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = p_pid and wait_event = 'PgSleep') then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

create function public.t299_inject() returns event_trigger language plpgsql as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    -- phase 1's ADD of the bound: after the preflight, committed with the bound. Once each. By objid, not
    -- by a name cast: the cutover's rename is an ALTER TABLE too, and the name is gone by its end.
    if r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t299a'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w299a_seq) then
      perform nextval('public.w299a_seq');
      create table public.t299a_pgpm_new (x int);
    elsif r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t299b'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w299b_seq) then
      perform nextval('public.w299b_seq');
      create type public.t299b_pgpm_new as enum ('x');
    elsif r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t299c'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w299c_seq) then
      perform nextval('public.w299c_seq');
      create table public.t299c_p0000000000000000000_to_0000000000000000300 (x int);
    elsif r.command_tag = 'ALTER TABLE' and r.object_identity = 'public._t299m'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w299m_seq) then
      -- (M)'s first attempt is stopped in its cutover, so the attempt the GRANT races resumes past phases
      -- 1 and 2, whose own ALTERs would otherwise queue behind the open GRANT
      perform nextval('public.w299m_seq');
      create table public."_t299m_pgpm_new" (x int);
    end if;
  end loop;
end $$;
create event trigger t299_inject on ddl_command_end when tag in ('ALTER TABLE') execute function public.t299_inject();

select dblink_connect('t299', 'dbname=' || current_database());
select dblink_connect('k299', 'dbname=' || current_database());
create temp table k299_pid as select pid from dblink('k299', 'select pg_backend_pid()') as x(pid int);

-- ====================================================================================================
-- (A) a table committed at the staging name after the preflight
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299a'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'pg_partition_magician: public.t299a_pgpm_new already exists, and transmute needs it as a staging name for the new parent.%',
  '(A) the cutover refuses the table committed at the staging name after the preflight, naming it, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w299a_seq), '1:true',
  'LIVENESS: (A) the window created the squatter once, inside phase 1');
select is((select relkind::text || '/' || relnatts from pg_class where oid = to_regclass('public.t299a_pgpm_new')), 'r/1',
  'LIVENESS: (A) the squatter public.t299a_pgpm_new (one column, x) committed with phase 1');
select is((select convalidated from pg_constraint where conrelid = 'public.t299a'::regclass and conname = 'pgpm_monolith_bound'), true,
  'LIVENESS: (A) phase 2 validated the bound before the cutover');
select is((select relkind::text from pg_class where oid = 'public.t299a'::regclass), 'r',
  '(A) t299a is still the plain table');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299a'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t299a'::regclass),
  '(A) the claim stands and nothing was registered: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t299', 'drop table public.t299a_pgpm_new') $$,
  'LIVENESS: (A) the operator takes the remedy the refusal names, dropping the squatter');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299a'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(A) the re-run resumes and converts t299a');
select is((select relkind::text from pg_class where oid = 'public.t299a'::regclass), 'p',
  'LIVENESS: (A) t299a is partitioned now');
select lives_ok($$ insert into public.t299a values (210, 'past') $$, 'LIVENESS: (A) a row past the monolith is accepted');
select isnt((select tableoid from public.t299a where id = 210),
            (select monolith_oid from pgpm.config where parent_table = 'public.t299a'::regclass),
  'LIVENESS: (A) and it landed in a forward partition, not the monolith');
select is((select array_agg(id order by id) from public.t299a where id > 147), array[148, 149, 150, 210]::bigint[],
  '(A) the rows are the ones written');
select is((select array_agg(keep) from s299.t299a_pgpm_new), array[299],
  '(A) the same name in another schema was never in the way, and is untouched');

-- ====================================================================================================
-- (B) a type committed at the staging name after the preflight
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299b'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'pg_partition_magician: public.t299b_pgpm_new already exists as %, and transmute needs that name as a staging name for the new parent%',
  '(B) the cutover refuses the type committed at the staging name after the preflight, naming it, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w299b_seq), '1:true',
  'LIVENESS: (B) the window created the squatter once, inside phase 1');
select is((select typtype::text from pg_type where typname = 't299b_pgpm_new' and typnamespace = 'public'::regnamespace), 'e',
  'LIVENESS: (B) the enum public.t299b_pgpm_new committed with phase 1');
select is((select convalidated from pg_constraint where conrelid = 'public.t299b'::regclass and conname = 'pgpm_monolith_bound'), true,
  'LIVENESS: (B) phase 2 validated the bound before the cutover');
select is((select relkind::text from pg_class where oid = 'public.t299b'::regclass), 'r',
  '(B) t299b is still the plain table');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299b'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t299b'::regclass),
  '(B) the claim stands and nothing was registered: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t299', 'drop type public.t299b_pgpm_new') $$,
  'LIVENESS: (B) the operator takes the remedy the refusal names, dropping the type');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299b'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(B) the re-run resumes and converts t299b');
select is((select relkind::text from pg_class where oid = 'public.t299b'::regclass), 'p',
  'LIVENESS: (B) t299b is partitioned now');

-- ====================================================================================================
-- (C) a table committed at the monolith's name after phase 1 asked
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299c'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'pg_partition_magician: public.t299c_p0000000000000000000_to_0000000000000000300 already exists, and transmute needs that name for the monolith%',
  '(C) the cutover refuses the table committed at the monolith''s name after phase 1 asked, naming it, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w299c_seq), '1:true',
  'LIVENESS: (C) the window created the holder once, inside phase 1');
select is((select relkind::text || '/' || relnatts from pg_class
            where oid = to_regclass('public.t299c_p0000000000000000000_to_0000000000000000300')), 'r/1',
  'LIVENESS: (C) the holder (one column, x) committed with phase 1');
select is((select convalidated from pg_constraint where conrelid = 'public.t299c'::regclass and conname = 'pgpm_monolith_bound'), true,
  'LIVENESS: (C) phase 2 validated the bound before the cutover');
select is((select relkind::text from pg_class where oid = 'public.t299c'::regclass), 'r',
  '(C) t299c is still the plain table');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299c'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t299c'::regclass),
  '(C) the claim stands and nothing was registered: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t299', 'drop table public.t299c_p0000000000000000000_to_0000000000000000300') $$,
  'LIVENESS: (C) the operator takes the remedy the refusal names, dropping the holder');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299c'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(C) the re-run resumes and converts t299c');
select is((select relkind::text from pg_class where oid = 'public.t299c'::regclass), 'p',
  'LIVENESS: (C) t299c is partitioned now');
select is((select relname::text from pg_class
            where oid = (select monolith_oid from pgpm.config where parent_table = 'public.t299c'::regclass)),
  't299c_p0000000000000000000_to_0000000000000000300',
  '(C) and the monolith carries the name the holder had');

-- ====================================================================================================
-- (D) a table at the staging name, created by a transaction still open when the cutover's CREATE reaches it
-- ====================================================================================================
select dblink_send_query('k299', $q$ select public.t299_hold('create table public.t299d_pgpm_new (x int)', 'public.t299d', 'D') $q$);
select ok(public.t299_await_hold((select pid from k299_pid)) and to_regclass('public.t299d_pgpm_new') is null,
  'LIVENESS: (D) k299 created t299d_pgpm_new in a transaction still open, invisible to the preflight');
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299d'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public.t299d_pgpm_new already exists, and transmute needs it as a staging name for the new parent.%',
  '(D) the cutover refuses the staging name an open transaction was creating, once it commits, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k299') as x(s text);
  perform * from dblink_get_result('k299') as x(s text);
end $$;
select is((select saw from public.w299_seen where tag = 'D'), true,
  'LIVENESS: (D) the cutover, holding t299d, waited on k299''s transaction before it committed');
select is((select relkind::text || '/' || relnatts from pg_class where oid = to_regclass('public.t299d_pgpm_new')), 'r/1',
  'LIVENESS: (D) k299''s t299d_pgpm_new (one column, x) committed');
select ok((select convalidated from pg_constraint where conrelid = 'public.t299d'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t299d'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299d'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t299d'::regclass),
  '(D) the validated bound and the claim stand, t299d is still the plain table: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t299', 'drop table public.t299d_pgpm_new') $$,
  'LIVENESS: (D) the operator takes the remedy the refusal names, dropping the holder');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299d'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(D) the re-run resumes and converts t299d');

-- ====================================================================================================
-- (E) a table at the monolith's name, created by a transaction still open when the RENAME reaches it
-- ====================================================================================================
select dblink_send_query('k299', $q$ select public.t299_hold('create table public.t299e_p0000000000000000000_to_0000000000000000200 (x int)', 'public.t299e', 'E') $q$);
select ok(public.t299_await_hold((select pid from k299_pid))
          and to_regclass('public.t299e_p0000000000000000000_to_0000000000000000200') is null,
  'LIVENESS: (E) k299 created the monolith''s name in a transaction still open, invisible to phase 1');
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299e'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public.t299e_p0000000000000000000_to_0000000000000000200 already exists, and transmute needs that name for the monolith%',
  '(E) the cutover refuses the monolith''s name an open transaction was creating, once it commits, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k299') as x(s text);
  perform * from dblink_get_result('k299') as x(s text);
end $$;
select is((select saw from public.w299_seen where tag = 'E'), true,
  'LIVENESS: (E) the cutover, holding t299e, waited on k299''s transaction before it committed');
select is((select relkind::text || '/' || relnatts from pg_class
            where oid = to_regclass('public.t299e_p0000000000000000000_to_0000000000000000200')), 'r/1',
  'LIVENESS: (E) k299''s holder (one column, x) committed');
select ok((select convalidated from pg_constraint where conrelid = 'public.t299e'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t299e'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299e'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t299e'::regclass),
  '(E) the validated bound and the claim stand, t299e is still the plain table: the resumable phase-2 state');

-- ====================================================================================================
-- (F) REPEATABLE READ, with a staging-name holder in flight: refused up front, nothing committed
-- ====================================================================================================
select dblink_connect('r299', 'dbname=' || current_database());
select dblink_exec('r299', 'set default_transaction_isolation = ''repeatable read''');
select is((select s from dblink('r299', 'select current_setting(''transaction_isolation'')') as x(s text)),
  'repeatable read',
  'LIVENESS: (F) the r299 session''s transactions are REPEATABLE READ');
select dblink_send_query('k299', $q$ select public.t299_hold('create table public.t299f_pgpm_new (x int)', 'public.t299f', 'F') $q$);
select ok(public.t299_await_hold((select pid from k299_pid)) and to_regclass('public.t299f_pgpm_new') is null,
  'LIVENESS: (F) k299 holds t299f_pgpm_new in a transaction still open, ready to commit once the cutover waits on it');
select throws_like(
  $$ select dblink_exec('r299', 'call pgpm.transmute(''public.t299f'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: transmute(t299f) must run in READ COMMITTED transactions (this one is repeatable read, %',
  '(F) transmute refuses a REPEATABLE READ session up front, in pgpm''s words');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.t299f'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299f'::regclass)
          and (select relkind::text from pg_class where oid = 'public.t299f'::regclass) = 'r',
  '(F) nothing was committed: no bound, no claim, t299f is still the plain table');
-- the holder is never waited on now, so it is cancelled, which rolls its CREATE back
select dblink_cancel_query('k299');
do $$ begin
  perform * from dblink_get_result('k299', false) as x(s text);
  perform * from dblink_get_result('k299', false) as x(s text);
end $$;
select ok(to_regclass('public.t299f_pgpm_new') is null and not exists (select 1 from public.w299_seen where tag = 'F'),
  'LIVENESS: (F) the cancelled holder never committed');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299f'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(F) the same call from a READ COMMITTED session converts t299f');
select is((select relkind::text from pg_class where oid = 'public.t299f'::regclass), 'p',
  'LIVENESS: (F) t299f is partitioned now');

-- ====================================================================================================
-- (G) a type at the staging name's array type name, created by a transaction still open at the CREATE
-- ====================================================================================================
select dblink_send_query('k299', $q$ select public.t299_hold('create type public."_t299g_pgpm_new" as enum (''x'')', 'public.t299g', 'G') $q$);
select ok(public.t299_await_hold((select pid from k299_pid))
          and to_regtype('public."_t299g_pgpm_new"') is null and to_regclass('public.t299g_pgpm_new') is null,
  'LIVENESS: (G) k299 created _t299g_pgpm_new in a transaction still open; nothing holds the staging name itself');
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299g'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public._t299g_pgpm_new already exists as an enum type, and the cutover''s CREATE of the new parent public.t299g_pgpm_new takes that name%',
  '(G) the cutover refuses the type at the staging name''s array type name, once it commits, naming it, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k299') as x(s text);
  perform * from dblink_get_result('k299') as x(s text);
end $$;
select is((select saw from public.w299_seen where tag = 'G'), true,
  'LIVENESS: (G) the cutover, holding t299g, waited on k299''s transaction before it committed');
select is((select typtype::text from pg_type where typname = '_t299g_pgpm_new' and typnamespace = 'public'::regnamespace), 'e',
  'LIVENESS: (G) k299''s enum _t299g_pgpm_new committed');
select ok((select convalidated from pg_constraint where conrelid = 'public.t299g'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t299g'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299g'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t299g'::regclass),
  '(G) the validated bound and the claim stand, t299g is still the plain table: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t299', 'drop type public."_t299g_pgpm_new"') $$,
  'LIVENESS: (G) the operator takes the remedy the refusal names, dropping the type');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299g'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(G) the re-run resumes and converts t299g');

-- ====================================================================================================
-- (H) a type at the monolith's array type name, created by a transaction still open at the RENAME
-- ====================================================================================================
select dblink_send_query('k299', $q$ select public.t299_hold('create type public."_t299h_p0000000000000000000_to_0000000000000000200" as enum (''x'')', 'public.t299h', 'H') $q$);
select ok(public.t299_await_hold((select pid from k299_pid))
          and to_regtype('public."_t299h_p0000000000000000000_to_0000000000000000200"') is null
          and to_regclass('public.t299h_p0000000000000000000_to_0000000000000000200') is null,
  'LIVENESS: (H) k299 created the monolith''s array type name in a transaction still open; nothing holds the monolith''s name itself');
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299h'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public._t299h_p0000000000000000000_to_0000000000000000200 already exists as an enum type, and the cutover''s RENAME of public.t299h to the monolith''s name takes that name%',
  '(H) the cutover refuses the type at the monolith''s array type name, once it commits, naming it, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k299') as x(s text);
  perform * from dblink_get_result('k299') as x(s text);
end $$;
select is((select saw from public.w299_seen where tag = 'H'), true,
  'LIVENESS: (H) the cutover, holding t299h, waited on k299''s transaction before it committed');
select is((select typtype::text from pg_type
            where typname = '_t299h_p0000000000000000000_to_0000000000000000200' and typnamespace = 'public'::regnamespace), 'e',
  'LIVENESS: (H) k299''s enum committed');
select ok((select convalidated from pg_constraint where conrelid = 'public.t299h'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t299h'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299h'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t299h'::regclass),
  '(H) the validated bound and the claim stand, t299h is still the plain table: the resumable phase-2 state');

-- ====================================================================================================
-- (I) a type at the table's own array type name, created by a transaction still open at the RENAME
-- ====================================================================================================
select dblink_send_query('k299', $q$ select public.t299_hold('create type public."_t299i" as enum (''x'')', 'public.t299i', 'I') $q$);
select ok(public.t299_await_hold((select pid from k299_pid))
          and (select typname::text from pg_type where oid = (select typarray from pg_type where oid = 'public.t299i'::regtype)) = '_t299i',
  'LIVENESS: (I) k299 created an enum _t299i in a transaction still open; t299i''s array type is still _t299i as committed');
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299i'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public._t299i already exists as an enum type, and the cutover''s RENAME of public.t299i to the monolith''s name takes that name%',
  '(I) the cutover refuses the type at the table''s own array type name, once it commits, naming it, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k299') as x(s text);
  perform * from dblink_get_result('k299') as x(s text);
end $$;
select is((select saw from public.w299_seen where tag = 'I'), true,
  'LIVENESS: (I) the cutover, holding t299i, waited on k299''s transaction before it committed');
select is((select typtype::text from pg_type where typname = '_t299i' and typnamespace = 'public'::regnamespace), 'e',
  'LIVENESS: (I) k299''s enum _t299i committed');
select ok((select convalidated from pg_constraint where conrelid = 'public.t299i'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t299i'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299i'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t299i'::regclass),
  '(I) the validated bound and the claim stand, t299i is still the plain table: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t299', 'drop type public."_t299i"') $$,
  'LIVENESS: (I) the operator takes the remedy the refusal names, dropping the type');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299i'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(I) the re-run resumes and converts t299i');

-- ====================================================================================================
-- (J) a table named _t299j: its staging name is the array type name of an in-flight enum
-- ====================================================================================================
select dblink_send_query('k299', $q$ select public.t299_hold('create type public.t299j_pgpm_new as enum (''x'')', 'public._t299j', 'J') $q$);
select ok(public.t299_await_hold((select pid from k299_pid)) and to_regclass('public._t299j_pgpm_new') is null and to_regtype('public.t299j_pgpm_new') is null,
  'LIVENESS: (J) k299 holds the name in a transaction still open, invisible to the up-front checks');
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public._t299j'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public._t299j_pgpm_new already exists as the array type of t299j_pgpm_new, and the cutover''s CREATE of the new parent public._t299j_pgpm_new takes that name%',
  '(J) the cutover refuses the in-flight implicit array type at the staging name, naming it and its element type, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k299') as x(s text);
  perform * from dblink_get_result('k299') as x(s text);
end $$;
select is((select saw from public.w299_seen where tag = 'J'), true,
  'LIVENESS: (J) the cutover, holding the table, waited on k299''s transaction before it committed');
select ok((select t.typname::text from pg_type t join pg_type e on e.typarray = t.oid where e.typname = 't299j_pgpm_new' and e.typtype = 'e') = '_t299j_pgpm_new',
  'LIVENESS: (J) k299''s enum t299j_pgpm_new committed, its array type named _t299j_pgpm_new');
select ok((select convalidated from pg_constraint where conrelid = 'public._t299j'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public._t299j'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public._t299j'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public._t299j'::regclass),
  '(J) the validated bound and the claim stand, the table is still plain: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t299', 'drop type public.t299j_pgpm_new') $$,
  'LIVENESS: (J) the operator takes the remedy the refusal names, dropping the type');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public._t299j'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(J) the re-run resumes and converts the table');

-- ====================================================================================================
-- (K) a table named _t299k: its monolith's name is the array type name of an in-flight enum
-- ====================================================================================================
select dblink_send_query('k299', $q$ select public.t299_hold('create type public.t299k_p0000000000000000000_to_0000000000000000200 as enum (''x'')', 'public._t299k', 'K') $q$);
select ok(public.t299_await_hold((select pid from k299_pid)) and to_regtype('public.t299k_p0000000000000000000_to_0000000000000000200') is null,
  'LIVENESS: (K) k299 holds the name in a transaction still open, invisible to the up-front checks');
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public._t299k'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public._t299k_p0000000000000000000_to_0000000000000000200 already exists as the array type of t299k_p0000000000000000000_to_0000000000000000200, and the cutover''s RENAME of public._t299k to the monolith''s name takes that name%',
  '(K) the cutover refuses the in-flight implicit array type at the monolith''s name, naming it and its element type, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k299') as x(s text);
  perform * from dblink_get_result('k299') as x(s text);
end $$;
select is((select saw from public.w299_seen where tag = 'K'), true,
  'LIVENESS: (K) the cutover, holding the table, waited on k299''s transaction before it committed');
select ok((select t.typname::text from pg_type t join pg_type e on e.typarray = t.oid where e.typname = 't299k_p0000000000000000000_to_0000000000000000200' and e.typtype = 'e') = '_t299k_p0000000000000000000_to_0000000000000000200',
  'LIVENESS: (K) k299''s enum committed, its array type named as the monolith would be');
select ok((select convalidated from pg_constraint where conrelid = 'public._t299k'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public._t299k'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public._t299k'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public._t299k'::regclass),
  '(K) the validated bound and the claim stand, the table is still plain: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t299', 'drop type public.t299k_p0000000000000000000_to_0000000000000000200') $$,
  'LIVENESS: (K) the operator takes the remedy the refusal names, dropping the type');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public._t299k'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(K) the re-run resumes and converts the table');

-- ====================================================================================================
-- (L) the second RENAME: an in-flight enum at _t299l, the array type name it gives the new parent
-- ====================================================================================================
select dblink_send_query('k299', $q$ select public.t299_hold('create type public."_t299l" as enum (''x'')', 'public.t299l', 'L') $q$);
select ok(public.t299_await_hold((select pid from k299_pid)) and (select t.typname::text from pg_type t where t.oid = (select typarray from pg_type where oid = 'public.t299l'::regtype)) <> '_t299l' and to_regtype('public."_t299l"') is null,
  'LIVENESS: (L) k299 holds the name in a transaction still open, invisible to the up-front checks');
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299l'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public._t299l already exists as an enum type, and the cutover''s RENAME of the new parent to public.t299l takes that name%',
  '(L) the cutover refuses the in-flight type at the array type name the second RENAME takes, naming it, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k299') as x(s text);
  perform * from dblink_get_result('k299') as x(s text);
end $$;
select is((select saw from public.w299_seen where tag = 'L'), true,
  'LIVENESS: (L) the cutover, holding the table, waited on k299''s transaction before it committed');
select ok((select typtype::text from pg_type where typname = '_t299l' and typnamespace = 'public'::regnamespace) = 'e',
  'LIVENESS: (L) k299''s enum _t299l committed');
select ok((select convalidated from pg_constraint where conrelid = 'public.t299l'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t299l'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t299l'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t299l'::regclass),
  '(L) the validated bound and the claim stand, the table is still plain: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t299', 'drop type public."_t299l"') $$,
  'LIVENESS: (L) the operator takes the remedy the refusal names, dropping the type');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299l'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(L) the re-run resumes and converts the table');

-- ====================================================================================================
-- (M) a GRANT racing the first RENAME: XX000 not blamed on a holder PostgreSQL steps around
-- ====================================================================================================
select lives_ok($$ select dblink_exec('t299', 'call pgpm.transmute(''public.t299m'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'LIVENESS: (M) t299m converts');
select is((select t.typname::text from pg_type t join pg_type e on e.typarray = t.oid
            where e.typname = 't299m_p0000000000000000000_to_0000000000000000200' and e.typrelid <> 0),
  '_t299m_p0000000000000000000_to_0000000000000000200',
  'LIVENESS: (M) t299m''s monolith''s array type holds _t299m''s monolith name, committed before _t299m''s cutover');
select throws_like(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public._t299m'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'pg_partition_magician: public._t299m_pgpm_new already exists, and transmute needs it as a staging name%',
  'LIVENESS: (M) the first attempt at _t299m stops in its cutover, past phases 1 and 2');
select lives_ok($$ select dblink_exec('t299', 'drop table public."_t299m_pgpm_new"') $$,
  'LIVENESS: (M) its staging-name holder is dropped, so the next attempt resumes into the cutover');
-- does a GRANT here take a lock on the table (PostgreSQL 18), which would serialize it behind the cutover?
select dblink_exec('k299', 'begin');
select dblink_exec('k299', 'grant select on public."_t299m" to t299_reader');
create temp table m299_probe as
  select not exists (select 1 from pg_locks where pid = (select pid from k299_pid)
                      and relation = 'public._t299m'::regclass) as races;
select dblink_exec('k299', 'rollback');
select case when (select races from m299_probe)
            then dblink_send_query('k299', $q$ select public.t299_grant_hold('public._t299m', 'M') $q$) end;
select case when (select races from m299_probe)
  then ok(public.t299_await_hold((select pid from k299_pid)),
          'LIVENESS: (M) k299 holds a GRANT on _t299m in a transaction still open')
  else skip('a GRANT takes a lock on the table on this server, so it cannot race the RENAME', 1) end;
select case when (select races from m299_probe)
  then throws_like(
    $$ select dblink_exec('t299', 'call pgpm.transmute(''public._t299m'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
    'tuple concurrently updated',
    '(M) the RENAME''s XX000 from the GRANT goes out as it came, not blamed on the array type PostgreSQL steps around')
  else skip('a GRANT takes a lock on the table on this server, so it cannot race the RENAME', 1) end;
do $$ begin
  if (select races from m299_probe) then
    perform * from dblink_get_result('k299') as x(s text);
    perform * from dblink_get_result('k299') as x(s text);
  end if;
end $$;
select case when (select races from m299_probe)
  then ok((select saw from public.w299_seen where tag = 'M')
          and (select relacl::text like '%t299_reader=r/%' from pg_class where oid = 'public._t299m'::regclass),
          'LIVENESS: (M) the cutover, holding _t299m, waited on k299''s GRANT, which committed')
  else skip('a GRANT takes a lock on the table on this server, so it cannot race the RENAME', 1) end;
select ok((select relkind::text from pg_class where oid = 'public._t299m'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public._t299m'::regclass)
          and exists (select 1 from pg_type where typname = '_t299m_p0000000000000000000_to_0000000000000000200'),
  '(M) the resumable phase-2 state stands, and t299m''s monolith''s array type is still in place');
select lives_ok(
  $$ select dblink_exec('t299', 'call pgpm.transmute(''public._t299m'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(M) the re-run converts _t299m with that array type left in place: it was never an obstacle');

select dblink_disconnect('r299');
select dblink_disconnect('t299');
select dblink_disconnect('k299');
drop event trigger t299_inject;
drop owned by t299_reader;
drop role t299_reader;
select * from finish();
