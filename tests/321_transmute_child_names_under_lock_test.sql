-- Issues #1167 and #1135: a name a forward partition takes, <table>_p<label>, held by the time the cutover
-- builds the forward grid, is refused in pgpm's words rather than leaving a hole in the grid or killing the
-- cutover raw.
--
-- transmute's orphan-child guard (a relation of any kind, or a type that is not a table's row type, at a
-- name pgpm could give a fine child) was asked in the preflight only. No lock on the table keeps a name in
-- its schema free, so a holder committed after the preflight, while phases 1 and 2 had let go of the table
-- or while the conversion waited for a lock, reached the cutover's obtain, which steps over a held name: the
-- conversion COMPLETED with that cell unbuilt (fail_obtain_name), and every write into it was refused, where
-- the reference lists such a name as refused up front (#1167). And a holder a still-open transaction was
-- creating when the cutover's obtain reached its name was invisible to obtain's asking, so the partition's
-- CREATE TABLE waited for it and, once it committed, died raw 23505 after phases 1 and 2 had committed the
-- write-rejecting bound and the claim (#1135). The cutover now asks the orphan-child guard again once its
-- obtain has built the grid, and asks it again (with every name the forward partitions' CREATEs take) from
-- that CREATE's own failure, the shape #1080/#1104/#1105 gave the staging and monolith names. Either
-- refusal rolls the cutover back to the resumable phase-2 state.
--
-- Two kinds of window, made as tests/299 makes them. A COMMITTED holder: an event trigger on phase 1's ADD
-- of pgpm_monolith_bound (after the preflight's asking, in the transaction that commits the bound) takes the
-- name in the transmuting session, so it commits with phase 1. An IN-FLIGHT holder: a second dblink session
-- (k321) creates it in a transaction left open, waits server-side until a backend holding the table waits on
-- that transaction (the forward partition's CREATE), records that it saw the wait, and commits. The transmute
-- runs over dblink, as a top-level CALL whose phases can commit. Fixtures, asymmetric on purpose:
--   (A) t321a, monolith [0, 200), p_obtain => 2: a TABLE committed at the SECOND forward cell's name,
--       t321a_p<300>, while a table of the same name in another schema (s321) has been there from the start;
--       refused naming the public one; with it dropped, the re-run converts with both forward cells built,
--       and the other schema's table is untouched;
--   (B) t321b, monolith [0, 300), p_obtain => 3: an enum TYPE committed at the middle forward cell's name,
--       t321b_p<400>; refused naming it as a type; with it dropped, the re-run converts with [400, 500) built;
--   (C) t321c, monolith [0, 200): a table at the FIRST forward cell's name, t321c_p<200>, in flight when the
--       cutover's obtain creates that partition (the #1135 reproduction); refused in the guard's words once
--       it commits; with it dropped, the re-run converts;
--   (D) t321d, monolith [0, 200): an enum at the second forward cell's ARRAY type name, _t321d_p<300>, in
--       flight when the cutover's obtain creates that partition (its CREATE takes that name for the
--       partition's array type); refused naming it; a type committed at an array type name is no obstacle
--       (PostgreSQL steps around it), so the re-run converts with the enum left in place;
--   (F) t321f, monolith [0, 200): an enum committed before the conversion at the FIRST forward cell's array
--       type name, _t321f_p<200> (no obstacle), and another in flight at the SECOND's, _t321f_p<300>, when
--       the cutover's obtain creates that partition; refused naming the in-flight one, NOT the one that was
--       there first; with it dropped, the re-run converts with the first enum left in place.
-- Every refusal is pinned by its message (throws_like), and each is paired with witnesses that the window
-- opened (once), that its holder committed, and that phases 1 and 2 had committed before the refusal.
-- bench/transmute_child_names_under_lock.sh runs this file against the mutants that drop the cutover's
-- second asking of the guard (transmute_child_names_preflight_only), the 23505 arm of the forward CREATE's
-- handler (transmute_forward_create_unhandled), the guard's asking in that handler
-- (transmute_forward_orphan_unasked), the general names helper's (transmute_forward_held_names_unchecked),
-- and the one that lets that helper blame a holder already there (transmute_forward_blames_preexisting).
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(44);

set timezone = 'UTC';

create table public.t321a (id bigint primary key, v text not null);
insert into public.t321a select g, 'a' || g from generate_series(1, 150) g;   -- step 100: monolith [0, 200)
create table public.t321b (id bigint primary key, v text not null);
insert into public.t321b select g, 'b' || g from generate_series(1, 250) g;   -- step 100: monolith [0, 300)
create table public.t321c (id bigint primary key, v text not null);
insert into public.t321c select g, 'c' || g from generate_series(1, 120) g;   -- step 100: monolith [0, 200)
create table public.t321d (id bigint primary key, v text not null);
insert into public.t321d select g, 'd' || g from generate_series(1, 130) g;   -- step 100: monolith [0, 200)

-- the same name in another schema, there from the start: a child's name is schema-qualified, so this one
-- never stands in the way, and must outlive the conversion
create schema s321;
create table s321.t321a_p0000000000000000300 (keep int);
insert into s321.t321a_p0000000000000000300 values (321);

-- a refusal rolls the cutover back but not a nextval, so each committed window witnesses on its own sequence
create sequence public.w321a_seq;
create sequence public.w321b_seq;

create function public.t321_inject() returns event_trigger language plpgsql as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    -- phase 1's ADD of the bound: after the preflight, committed with the bound. Once each. By objid, not
    -- by a name cast: the cutover's rename is an ALTER TABLE too, and the name is gone by its end.
    if r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t321a'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w321a_seq) then
      perform nextval('public.w321a_seq');
      create table public.t321a_p0000000000000000300 (x int);
    elsif r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t321b'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w321b_seq) then
      perform nextval('public.w321b_seq');
      create type public.t321b_p0000000000000000400 as enum ('x');
    end if;
  end loop;
end $$;
create event trigger t321_inject on ddl_command_end when tag in ('ALTER TABLE') execute function public.t321_inject();

-- The in-flight holder, run by k321 as ONE statement (so its transaction is open until it returns): create
-- the name, wait until a backend that holds a lock on p_rel waits on this transaction, record whether it was
-- seen, and return, which commits the name. Polled server-side: pg_locks is read live on each iteration.
create table public.w321_seen (tag text primary key, saw boolean not null);
create function public.t321_hold(p_ddl text, p_rel regclass, p_tag text) returns void language plpgsql as $$
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
  insert into public.w321_seen values (p_tag, v_saw);
end $$;
-- and the main session's wait for k321 to have created its name and started polling
create function public.t321_await_hold(p_pid int) returns boolean language plpgsql as $$
begin
  for i in 1 .. 400 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = p_pid and wait_event = 'PgSleep') then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

select dblink_connect('t321', 'dbname=' || current_database());
select dblink_connect('k321', 'dbname=' || current_database());
create temp table k321_pid as select pid from dblink('k321', 'select pg_backend_pid()') as x(pid int);

-- ====================================================================================================
-- (A) a table committed at the second forward cell's name after the preflight (#1167)
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321a'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'pg_partition_magician: public.t321a_p0000000000000000300 already exists as a standalone table matching this parent''s partition naming%',
  '(A) the cutover refuses the table committed at a forward cell''s name after the preflight, naming it, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w321a_seq), '1:true',
  'LIVENESS: (A) the window created the holder once, inside phase 1');
select is((select relkind::text || '/' || relnatts from pg_class where oid = to_regclass('public.t321a_p0000000000000000300')), 'r/1',
  'LIVENESS: (A) the holder public.t321a_p0000000000000000300 (one column, x) committed with phase 1');
select ok((select convalidated from pg_constraint where conrelid = 'public.t321a'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t321a'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t321a'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t321a'::regclass),
  '(A) the validated bound and the claim stand, t321a is still the plain table: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t321', 'drop table public.t321a_p0000000000000000300') $$,
  'LIVENESS: (A) the operator takes the remedy the refusal names, dropping the holder');
select lives_ok(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321a'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(A) the re-run resumes and converts t321a');
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t321a'::regclass),
  array['t321a_p0000000000000000000_to_0000000000000000200', 't321a_p0000000000000000200', 't321a_p0000000000000000300'],
  '(A) its partitions are the monolith and BOTH forward cells: no hole in the grid');
select lives_ok($$ insert into public.t321a values (350, 'past') $$, 'LIVENESS: (A) a row in the second forward cell is accepted');
select is((select tableoid::regclass::text from public.t321a where id = 350), 't321a_p0000000000000000300',
  '(A) and it landed in that cell''s partition');
select is((select array_agg(keep) from s321.t321a_p0000000000000000300), array[321],
  '(A) the same name in another schema was never in the way, and is untouched');

-- ====================================================================================================
-- (B) an enum committed at the middle forward cell's name after the preflight (#1167, the type half)
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321b'', ''id'', 100::bigint, p_obtain => 3)') $$,
  'pg_partition_magician: public.t321b_p0000000000000000400 already exists as an enum type matching this parent''s partition naming%',
  '(B) the cutover refuses the enum committed at a forward cell''s name after the preflight, naming it as a type, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w321b_seq), '1:true',
  'LIVENESS: (B) the window created the holder once, inside phase 1');
select is((select typtype::text from pg_type where typname = 't321b_p0000000000000000400' and typnamespace = 'public'::regnamespace), 'e',
  'LIVENESS: (B) the enum public.t321b_p0000000000000000400 committed with phase 1');
select ok((select convalidated from pg_constraint where conrelid = 'public.t321b'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t321b'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t321b'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t321b'::regclass),
  '(B) the validated bound and the claim stand, t321b is still the plain table: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t321', 'drop type public.t321b_p0000000000000000400') $$,
  'LIVENESS: (B) the operator takes the remedy the refusal names, dropping the type');
select lives_ok(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321b'', ''id'', 100::bigint, p_obtain => 3)') $$,
  '(B) the re-run resumes and converts t321b');
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t321b'::regclass),
  array['t321b_p0000000000000000000_to_0000000000000000300', 't321b_p0000000000000000300',
        't321b_p0000000000000000400', 't321b_p0000000000000000500'],
  '(B) its partitions are the monolith and all three forward cells, [400, 500) among them');

-- ====================================================================================================
-- (C) a table at the first forward cell's name, created by a transaction still open when the cutover's
-- obtain creates that partition (#1135)
-- ====================================================================================================
select dblink_send_query('k321', $q$ select public.t321_hold('create table public.t321c_p0000000000000000200 (x int)', 'public.t321c', 'C') $q$);
select ok(public.t321_await_hold((select pid from k321_pid)) and to_regclass('public.t321c_p0000000000000000200') is null,
  'LIVENESS: (C) k321 created t321c_p0000000000000000200 in a transaction still open, invisible to the preflight and to obtain');
select throws_like(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321c'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public.t321c_p0000000000000000200 already exists as a standalone table matching this parent''s partition naming%',
  '(C) the cutover refuses the forward cell''s name an open transaction was creating, once it commits, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k321') as x(s text);
  perform * from dblink_get_result('k321') as x(s text);
end $$;
select is((select saw from public.w321_seen where tag = 'C'), true,
  'LIVENESS: (C) the cutover, holding t321c, waited on k321''s transaction before it committed');
select is((select relkind::text || '/' || relnatts from pg_class where oid = to_regclass('public.t321c_p0000000000000000200')), 'r/1',
  'LIVENESS: (C) k321''s t321c_p0000000000000000200 (one column, x) committed');
select ok((select convalidated from pg_constraint where conrelid = 'public.t321c'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t321c'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t321c'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t321c'::regclass),
  '(C) the validated bound and the claim stand, t321c is still the plain table: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t321', 'drop table public.t321c_p0000000000000000200') $$,
  'LIVENESS: (C) the operator takes the remedy the refusal names, dropping the holder');
select lives_ok(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321c'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(C) the re-run resumes and converts t321c');
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t321c'::regclass),
  array['t321c_p0000000000000000000_to_0000000000000000200', 't321c_p0000000000000000200', 't321c_p0000000000000000300'],
  '(C) its partitions are the monolith and both forward cells, the first among them');

-- ====================================================================================================
-- (D) an enum at the second forward cell's ARRAY type name, created by a transaction still open when the
-- cutover's obtain creates that partition (#1135, a name the CREATE takes besides the cell's own)
-- ====================================================================================================
select dblink_send_query('k321', $q$ select public.t321_hold('create type public."_t321d_p0000000000000000300" as enum (''x'')', 'public.t321d', 'D') $q$);
select ok(public.t321_await_hold((select pid from k321_pid))
          and to_regtype('public."_t321d_p0000000000000000300"') is null
          and to_regclass('public.t321d_p0000000000000000300') is null,
  'LIVENESS: (D) k321 created _t321d_p0000000000000000300 in a transaction still open; nothing holds the cell''s own name');
select throws_like(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321d'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public._t321d_p0000000000000000300 already exists as an enum type, and the cutover''s CREATE of a forward partition takes that name%',
  '(D) the cutover refuses the type at a forward partition''s array type name, once it commits, naming it, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k321') as x(s text);
  perform * from dblink_get_result('k321') as x(s text);
end $$;
select is((select saw from public.w321_seen where tag = 'D'), true,
  'LIVENESS: (D) the cutover, holding t321d, waited on k321''s transaction before it committed');
select is((select typtype::text from pg_type where typname = '_t321d_p0000000000000000300' and typnamespace = 'public'::regnamespace), 'e',
  'LIVENESS: (D) k321''s enum _t321d_p0000000000000000300 committed');
select ok((select convalidated from pg_constraint where conrelid = 'public.t321d'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t321d'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t321d'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t321d'::regclass),
  '(D) the validated bound and the claim stand, t321d is still the plain table: the resumable phase-2 state');
select lives_ok(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321d'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(D) with the enum still in place, the re-run converts t321d: a committed type at an array type name is no obstacle');
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t321d'::regclass),
  array['t321d_p0000000000000000000_to_0000000000000000200', 't321d_p0000000000000000200', 't321d_p0000000000000000300'],
  '(D) its partitions are the monolith and both forward cells');
select is((select typtype::text from pg_type where typname = '_t321d_p0000000000000000300' and typnamespace = 'public'::regnamespace), 'e',
  '(D) and the enum keeps its name: PostgreSQL gave the partition''s array type another');

-- ====================================================================================================
-- (F) an enum committed before the conversion at the FIRST forward cell's array type name, _t321f_p<200>
-- (no obstacle), and another in flight at the SECOND's, _t321f_p<300>, when the cutover's obtain creates
-- that partition: the refusal names the one the CREATE collided with, not the one that was there first
-- ====================================================================================================
create table public.t321f (id bigint primary key, v text not null);
insert into public.t321f select g, 'f' || g from generate_series(1, 140) g;   -- step 100: monolith [0, 200)
create type public."_t321f_p0000000000000000200" as enum ('there first');
select dblink_send_query('k321', $q$ select public.t321_hold('create type public."_t321f_p0000000000000000300" as enum (''x'')', 'public.t321f', 'F') $q$);
select ok(public.t321_await_hold((select pid from k321_pid))
          and to_regtype('public."_t321f_p0000000000000000300"') is null,
  'LIVENESS: (F) k321 created _t321f_p0000000000000000300 in a transaction still open');
select throws_like(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321f'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public._t321f_p0000000000000000300 already exists as an enum type, and the cutover''s CREATE of a forward partition takes that name%',
  '(F) the cutover names the type it collided with, not the one committed before obtain ran, which PostgreSQL steps around');
do $$ begin
  perform * from dblink_get_result('k321') as x(s text);
  perform * from dblink_get_result('k321') as x(s text);
end $$;
select is((select saw from public.w321_seen where tag = 'F'), true,
  'LIVENESS: (F) the cutover, holding t321f, waited on k321''s transaction before it committed');
select is((select string_agg(typname::text || '/' || typtype::text, ', ' order by typname) from pg_type
            where typname in ('_t321f_p0000000000000000200', '_t321f_p0000000000000000300')
              and typnamespace = 'public'::regnamespace),
  '_t321f_p0000000000000000200/e, _t321f_p0000000000000000300/e',
  'LIVENESS: (F) both enums are committed: the one there first, and k321''s');
select ok((select convalidated from pg_constraint where conrelid = 'public.t321f'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t321f'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t321f'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t321f'::regclass),
  '(F) the validated bound and the claim stand, t321f is still the plain table: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t321', 'drop type public."_t321f_p0000000000000000300"') $$,
  'LIVENESS: (F) the operator takes the remedy the refusal names, dropping the type it named');
select lives_ok(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321f'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(F) with the enum that was there first still in place, the re-run converts t321f');
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t321f'::regclass),
  array['t321f_p0000000000000000000_to_0000000000000000200', 't321f_p0000000000000000200', 't321f_p0000000000000000300'],
  '(F) its partitions are the monolith and both forward cells');

-- ====================================================================================================
-- no window: nothing holds a forward name, and the second asking refuses nothing
-- ====================================================================================================
create table public.t321e (id bigint primary key, v text not null);
insert into public.t321e select g, 'e' || g from generate_series(1, 160) g;   -- step 100: monolith [0, 200)
-- a table of the same shape in another schema, and a table that only LOOKS like a child (its label is not
-- a fine one) in this one: neither is a holder
create table s321.t321e_p0000000000000000200 (keep int);
create table public.t321e_pending (keep int);
select lives_ok(
  $$ select dblink_exec('t321', 'call pgpm.transmute(''public.t321e'', ''id'', 100::bigint, p_obtain => 1)') $$,
  'with no holder, the cutover''s second asking refuses nothing: t321e converts');
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t321e'::regclass),
  array['t321e_p0000000000000000000_to_0000000000000000200', 't321e_p0000000000000000200'],
  'LIVENESS: t321e''s partitions are the monolith and its forward cell, built by the cutover''s obtain');
select ok(to_regclass('s321.t321e_p0000000000000000200') is not null and to_regclass('public.t321e_pending') is not null,
  'the other schema''s namesake and the look-alike are untouched');

select dblink_disconnect('t321');
select dblink_disconnect('k321');
drop event trigger t321_inject;
select * from finish();
