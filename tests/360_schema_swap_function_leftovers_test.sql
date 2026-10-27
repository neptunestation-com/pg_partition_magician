-- The owner and function statements the schema-swap families left reach what pgpm identified by oid (the schema-swap
-- class: #1335 bullet 10, #1357's function residue, #1366; scripts/check_by_name_after_wait.py is the class's lint).
--
-- THE BUG. ALTER TABLE ... OWNER waits for ACCESS EXCLUSIVE behind any reader, and ALTER FUNCTION ... OWNER and DROP
-- FUNCTION wait for the function's lock behind any DDL on it; each looks its name up again once granted. A lock pins
-- no schema's name, and a function cannot be LOCKed at all, so a schema renamed aside during the wait, with a
-- namesake schema and object committed in its place, is what the statement reached:
--   PART C  _own_like_parent handed the namesake table to the parent's owner (regrain's copy tick holds the copy in
--           ROW EXCLUSIVE only, so its ALTER ... OWNER can wait), and the copy kept its owner.
--   PART D  _scratch_mint_fn handed the namesake function to the parent's owner.
--   PART E  _scratch_owner_follow's function branch did the same to a namesake of the regrain capture function.
--   PART G  _regrain_capture_install minted the capture function with CREATE OR REPLACE under the name it had found
--           free BEFORE its waits (the trigger's DROP behind the source's readers), so a function committed under
--           that name during one had its body replaced by pgpm's capture (#1357's residue class).
--   PART H  pgpm._drop_fn_by_oid, the DROP FUNCTION by oid that _regrain_capture_install and untransmute now share
--           (they rendered the function from its oid and checked nothing after).
--
-- THE CONTRACT. Each statement is checked by its effect on the oid it identified (pgpm._effect_or_raise): the table or
-- function by oid has the new owner, or the function by oid is gone; otherwise the call raises and rolls back, and the
-- namesake is left as it was. The capture function is made by a plain CREATE, which refuses any function under its
-- name (42723), so another role's function is never replaced.
--
-- Every concurrent order is set by a lock queue: a second session ('h360') holds a conflicting lock, a third
-- ('r360') makes the call, a server-side poll sees the call waiting on the oid, and only then does the holder rename,
-- create and commit. ASYMMETRIC FIXTURES: every namesake is told apart by its oid and its owner or body, and every
-- check names the object it means. No throws_* here: each refusal is read off the call's own session.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(31);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'g360o') then create role g360o; end if;
end $$;

-- the call in session r360 is waiting, ungranted, for p_mode on relation p_oid, or (p_fn) on function p_oid
create function pg_temp.waits_for(p_oid oid, p_mode text, p_fn boolean default false) returns boolean
language plpgsql as $$
begin
  for i in 1 .. 800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.mode = p_mode and l.pid = current_setting('pgpm360.r_pid')::int
                  and case when p_fn then l.locktype = 'object' and l.classid = 'pg_proc'::regclass and l.objid = p_oid
                           else l.locktype = 'relation' and l.relation = p_oid end) then
      return true;
    end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

select dblink_connect('h360', format('dbname=%s user=postgres', current_database())) as h \gset
select dblink_connect('r360', format('dbname=%s user=postgres', current_database())) as r \gset
select set_config('pgpm360.r_pid', (select pid::text from dblink('r360', 'select pg_backend_pid()') as t(pid int)), false) as r_pid \gset
select dblink_exec('r360', 'set lock_timeout = ''60s''') as r_lt \gset
select dblink_exec('r360', 'set statement_timeout = ''120s''') as r_st \gset

-- ======================= (C) _own_like_parent: the table handed over is the one it identified ==================
create schema c360s;
create table c360s.p (id bigint);
alter table c360s.p owner to g360o;
create table c360s.c (id bigint);
insert into c360s.c values (1), (2);
select 'c360s.p'::regclass::oid as c_parent, 'c360s.c'::regclass::oid as c_child \gset
select dblink_exec('h360', 'begin') as c1 \gset
select x as c_seen from dblink('h360', 'select count(*)::text from c360s.c') as t(x text) \gset
select dblink_send_query('r360', format('select pgpm._own_like_parent(%s::oid::regclass, %s::oid::regclass)', :'c_parent', :'c_child')) as c2 \gset
select ok(pg_temp.waits_for(:'c_child'::oid, 'AccessExclusiveLock'),
  'LIVENESS: C: ALTER ... OWNER waits for ACCESS EXCLUSIVE on the child''s oid, behind the reader');
select dblink_exec('h360', 'alter schema c360s rename to c360s_aside') as c3 \gset
select dblink_exec('h360', 'create schema c360s') as c4 \gset
select dblink_exec('h360', 'create table c360s.c (id bigint)') as c5 \gset
select dblink_exec('h360', 'insert into c360s.c values (77)') as c6 \gset
select o as c_squat from dblink('h360', $$select 'c360s.c'::regclass::oid$$) as t(o oid) \gset
select dblink_exec('h360', 'commit') as c7 \gset
select coalesce(string_agg(x, ','), 'no row') as c_ret from dblink_get_result('r360', false) as t(x text) \gset
select dblink_error_message('r360') as c_err \gset
select count(*) as c_drained from dblink_get_result('r360', false) as t(x text) \gset
select ok(:'c_squat'::oid <> :'c_child'::oid, 'LIVENESS: C: the child''s name denotes the stranger once the reader commits');

select is((select pg_get_userbyid(relowner) from pg_class where oid = :'c_squat'::oid), 'postgres',
  'C: the stranger''s table keeps its owner');
select ok(:'c_err' like '%reached another relation than the one it identified%',
  format('C: the hand-over refused, rolled back, naming the redirection (%s)', :'c_err'));
select is((select array_agg(id order by id) from c360s.c), array[77::bigint], 'C: the stranger still holds its row 77 alone');

-- ======================= (D) _scratch_mint_fn: the function handed over is the one it identified ===============
create schema d360s;
create table d360s.p (id bigint);
alter table d360s.p owner to g360o;
create function d360s.f() returns int language sql as 'select 1';
select 'd360s.p'::regclass::oid as d_parent, 'd360s.f()'::regprocedure::oid as d_fn \gset
select dblink_exec('h360', 'begin') as d1 \gset
select dblink_exec('h360', 'comment on function d360s.f() is ''held''') as d2 \gset
select dblink_send_query('r360', format('select pgpm._scratch_mint_fn(%s::oid::regclass, %s::oid::regprocedure)', :'d_parent', :'d_fn')) as d3 \gset
select ok(pg_temp.waits_for(:'d_fn'::oid, 'AccessExclusiveLock', true),
  'LIVENESS: D: ALTER FUNCTION ... OWNER waits for the function''s lock, behind the holder''s COMMENT');
select dblink_exec('h360', 'alter schema d360s rename to d360s_aside') as d4 \gset
select dblink_exec('h360', 'create schema d360s') as d5 \gset
select dblink_exec('h360', 'create function d360s.f() returns int language sql as ''select 2''') as d6 \gset
select o as d_squat from dblink('h360', $$select 'd360s.f()'::regprocedure::oid$$) as t(o oid) \gset
select dblink_exec('h360', 'commit') as d7 \gset
select coalesce(string_agg(x, ','), 'no row') as d_ret from dblink_get_result('r360', false) as t(x text) \gset
select dblink_error_message('r360') as d_err \gset
select count(*) as d_drained from dblink_get_result('r360', false) as t(x text) \gset
select ok(:'d_squat'::oid <> :'d_fn'::oid, 'LIVENESS: D: the function''s name denotes the stranger''s once the holder commits');

select is((select pg_get_userbyid(proowner) from pg_proc where oid = :'d_squat'::oid), 'postgres',
  'D: the stranger''s function keeps its owner');
select ok(:'d_err' like '%reached another relation than the one it identified%',
  format('D: the hand-over refused, rolled back, naming the redirection (%s)', :'d_err'));
select is((select pg_get_userbyid(proowner) from pg_proc where oid = :'d_fn'::oid), 'postgres',
  'D: and the function it identified is as it was, the refusal rolled back');

-- ======================= (E) _scratch_owner_follow: the capture function followed is pgpm's ======================
create schema e360s;
create table e360s.t (id bigint primary key, payload text);
insert into e360s.t select g * 10, 'real' from generate_series(1, 99) g;
call pgpm.transmute('e360s.t', 'id', 1000, p_paused => true);
insert into e360s.t values (20000, 'frontier');
select 'e360s.t'::regclass::oid as e_parent \gset
select is(pgpm.regrain_step('e360s.t', (select child_name from pgpm.part
    where parent_table = 'e360s.t'::regclass and attached and lo = '0'), '500', 1000), 'prepared',
  'fixture: E''s regrain is prepared, its capture function minted');
select regrain_capture_fn_oid as e_fn from pgpm.config where parent_table = :'e_parent'::oid \gset
select is((select proname::text from pg_proc where oid = :'e_fn'::oid), 't_pgpm_regrain_capture',
  'LIVENESS: E: the capture function pgpm recorded is e360s.t_pgpm_regrain_capture()');
alter table e360s.t owner to g360o;
select dblink_exec('h360', 'begin') as e1 \gset
select dblink_exec('h360', 'comment on function e360s.t_pgpm_regrain_capture() is ''held''') as e2 \gset
select dblink_send_query('r360', format('select pgpm._scratch_owner_follow(%s::oid::regclass, %L)', :'e_parent', 'test 360')) as e3 \gset
select ok(pg_temp.waits_for(:'e_fn'::oid, 'AccessExclusiveLock', true),
  'LIVENESS: E: the follow waits for the capture function''s lock to hand it over, behind the holder''s COMMENT');
select dblink_exec('h360', 'alter schema e360s rename to e360s_aside') as e4 \gset
select dblink_exec('h360', 'create schema e360s') as e5 \gset
select dblink_exec('h360', $$create function e360s.t_pgpm_regrain_capture() returns trigger language plpgsql as 'begin return null; end'$$) as e6 \gset
select o as e_squat from dblink('h360', $$select 'e360s.t_pgpm_regrain_capture()'::regprocedure::oid$$) as t(o oid) \gset
select dblink_exec('h360', 'commit') as e7 \gset
select coalesce(string_agg(x, ','), 'no row') as e_ret from dblink_get_result('r360', false) as t(x text) \gset
select dblink_error_message('r360') as e_err \gset
select count(*) as e_drained from dblink_get_result('r360', false) as t(x text) \gset
select ok(:'e_squat'::oid <> :'e_fn'::oid, 'LIVENESS: E: the capture function''s name denotes the stranger''s once the holder commits');

select is((select pg_get_userbyid(proowner) from pg_proc where oid = :'e_squat'::oid), 'postgres',
  'E: the stranger''s function keeps its owner');
select ok(:'e_err' like '%reached another relation than the one it identified%',
  format('E: the follow refused, rolled back, naming the redirection (%s)', :'e_err'));
select is((select pg_get_userbyid(proowner) from pg_proc where oid = :'e_fn'::oid), 'postgres',
  'E: and the capture function pgpm recorded is as it was, the refusal rolled back');

-- ======================= (G) the capture function is never minted over another role's ===========================
-- A second prepare drops the previous run's capture function and delta (by oid) before it mints fresh ones; the
-- delta's DROP waits behind a reader of it, after the function's name was found free in the parent's schema, and
-- during that wait the schema is renamed aside and a namesake schema holding the operator's function of that name
-- is committed in its place.
create schema g360s;
create table g360s.t (id bigint primary key, payload text);
insert into g360s.t select g * 10, 'real' from generate_series(1, 99) g;
call pgpm.transmute('g360s.t', 'id', 1000, p_paused => true);
insert into g360s.t values (20000, 'frontier');
select 'g360s.t'::regclass::oid as g_parent \gset
select is(pgpm.regrain_step('g360s.t', (select child_name from pgpm.part
    where parent_table = 'g360s.t'::regclass and attached and lo = '0'), '500', 1000), 'prepared',
  'fixture: G''s first regrain is prepared');
select pgpm.regrain_cancel('g360s.t') as g_cancel \gset
select regrain_delta_oid as g_delta, regrain_capture_fn_oid as g_old_fn from pgpm.config where parent_table = :'g_parent'::oid \gset
select ok(:'g_delta'::oid is not null and exists (select 1 from pg_class where oid = :'g_delta'::oid)
          and exists (select 1 from pg_proc where oid = :'g_old_fn'::oid and proname = 't_pgpm_regrain_capture'),
  'LIVENESS: G: the cancelled run left its delta and its capture function recorded, for the next prepare to drop');
select child_name as g_src from pgpm.part where parent_table = :'g_parent'::oid and attached and lo = '0' \gset
select dblink_exec('h360', 'begin') as g1 \gset
select x as g_seen from dblink('h360', format('select count(*)::text from %s', :'g_delta'::oid::regclass)) as t(x text) \gset
select dblink_send_query('r360', format('select pgpm.regrain_step(%s::oid::regclass, %L, %L, 1000)', :'g_parent', :'g_src', '500')) as g2 \gset
select ok(pg_temp.waits_for(:'g_delta'::oid, 'AccessExclusiveLock'),
  'LIVENESS: G: the second prepare waits for ACCESS EXCLUSIVE on the previous delta''s oid to drop it, behind the reader');
select dblink_exec('h360', 'alter schema g360s rename to g360s_aside') as g3a \gset
select dblink_exec('h360', 'create schema g360s') as g3b \gset
select dblink_exec('h360', $$create function g360s.t_pgpm_regrain_capture() returns trigger language plpgsql as 'begin return null; end'$$) as g3 \gset
select o as g_op_fn from dblink('h360', $$select 'g360s.t_pgpm_regrain_capture()'::regprocedure::oid$$) as t(o oid) \gset
select dblink_exec('h360', 'commit') as g4 \gset
select ok((select relnamespace from pg_class where oid = :'g_parent'::oid) <> 'g360s'::regnamespace,
  'LIVENESS: G: the parent''s schema was renamed aside, and another schema holds its name and the function''s');
select coalesce(string_agg(x, ','), 'no row') as g_ret from dblink_get_result('r360', false) as t(x text) \gset
select dblink_error_message('r360') as g_err \gset
select count(*) as g_drained from dblink_get_result('r360', false) as t(x text) \gset

select is((select prosrc from pg_proc where oid = :'g_op_fn'::oid), 'begin return null; end',
  format('G: the operator''s function keeps its own body (prepare: %s, %s)', :'g_ret', :'g_err'));
select isnt(:'g_ret'::text, 'prepared', 'G: and the prepare did not complete over it');
select is((select regrain_capture_fn_oid from pgpm.config where parent_table = :'g_parent'::oid), :'g_old_fn'::oid,
  'G: pgpm''s record is as the cancelled run left it, the refused prepare rolled back');

-- ======================= (H) _drop_fn_by_oid drops the function it identified, or nothing ======================
create schema h360s;
create function h360s.f() returns int language sql as 'select 1';
select 'h360s.f()'::regprocedure::oid as h_fn \gset
select dblink_exec('h360', 'begin') as h1 \gset
select dblink_exec('h360', 'comment on function h360s.f() is ''held''') as h2 \gset
select dblink_send_query('r360', format('select pgpm._drop_fn_by_oid(%s::oid, %L)', :'h_fn', 'test 360')) as h3 \gset
select ok(pg_temp.waits_for(:'h_fn'::oid, 'AccessExclusiveLock', true),
  'LIVENESS: H: DROP FUNCTION waits for the function''s lock, behind the holder''s COMMENT');
select dblink_exec('h360', 'alter schema h360s rename to h360s_aside') as h4 \gset
select dblink_exec('h360', 'create schema h360s') as h5 \gset
select dblink_exec('h360', 'create function h360s.f() returns int language sql as ''select 2''') as h6 \gset
select o as h_squat from dblink('h360', $$select 'h360s.f()'::regprocedure::oid$$) as t(o oid) \gset
select dblink_exec('h360', 'commit') as h7 \gset
select coalesce(string_agg(x, ','), 'no row') as h_ret from dblink_get_result('r360', false) as t(x text) \gset
select dblink_error_message('r360') as h_err \gset
select count(*) as h_drained from dblink_get_result('r360', false) as t(x text) \gset
select ok(:'h_squat'::oid <> :'h_fn'::oid, 'LIVENESS: H: the function''s name denotes the stranger''s once the holder commits');

select ok(exists (select 1 from pg_proc where oid = :'h_squat'::oid), 'H: the stranger''s function is not dropped');
select ok(:'h_err' like '%reached another relation than the one it identified%',
  format('H: the drop refused, rolled back, naming the redirection (%s)', :'h_err'));
select ok(exists (select 1 from pg_proc where oid = :'h_fn'::oid), 'H: and the function it identified is still there, the refusal rolled back');

-- with nothing in the way it drops exactly the function it identified
select is(pgpm._drop_fn_by_oid(:'h_fn'::oid, 'test 360')::text, '', 'H: a free drop returns');
select ok(not exists (select 1 from pg_proc where oid = :'h_fn'::oid) and exists (select 1 from pg_proc where oid = :'h_squat'::oid),
  'H: and it dropped the function it identified, leaving the stranger''s');

select dblink_disconnect('h360') as x1 \gset
select dblink_disconnect('r360') as x2 \gset
drop schema c360s cascade; drop schema c360s_aside cascade;
drop schema d360s cascade; drop schema d360s_aside cascade;
drop schema h360s cascade; drop schema h360s_aside cascade;
drop schema e360s cascade; drop schema e360s_aside cascade;
drop schema g360s cascade; drop schema g360s_aside cascade;
select * from finish();
drop owned by g360o;
drop role g360o;
