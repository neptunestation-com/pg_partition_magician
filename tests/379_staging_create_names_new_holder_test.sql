-- The staging CREATE's name-collision refusal names the holder the CREATE collided with, not one that was already
-- there and that PostgreSQL steps around (issue #1217).
--
-- Step 5 of the cutover CREATEs the new parent under <table>_pgpm_new, and that CREATE takes the name in pg_class,
-- in pg_type (the row type), and the array type's name, an underscore before it. A holder a still-open
-- transaction is creating at one of those names makes the CREATE wait, and once it commits the CREATE fails 23505,
-- whose handler asks _transmute_refuse_names_held who holds the names. That arm asked without p_skip (only the
-- XX000 arm passed the holders present before the CREATE ran), so the first holder it met was named, a
-- pre-existing implicit array type PostgreSQL moves aside included, with a remedy ("Drop or rename it") that
-- cannot be applied to one. Every 23505 arm of the cutover now passes them, as the forward partitions' arm does.
--
-- The fixture: table public._s, so its staging name _s_pgpm_new is also the name of the implicit array type of a
-- table public.s_pgpm_new committed beforehand (no obstacle: PostgreSQL moves it aside, and the preflight passes
-- it). An open transaction creates an enum at __s_pgpm_new, the name the CREATE moves that array type to. The
-- ordering is pinned by locks, not timing: the holder waits until it sees the cutover, holding _s, waiting on its
-- transaction id, and only then commits. Part B is the same for the first RENAME, of public._m to its monolith's
-- name _m_p0000000000000000000, the name of the implicit array type of a table public.m_p0000000000000000000,
-- with the enum in flight at __m_p0000000000000000000 (the staging CREATE before it takes none of those names).
-- bench/transmute_state_reads.sh runs this file against the mutants that drop p_skip from each arm.
\set ON_ERROR_STOP 1
create extension if not exists pgtap;
create extension if not exists dblink;
set timezone = 'UTC';
set client_min_messages = warning;
select plan(11);

create table public._s (id bigint primary key, v text not null);
insert into public._s select g, 's' || g from generate_series(1, 140) g;   -- step 100: monolith [0, 200)
create table public.s_pgpm_new (keep int);
select is((select format_type(typelem, null) from pg_type where typname = '_s_pgpm_new' and typnamespace = 'public'::regnamespace),
  's_pgpm_new',
  'LIVENESS: _s_pgpm_new, the staging name, is held by the implicit array type of s_pgpm_new before transmute');

create table public.p379_seen (saw boolean not null);
create function public.p379_hold(p_ddl text, p_rel regclass) returns void language plpgsql as $$
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
  insert into public.p379_seen values (v_saw);
end $$;
create function public.p379_await_hold(p_pid int) returns boolean language plpgsql as $$
begin
  for i in 1 .. 400 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = p_pid and wait_event = 'PgSleep') then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

select dblink_connect('p379t', 'dbname=' || current_database() || ' user=postgres') is not null as t;
select dblink_connect('p379k', 'dbname=' || current_database() || ' user=postgres') is not null as k;
create temp table p379k_pid as select pid from dblink('p379k', 'select pg_backend_pid()') as x(pid int);

select dblink_send_query('p379k', $q$ select public.p379_hold('create type public."__s_pgpm_new" as enum (''x'')', 'public._s') $q$) = 1 as sent;
select ok(public.p379_await_hold((select pid from p379k_pid))
          and to_regtype('public."__s_pgpm_new"') is null,
  'LIVENESS: an open transaction has created __s_pgpm_new, invisible to this session');

select throws_like(
  $$ select dblink_exec('p379t', 'call pgpm.transmute(''public._s'', ''id'', 100::bigint, p_obtain => 1, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public.__s_pgpm_new already exists as an enum type%',
  'the refusal names the in-flight enum __s_pgpm_new the CREATE collided with, not the array type of s_pgpm_new, which PostgreSQL steps around');

do $$ begin
  perform * from dblink_get_result('p379k') as x(s text);
  perform * from dblink_get_result('p379k') as x(s text);
end $$;
select is((select saw from public.p379_seen), true,
  'LIVENESS: the cutover, holding _s, waited on the open transaction before it committed');
select is((select typtype::text from pg_type where typname = '__s_pgpm_new' and typnamespace = 'public'::regnamespace), 'e',
  'LIVENESS: the enum __s_pgpm_new is committed');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public._s'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public._s'::regclass),
  'GUARD: the cutover was refused and rolled back to the resumable phase-2 state');

-- ==================== B: the first RENAME, to the monolith's name ====================
create table public._m (id bigint primary key, v text not null);
insert into public._m select g, 'm' || g from generate_series(1, 40) g;   -- step 100: monolith [0, 100)
create table public.m_p0000000000000000000 (keep int);
truncate public.p379_seen;
select is((select format_type(typelem, null) from pg_type where typname = '_m_p0000000000000000000' and typnamespace = 'public'::regnamespace),
  'm_p0000000000000000000',
  'LIVENESS: _m_p0000000000000000000 is held by the implicit array type of m_p0000000000000000000 before transmute');
select dblink_send_query('p379k', $q$ select public.p379_hold('create type public."__m_p0000000000000000000" as enum (''y'')', 'public._m') $q$) = 1 as sent;
select ok(public.p379_await_hold((select pid from p379k_pid))
          and to_regtype('public."__m_p0000000000000000000"') is null,
  'LIVENESS: an open transaction has created __m_p0000000000000000000, invisible to this session');
select throws_like(
  $$ select dblink_exec('p379t', 'call pgpm.transmute(''public._m'', ''id'', 100::bigint, p_obtain => 1, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: public.__m_p0000000000000000000 already exists as an enum type, and the cutover''s RENAME of public._m to the monolith''s name%',
  'the first RENAME''s refusal names the in-flight enum it collided with, not the array type PostgreSQL moves aside');
do $$ begin
  perform * from dblink_get_result('p379k') as x(s text);
  perform * from dblink_get_result('p379k') as x(s text);
end $$;
select is((select saw from public.p379_seen), true,
  'LIVENESS: the cutover, holding _m, waited on the open transaction before it committed');
select is((select pgpm._part_name('_m', 'id', '100', lo, hi, partition_tz) from pgpm.transmute_inflight
            where parent_table = 'public._m'::regclass), '_m_p0000000000000000000',
  'GUARD: the cutover was refused and rolled back to phase 2, whose recorded bound names the monolith _m_p0000000000000000000');

select dblink_disconnect('p379t') is not null;
select dblink_disconnect('p379k') is not null;
select * from finish();
