-- uninstall.sql drops what pgpm recorded by its oid, never by a name read before a wait (issue #1357).
--
-- THE BUG. uninstall.sql read the names of the objects pgpm's records name (regrain's delta and capture function,
-- from_hypertable's scratch copy, delta and function) and then dropped them by those names. A DROP waits for its
-- lock and resolves the name again once granted; so do the statements before it (regrain_cancel's DROP TRIGGER, an
-- earlier iteration's DROP). A schema renamed aside, with a namesake schema and a table of the operator's under the
-- name committed during any of those waits, was what the DROP reached: the operator's table was dropped, rows and
-- all, and pgpm's own survived. A DROP FUNCTION re-resolves its name after waiting for the function's own lock the
-- same way, and its CASCADE took the operator's triggers with the namesake.
--
-- THE CONTRACT. Every such drop goes by the object's oid (pgpm._uninstall_drop: a table through pgpm._drop_by_oid,
-- locked by oid first; a function by the name its oid has at the statement), and the oid must be gone after it, or
-- the uninstall stops, rolled back.
--   PHASE 0  an install older than pgpm._drop_by_oid (it is dropped first): the uninstall still runs and drops
--            the recorded delta and the recorded copy (rolled back after).
--   PHASE 1  (S6) the record sweep's DROP FUNCTION of a recorded capture function waits for the function's lock
--            behind a COMMENT, and the schema is swapped meanwhile: the uninstall refuses, P0001, naming the oid,
--            and the namesake function keeps its trigger.
--   PHASE 1b (S7) the same refusal in the regrain sweep's DROP FUNCTION, the script run as plain psql -f (no
--            ON_ERROR_STOP, no transaction): the refusal stops the schema drop all the same, pgpm.config still
--            records what it left, and the next run drops it.
--   PHASE 2, one uninstall, five lock waits, each a schema swapped while the uninstall waits:
--     S1  the reported site: the recorded regrain delta of a cancelled regrain, its DROP waiting behind a reader.
--     S2  an in-flight regrain's capture (delta and function moved to a schema of their own), the names read before
--         regrain_cancel's DROP TRIGGER waits behind a reader of the source.
--     S3  a recorded from_hypertable copy, its DROP waiting behind a reader.
--     S4  the comment sweep of an unrecorded tracking copy's delta and function: the loop's names for the second
--         delta read before the first delta's DROP waits.
--     S5  the comment sweep of unrecorded copies: the second copy's name read before the first copy's DROP waits.
--   In each, the namesake keeps its rows (and a namesake function its trigger) and the object pgpm recorded, renamed
--   aside with its schema, is gone.
-- Every concurrent order is set by a lock queue: a holder session ('h348_<n>') takes its lock, polls pg_locks
-- server-side (one statement per sample) until this session waits for ACCESS EXCLUSIVE on the target's oid, then
-- swaps the schema and commits in the same round trip; it records whether it saw the wait and the namesake's oid.
--
-- ASYMMETRIC FIXTURES: S1's namesake holds ids 1, 2; S2's 5; S3's copy 301..303, its namesake 7, 8, 9; S4's
-- namesake 31; S5's second copy 51, its namesake 61, 62. Every check names the object by oid and its rows by value.
-- No throws_* here: the uninstall is run as the guide says, in one transaction, its error read from psql.
--
-- The uninstall script is read with \ir, relative to this file. bench/uninstall_drops_by_oid.sh runs this file
-- against a mutant uninstall.sql by setting the psql variable `uninstall` to its path.
\if :{?uninstall}
\else
\set uninstall ../pgpm_core/uninstall.sql
\endif
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

select plan(58);

create table public.u348_witness (tag text primary key, waited boolean, squat oid);

-- The holder's half, run in its own session inside the transaction that holds its lock: wait (one statement per
-- sample, pg_locks is never snapshotted) until p_pid waits for ACCESS EXCLUSIVE on p_oid (a relation, or with
-- p_fn the function's object lock), then run p_swap and record what p_name denotes. The swap runs either way, so a
-- holder that never saw the wait is a failed LIVENESS check, not a hang.
create function public.u348_hold(p_tag text, p_pid int, p_oid oid, p_fn boolean, p_swap text, p_name text)
returns text language plpgsql as $$
declare v_waited boolean := false;
begin
  for i in 1 .. 800 loop
    if exists (select 1 from pg_locks l
                where l.pid = p_pid and not l.granted and l.mode = 'AccessExclusiveLock'
                  and ((not p_fn and l.locktype = 'relation' and l.relation = p_oid)
                       or (p_fn and l.locktype = 'object' and l.classid = 'pg_proc'::regclass and l.objid = p_oid))) then
      v_waited := true;
      exit;
    end if;
    perform pg_sleep(0.025);
  end loop;
  execute p_swap;
  insert into public.u348_witness
    values (p_tag, v_waited, case when p_fn then to_regprocedure(p_name)::oid else to_regclass(p_name)::oid end);
  return v_waited::text;
end $$;

-- the ids a relation holds (with its partitions), read by its oid: null when no relation has that oid any more
create function pg_temp.ids_of(p_oid oid) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if p_oid is null or not exists (select 1 from pg_class where oid = p_oid) then return null; end if;
  execute format('select array_agg(id order by id) from %s', p_oid::regclass) into v;
  return v;
end $$;

-- the triggers that fire a function, as table:trigger, by the function's oid
create function pg_temp.triggers_of(p_fn oid) returns text[] language sql as $$
  select array_agg(t.tgrelid::regclass::text || ':' || t.tgname order by t.tgname) from pg_trigger t where t.tgfoid = p_fn
$$;

-- what pgpm.config records of a parent's capture, as [function, delta]; null when pgpm is gone (read dynamically,
-- so a run that dropped the schema fails the check below rather than ending the file)
create function pg_temp.recorded_capture(p_parent regclass) returns oid[] language plpgsql as $$
declare v oid[];
begin
  if to_regclass('pgpm.config') is null then return null; end if;
  execute 'select array[regrain_capture_fn_oid, regrain_delta_oid] from pgpm.config where parent_table = $1'
    into v using p_parent;
  return v;
end $$;

-- arm holder p_conn: open its transaction, take p_lock, and send the poll-swap-commit round trip
create function pg_temp.arm(p_conn text, p_lock text, p_tag text, p_oid oid, p_fn boolean, p_swap text, p_name text)
returns text language plpgsql as $$
begin
  perform dblink_connect(p_conn, format('dbname=%s user=postgres', current_database()));
  perform dblink_exec(p_conn, 'begin');
  perform dblink_exec(p_conn, p_lock);
  perform dblink_send_query(p_conn, format('select public.u348_hold(%L, %s, %s, %L, %L, %L); commit',
                                           p_tag, pg_backend_pid(), p_oid, p_fn, p_swap, p_name));
  return p_conn;
end $$;

-- collect a holder's two results (the poll, the commit) and close it
create function pg_temp.disarm(p_conn text) returns text language plpgsql as $$
declare v text;
begin
  select x into v from dblink_get_result(p_conn) as t(x text);
  perform x from dblink_get_result(p_conn) as t(x text);
  perform x from dblink_get_result(p_conn) as t(x text);
  perform dblink_disconnect(p_conn);
  return v;
end $$;

-- ======================================================================================================
-- fixtures
-- ======================================================================================================
-- S1: a cancelled regrain, its delta recorded in the parent's schema
create schema u348a;
create table u348a.t (id bigint primary key, payload text);
insert into u348a.t select g * 10, 'a' from generate_series(1, 99) g;
call pgpm.transmute('u348a.t', 'id', 1000, p_paused => true);
insert into u348a.t values (20000, 'frontier');
select pgpm.regrain_step('u348a.t', (select child_name from pgpm.part where parent_table = 'u348a.t'::regclass and attached and lo = '0'), '500', 1000) as s1_prep \gset
select pgpm.regrain_cancel('u348a.t') as s1_cancel \gset
select regrain_delta_oid as s1_delta, regrain_capture_fn_oid as s1_fn from pgpm.config where parent_table = 'u348a.t'::regclass \gset

-- S2: a regrain in flight, its delta and capture function moved to a schema of their own
create schema u348b;
create schema u348b_cap;
create table u348b.t (id bigint primary key, payload text);
insert into u348b.t select g * 10, 'b' from generate_series(1, 99) g;
call pgpm.transmute('u348b.t', 'id', 1000, p_paused => true);
insert into u348b.t values (20000, 'frontier');
select child_oid as s2_src from pgpm.part where parent_table = 'u348b.t'::regclass and attached and lo = '0' \gset
select pgpm.regrain_step('u348b.t', (select child_name from pgpm.part where parent_table = 'u348b.t'::regclass and attached and lo = '0'), '500', 1000) as s2_prep \gset
select regrain_delta_oid as s2_delta, regrain_capture_fn_oid as s2_fn from pgpm.config where parent_table = 'u348b.t'::regclass \gset
select format('alter table %s set schema u348b_cap', :'s2_delta'::oid::regclass) \gexec
select format('alter function %s set schema u348b_cap', :'s2_fn'::oid::regprocedure) \gexec

-- S3: a recorded from_hypertable copy
create schema u348c;
create schema u348c_src;
create table u348c_src.h3 (id bigint);
create table u348c.h3_pgpm_dest (id bigint);
insert into u348c.h3_pgpm_dest values (301), (302), (303);
select pgpm._scratch_record('u348c_src.h3', 'hypertable_dest', 'u348c.h3_pgpm_dest'::regclass::oid);
select 'u348c.h3_pgpm_dest'::regclass::oid as s3_dest \gset

-- S4: two unrecorded tracking copies' deltas and functions, found by their comments
create schema u348d1;
create schema u348d2;
create table u348d1.e1_pgpm_delta (id bigint);
comment on table u348d1.e1_pgpm_delta is 'pgpm from_hypertable horizon 1';
create function u348d1.e1_pgpm_delta_fn() returns trigger language plpgsql as $f$ begin return new; end $f$;
create table u348d2.e2 (id bigint);
create table u348d2.e2_pgpm_delta (id bigint);
insert into u348d2.e2_pgpm_delta values (41);
comment on table u348d2.e2_pgpm_delta is 'pgpm from_hypertable horizon 2';
create function u348d2.e2_pgpm_delta_fn() returns trigger language plpgsql as $f$ begin return new; end $f$;
create trigger e2_pgpm_delta_trg after insert on u348d2.e2 for each row execute function u348d2.e2_pgpm_delta_fn();
select 'u348d1.e1_pgpm_delta'::regclass::oid as s4_d1, 'u348d1.e1_pgpm_delta_fn()'::regprocedure::oid as s4_f1,
       'u348d2.e2_pgpm_delta'::regclass::oid as s4_d2, 'u348d2.e2_pgpm_delta_fn()'::regprocedure::oid as s4_f2,
       'u348d2.e2'::regclass::oid as s4_e2 \gset

-- S5: two unrecorded copies whose hypertables still exist, found by their comments
create schema u348e1;
create schema u348e2;
create schema u348e_src;
create table u348e_src.f1 (id bigint);
create table u348e_src.f2 (id bigint);
create table u348e1.f1_pgpm_dest (id bigint);
create table u348e2.f2_pgpm_dest (id bigint);
insert into u348e2.f2_pgpm_dest values (51);
select format('comment on table u348e1.f1_pgpm_dest is %L', 'pgpm from_hypertable copy of ' || 'u348e_src.f1'::regclass::oid) \gexec
select format('comment on table u348e2.f2_pgpm_dest is %L', 'pgpm from_hypertable copy of ' || 'u348e_src.f2'::regclass::oid) \gexec
select 'u348e1.f1_pgpm_dest'::regclass::oid as s5_c1, 'u348e2.f2_pgpm_dest'::regclass::oid as s5_c2 \gset

-- S6: a recorded capture function with its trigger on the hypertable
create schema u348g;
create schema u348g_src;
create table u348g_src.h6 (id bigint);
create function u348g.h6_pgpm_delta_fn() returns trigger language plpgsql as $f$ begin return new; end $f$;
create trigger h6_pgpm_delta_trg after insert on u348g_src.h6 for each row execute function u348g.h6_pgpm_delta_fn();
select pgpm._scratch_record('u348g_src.h6', 'hypertable_delta_fn', 'u348g.h6_pgpm_delta_fn()'::regprocedure::oid);
select 'u348g.h6_pgpm_delta_fn()'::regprocedure::oid as s6_fn, 'u348g_src.h6'::regclass::oid as s6_ht \gset

-- S7: a cancelled regrain whose capture function a plain psql run's DROP FUNCTION waits for
create schema u348h;
create table u348h.t (id bigint primary key, payload text);
insert into u348h.t select g * 10, 'h' from generate_series(1, 99) g;
call pgpm.transmute('u348h.t', 'id', 1000, p_paused => true);
insert into u348h.t values (20000, 'frontier');
select pgpm.regrain_step('u348h.t', (select child_name from pgpm.part where parent_table = 'u348h.t'::regclass and attached and lo = '0'), '500', 1000) as s7_prep \gset
select pgpm.regrain_cancel('u348h.t') as s7_cancel \gset
select regrain_delta_oid as s7_delta, regrain_capture_fn_oid as s7_fn, (select proname from pg_proc where oid = regrain_capture_fn_oid) as s7_fname
  from pgpm.config where parent_table = 'u348h.t'::regclass \gset

select is(array[:'s1_prep', :'s2_prep', :'s7_prep'], array['prepared', 'prepared', 'prepared'], 'fixture: the three regrains of [0, 1000) prepared');
select is(
  (select array_agg(c.parent_table::text || ':' || (c.regrain_cursor is null)::text || ':'
                    || (select n.nspname from pg_class r join pg_namespace n on n.oid = r.relnamespace where r.oid = c.regrain_delta_oid)
                    order by c.parent_table::text)
     from pgpm.config c where c.parent_table in ('u348a.t'::regclass, 'u348b.t'::regclass)),
  array['u348a.t:true:u348a', 'u348b.t:false:u348b_cap'],
  'LIVENESS: S1''s cancelled regrain keeps its delta recorded in u348a; S2''s is in flight, its delta in u348b_cap');
select is(pg_temp.triggers_of(:'s2_fn'::oid), array[(:'s2_src'::oid::regclass)::text || ':pgpm_regrain_capture'],
  'LIVENESS: S2''s capture function, moved to u348b_cap, fires on the source being regrained');
select is(
  (select array_agg(s.kind || '=' || s.obj order by s.kind) from pgpm.scratch s),
  array['hypertable_delta_fn=' || :'s6_fn', 'hypertable_dest=' || :'s3_dest'],
  'LIVENESS: pgpm.scratch records S3''s copy and S6''s function, and nothing of S4''s and S5''s');

-- ======================================================================================================
-- PHASE 0: an install older than pgpm._drop_by_oid still uninstalls (rolled back after)
-- ======================================================================================================
begin;
drop function pgpm._drop_by_oid(regclass, text);
\ir :uninstall
select is(to_regnamespace('pgpm'), null, 'PHASE 0: without pgpm._drop_by_oid the uninstall went through');
select is(
  (select count(*)::int from pg_class where oid in (:'s1_delta'::oid, :'s3_dest'::oid, :'s4_d1'::oid, :'s5_c1'::oid)), 0,
  'PHASE 0: and dropped S1''s recorded delta, S3''s recorded copy, S4''s and S5''s commented ones');
rollback;
select isnt(to_regprocedure('pgpm._drop_by_oid(regclass,text)'), null, 'PHASE 0: rolled back, pgpm._drop_by_oid is back');

-- ======================================================================================================
-- PHASE 1 (S6): the DROP FUNCTION waits for the function's own lock; the schema is swapped meanwhile
-- ======================================================================================================
select pg_temp.arm('h348_6', format('comment on function %s is %L', :'s6_fn'::oid::regprocedure, 'held'), 's6', :'s6_fn', true,
  'alter schema u348g rename to u348g_aside; create schema u348g; '
  || 'create function u348g.h6_pgpm_delta_fn() returns trigger language plpgsql as $f$ begin return new; end $f$; '
  || 'create table u348g.mine (id bigint); '
  || 'create trigger mine_trg before insert on u348g.mine for each row execute function u348g.h6_pgpm_delta_fn()',
  'u348g.h6_pgpm_delta_fn()') as h6 \gset
\set ON_ERROR_STOP 0
begin;
\ir :uninstall
rollback;
\set ON_ERROR_STOP 1
select is(:'LAST_ERROR_SQLSTATE'::text, 'P0001', 'S6: the uninstall refused with a raised exception');
select ok(strpos(:'LAST_ERROR_MESSAGE'::text,
    format('refusing to uninstall: dropping from_hypertable''s hypertable_delta_fn of the hypertable with oid %s, oid %s, reached another object under its name',
           :'s6_ht', :'s6_fn')) > 0,
  'S6: naming the function''s oid and that the drop reached another object');
select is(pg_temp.disarm('h348_6'), 'true', 'S6: the holder''s round trip completed');
select ok((select waited from public.u348_witness where tag = 's6'),
  'LIVENESS: S6''s DROP FUNCTION waited for ACCESS EXCLUSIVE on the recorded function''s oid behind the COMMENT');
select ok((select squat is not null and squat <> :'s6_fn'::oid from public.u348_witness where tag = 's6'),
  'LIVENESS: S6''s function name denotes the namesake when the wait ends');
select isnt(to_regnamespace('pgpm'), null, 'S6: the refusal dropped nothing: the pgpm schema is still there');
select is(pg_temp.triggers_of((select squat from public.u348_witness where tag = 's6')), array['u348g.mine:mine_trg'],
  'S6: the namesake function survives, with the operator''s trigger on u348g.mine');
select is(pg_temp.triggers_of(:'s6_fn'::oid), array['u348g_src.h6:h6_pgpm_delta_trg'],
  'S6: and the recorded function, now u348g_aside, is as it was, firing on the hypertable');

-- ======================================================================================================
-- PHASE 1b (S7): the same refusal in the regrain sweep, from a client that carries on past an error (psql -f with
-- neither ON_ERROR_STOP nor --single-transaction): it must stop the schema drop all the same
-- ======================================================================================================
select pg_temp.arm('h348_7', format('comment on function %s is %L', :'s7_fn'::oid::regprocedure, 'held'), 's7', :'s7_fn', true,
  format('alter schema u348h rename to u348h_aside; create schema u348h; '
         'create function u348h.%I() returns trigger language plpgsql as $f$ begin return new; end $f$; '
         'create table u348h.mine (id bigint); '
         'create trigger mine_trg before insert on u348h.mine for each row execute function u348h.%I()', :'s7_fname', :'s7_fname'),
  format('u348h.%I()', :'s7_fname')) as h7 \gset
\set ON_ERROR_STOP 0
\ir :uninstall
\set ON_ERROR_STOP 1
select is(:'LAST_ERROR_SQLSTATE'::text, 'P0001', 'S7: the plain run refused with a raised exception');
select ok(strpos(:'LAST_ERROR_MESSAGE'::text,
    format('refusing to uninstall: dropping the regrain capture function of u348h.t, oid %s, reached another object under its name', :'s7_fn')) > 0,
  'S7: at the regrain capture function, naming its oid');
select is(pg_temp.disarm('h348_7'), 'true', 'S7: the holder''s round trip completed');
select ok((select waited from public.u348_witness where tag = 's7'),
  'LIVENESS: S7''s DROP FUNCTION waited for ACCESS EXCLUSIVE on the recorded capture function''s oid behind the COMMENT');
select ok((select squat is not null and squat <> :'s7_fn'::oid from public.u348_witness where tag = 's7'),
  'LIVENESS: S7''s function name denotes the namesake when the wait ends');
select isnt(to_regnamespace('pgpm'), null, 'S7: the refusal stopped the schema drop, though the client carried on past it');
select is(pg_temp.recorded_capture(to_regclass('u348h_aside.t')),
  array[:'s7_fn'::oid, :'s7_delta'::oid],
  'S7: and pgpm.config still records the capture function and delta the refusal left, for the next run to drop');
select is(pg_temp.triggers_of((select squat from public.u348_witness where tag = 's7')), array['u348h.mine:mine_trg'],
  'S7: the namesake function keeps the operator''s trigger');

-- ======================================================================================================
-- PHASE 2: one uninstall, five waits, a schema swapped during each
-- ======================================================================================================
select pg_temp.arm('h348_1', format('lock table %s in access share mode', :'s1_delta'::oid::regclass), 's1', :'s1_delta', false,
  format('alter schema u348a rename to u348a_aside; create schema u348a; create table u348a.%I (id bigint); insert into u348a.%I values (1), (2)',
         (select relname from pg_class where oid = :'s1_delta'), (select relname from pg_class where oid = :'s1_delta')),
  format('u348a.%I', (select relname from pg_class where oid = :'s1_delta'))) as h1 \gset
select pg_temp.arm('h348_2', format('lock table %s in access share mode', :'s2_src'::oid::regclass), 's2', :'s2_src', false,
  format('alter schema u348b_cap rename to u348b_cap_aside; create schema u348b_cap; create table u348b_cap.%I (id bigint); '
         'insert into u348b_cap.%I values (5); '
         'create function u348b_cap.%I() returns trigger language plpgsql as $f$ begin return new; end $f$; '
         'create table u348b_cap.mine (id bigint); '
         'create trigger mine_trg before insert on u348b_cap.mine for each row execute function u348b_cap.%I()',
         (select relname from pg_class where oid = :'s2_delta'), (select relname from pg_class where oid = :'s2_delta'),
         (select proname from pg_proc where oid = :'s2_fn'), (select proname from pg_proc where oid = :'s2_fn')),
  format('u348b_cap.%I', (select relname from pg_class where oid = :'s2_delta'))) as h2 \gset
select pg_temp.arm('h348_3', 'lock table u348c.h3_pgpm_dest in access share mode', 's3', :'s3_dest', false,
  'alter schema u348c rename to u348c_aside; create schema u348c; create table u348c.h3_pgpm_dest (id bigint); '
  || 'insert into u348c.h3_pgpm_dest values (7), (8), (9)',
  'u348c.h3_pgpm_dest') as h3 \gset
select pg_temp.arm('h348_4', 'lock table u348d1.e1_pgpm_delta in access share mode', 's4', :'s4_d1', false,
  'alter schema u348d2 rename to u348d2_aside; create schema u348d2; create table u348d2.e2_pgpm_delta (id bigint); '
  || 'insert into u348d2.e2_pgpm_delta values (31); '
  || 'create function u348d2.e2_pgpm_delta_fn() returns trigger language plpgsql as $f$ begin return new; end $f$; '
  || 'create table u348d2.e2 (id bigint); '
  || 'create trigger e2_mine before insert on u348d2.e2 for each row execute function u348d2.e2_pgpm_delta_fn()',
  'u348d2.e2_pgpm_delta') as h4 \gset
select pg_temp.arm('h348_5', 'lock table u348e1.f1_pgpm_dest in access share mode', 's5', :'s5_c1', false,
  'alter schema u348e2 rename to u348e2_aside; create schema u348e2; create table u348e2.f2_pgpm_dest (id bigint); '
  || 'insert into u348e2.f2_pgpm_dest values (61), (62)',
  'u348e2.f2_pgpm_dest') as h5 \gset

-- psql carries on past an error here, so a refusal is read by the checks below rather than ending the file
\set ON_ERROR_STOP 0
begin;
\ir :uninstall
commit;
\set ON_ERROR_STOP 1

select is(
  array[pg_temp.disarm('h348_1'), pg_temp.disarm('h348_2'), pg_temp.disarm('h348_3'), pg_temp.disarm('h348_4'), pg_temp.disarm('h348_5')],
  array['true', 'true', 'true', 'true', 'true'], 'LIVENESS: every holder''s round trip completed and saw its wait');
select is(to_regnamespace('pgpm'), null,
  'the uninstall went through every wait, each drop following its object to where the schema went, and removed pgpm');

-- S1, the reported site
select ok((select waited from public.u348_witness where tag = 's1'),
  'LIVENESS: S1: the uninstall waited for ACCESS EXCLUSIVE on the recorded delta''s oid behind the reader');
select ok((select squat is not null and squat <> :'s1_delta'::oid from public.u348_witness where tag = 's1'),
  'LIVENESS: S1: the delta''s name denotes the namesake when the wait ends');
select is(pg_temp.ids_of((select squat from public.u348_witness where tag = 's1')), array[1, 2]::bigint[],
  'S1: the namesake keeps its rows 1 and 2');
select is((select count(*)::int from pg_class where oid = :'s1_delta'::oid), 0,
  'S1: the recorded delta, renamed aside with its schema, is gone');
select is((select count(*)::int from pg_proc where oid = :'s1_fn'::oid), 0, 'S1: and so is the recorded capture function');
select is(pg_temp.ids_of(to_regclass('u348a_aside.t')), (select array_agg(g * 10)::bigint[] from generate_series(1, 99) g) || 20000::bigint,
  'S1: the transmuted table keeps every row');

-- S2: names read before regrain_cancel waited
select ok((select waited from public.u348_witness where tag = 's2'),
  'LIVENESS: S2: regrain_cancel, inside the uninstall, waited for ACCESS EXCLUSIVE on the source behind the reader');
select ok((select squat is not null and squat <> :'s2_delta'::oid from public.u348_witness where tag = 's2'),
  'LIVENESS: S2: the delta''s name denotes the namesake when the wait ends');
select is(pg_temp.ids_of((select squat from public.u348_witness where tag = 's2')), array[5]::bigint[],
  'S2: the namesake delta keeps its row 5');
select is(
  (select array_agg(t.tgname::text) from pg_trigger t join pg_proc p on p.oid = t.tgfoid
    where t.tgrelid = to_regclass('u348b_cap.mine') and p.pronamespace = 'u348b_cap'::regnamespace),
  array['mine_trg'], 'S2: the namesake capture function survives, with the operator''s trigger on u348b_cap.mine');
select is((select count(*)::int from pg_class where oid = :'s2_delta'::oid), 0, 'S2: the recorded delta is gone');
select is((select count(*)::int from pg_proc where oid = :'s2_fn'::oid), 0, 'S2: the recorded capture function is gone');
select is((select count(*)::int from pg_trigger where tgrelid = :'s2_src'::oid and tgname like 'pgpm_regrain%'), 0,
  'S2: and the source carries no capture trigger or TRUNCATE guard');
select is(pg_temp.ids_of(:'s2_src'::oid), (select array_agg(g * 10)::bigint[] from generate_series(1, 99) g),
  'S2: the source keeps its rows');

-- S3: the record sweep's copy
select ok((select waited from public.u348_witness where tag = 's3'),
  'LIVENESS: S3: the uninstall waited for ACCESS EXCLUSIVE on the recorded copy''s oid behind the reader');
select ok((select squat is not null and squat <> :'s3_dest'::oid from public.u348_witness where tag = 's3'),
  'LIVENESS: S3: the copy''s name denotes the namesake when the wait ends');
select is(pg_temp.ids_of((select squat from public.u348_witness where tag = 's3')), array[7, 8, 9]::bigint[],
  'S3: the namesake keeps its rows 7, 8, 9');
select is((select count(*)::int from pg_class where oid = :'s3_dest'::oid), 0,
  'S3: the recorded copy (ids 301..303), renamed aside with its schema, is gone');

-- S4: the comment sweep's second delta and its function, named before the first delta's DROP waited
select ok((select waited from public.u348_witness where tag = 's4'),
  'LIVENESS: S4: the uninstall waited for ACCESS EXCLUSIVE on the first commented delta behind the reader');
select ok((select squat is not null and squat <> :'s4_d2'::oid from public.u348_witness where tag = 's4'),
  'LIVENESS: S4: the second delta''s name denotes the namesake when the wait ends');
select is(pg_temp.ids_of((select squat from public.u348_witness where tag = 's4')), array[31]::bigint[],
  'S4: the namesake delta keeps its row 31');
select is(
  (select array_agg(t.tgname::text) from pg_trigger t join pg_proc p on p.oid = t.tgfoid
    where t.tgrelid = to_regclass('u348d2.e2') and p.oid = to_regprocedure('u348d2.e2_pgpm_delta_fn()')),
  array['e2_mine'], 'S4: the namesake function survives, with the operator''s trigger on u348d2.e2');
select is((select count(*)::int from pg_class where oid in (:'s4_d1'::oid, :'s4_d2'::oid)), 0,
  'S4: both commented deltas are gone, the second (row 41) renamed aside with its schema');
select is((select count(*)::int from pg_proc where oid in (:'s4_f1'::oid, :'s4_f2'::oid)), 0,
  'S4: and both their functions');
select is((select count(*)::int from pg_trigger where tgrelid = :'s4_e2'::oid), 0,
  'S4: the second copy''s capture trigger is gone from its live table, now u348d2_aside.e2');

-- S5: the comment sweep's second copy, named before the first copy's DROP waited
select ok((select waited from public.u348_witness where tag = 's5'),
  'LIVENESS: S5: the uninstall waited for ACCESS EXCLUSIVE on the first commented copy behind the reader');
select ok((select squat is not null and squat <> :'s5_c2'::oid from public.u348_witness where tag = 's5'),
  'LIVENESS: S5: the second copy''s name denotes the namesake when the wait ends');
select is(pg_temp.ids_of((select squat from public.u348_witness where tag = 's5')), array[61, 62]::bigint[],
  'S5: the namesake keeps its rows 61, 62');
select is((select count(*)::int from pg_class where oid in (:'s5_c1'::oid, :'s5_c2'::oid)), 0,
  'S5: both commented copies are gone, the second (row 51) renamed aside with its schema');

-- S6, after the second uninstall
select is((select count(*)::int from pg_proc where oid = :'s6_fn'::oid), 0,
  'S6: the second uninstall dropped the recorded function, in u348g_aside');
select is(pg_temp.triggers_of((select squat from public.u348_witness where tag = 's6')), array['u348g.mine:mine_trg'],
  'S6: and left the namesake with its trigger');

-- S7, after the second uninstall
select is((select count(*)::int from pg_proc where oid = :'s7_fn'::oid) + (select count(*)::int from pg_class where oid = :'s7_delta'::oid), 0,
  'S7: the next run dropped the recorded capture function and delta, in u348h_aside');
select is(pg_temp.triggers_of((select squat from public.u348_witness where tag = 's7')), array['u348h.mine:mine_trg'],
  'S7: and left the namesake with its trigger');

select * from finish();

drop table public.u348_witness;
drop function public.u348_hold(text, int, oid, boolean, text, text);
drop schema u348a_aside, u348a, u348b, u348b_cap, u348b_cap_aside, u348c, u348c_aside, u348c_src, u348d1, u348d2,
  u348d2_aside, u348e1, u348e2, u348e2_aside, u348e_src, u348g, u348g_aside, u348g_src, u348h, u348h_aside cascade;
