-- A role that writes the table only through a VIEW can write the regraining partition mid-regrain, and its
-- writes are captured and survive the swap (issue #1073).
--
-- A write through an ordinary (not security_invoker) view is permission-checked as the view's OWNER, but the
-- row triggers on the base table fire as the session's role. The capture trigger used to insert into the
-- delta as that role, and _regrain_capture_grant gives INSERT on the delta only to the grantees and owners of
-- the parent and the source, so a view writer got 42501 'permission denied for table <rel>_pgpm_regrain_delta'
-- on every write into the regraining partition for the life of the regrain. The capture function now writes
-- the delta as its owner (SECURITY DEFINER, owned like the parent and the delta), whatever path the write
-- took. Its search_path is pinned (a writer's own `=` ahead of pg_catalog never runs as the table's owner),
-- held here by a behaviour, not by its spelling. Its EXECUTE stays PUBLIC's default: TimescaleDB re-creates
-- the trigger on each new chunk as the hypertable's owner, and a key another role adds to the delta through a
-- table of its own changes no row, since the reconcile takes every key from the source. And a capture minted
-- before the change (an in-flight regrain carried across the upgrade) is armed by the next tick.
--
-- Fixture, asymmetric on purpose: g294 holds ids 1..200 in one monolith [0, 300), owned by g294_own, which
-- also owns the view g294_v over it. g294_vw holds DML on the view and nothing on the table or the delta.
-- Through the view it updates ids 10 and 40, deletes ids 20 and 120, and inserts id 205: two in-place
-- changes, two rows out, one in, so a lost write and a resurrected one cannot cancel.
--   (A) after the prepare tick: update 10, delete 20, captured as keys 10, 10, 20;
--   (B) after a copy tick, with a schema of the writer's own (holding an `=` on regclass that records the
--       role it ran as) ahead of pg_catalog: delete 120 and insert 205; the `=` never ran as g294_own;
--   (C) the EXECUTE of the capture function stays PUBLIC's: g294_other attaches it to a table of its own
--       and adds keys 7 (a row of the source) and 999 (none) to the delta; after the swap row 7 is as the
--       source holds it and there is no row 999;
--   (D) the capture disarmed by hand to the pre-fix shape (SECURITY INVOKER, no search_path, EXECUTE to
--       PUBLIC) refuses the view writer, and the next tick arms it again: update 40 then goes through;
--   (E) the run swaps, and the table holds exactly those changes.
--   (F) a second table, g294f.t, whose OWNER holds no USAGE on its schema (REVOKE ALL ... FROM PUBLIC,
--       USAGE granted to the application role g294f_app alone). A definer capture could not name the delta
--       there and refused every write into the source (P1-02); the capture stays the writer-run one, and
--       g294f_app, which holds DML on the table, USAGE on the schema and INSERT on the delta, updates id 10,
--       deletes ids 20 and 30 and inserts id 205 into the regraining partition (two out, one in): captured,
--       and in the table after the swap.
--   (G) a third table, g294m, whose delta is moved mid-run (SET SCHEMA) into g294m2, a schema its owner
--       holds no USAGE on and the writer g294m_w does: the next tick puts the writer-run capture back, and
--       g294m_w's two deletes and one insert are captured in the moved delta and in the table after the swap.
--       (Between the move and that tick the definer capture cannot name the delta: a documented one-tick
--       window, not asserted here.)
-- bench/regrain_capture_view_writer.sh runs this file against the mutants capture_definer_dropped,
-- capture_definer_search_path_unpinned, capture_definer_execute_owner_only, capture_definer_not_rearmed,
-- capture_definer_owner_reach_unchecked and capture_definer_reach_by_fn_schema, so it is also required to
-- FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(33);

do $$ begin create role g294_own;   exception when duplicate_object then null; end $$;
do $$ begin create role g294_vw;    exception when duplicate_object then null; end $$;
do $$ begin create role g294_other; exception when duplicate_object then null; end $$;
grant usage on schema public to g294_own, g294_vw, g294_other;

create table public.g294 (id bigint primary key, payload text);
insert into public.g294 select g, 'a' || g from generate_series(1, 200) g;
alter table public.g294 owner to g294_own;
call pgpm.transmute('public.g294', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.g294');
insert into public.g294 values (450, 'frontier');   -- the monolith [0, 300) freezes

create view public.g294_v as select * from public.g294;
alter view public.g294_v owner to g294_own;
grant select, insert, update, delete on public.g294_v to g294_vw;

-- what the writer's own operator saw, and what each write through the view came to
create table public.g294_seen (who text);
grant insert on public.g294_seen to public;
create table public.g294_outcome (step text primary key, err text);
grant insert on public.g294_outcome to g294_vw;
create schema g294_evil;
create function g294_evil.eq(regclass, regclass) returns boolean language sql as
  $f$ insert into public.g294_seen values (current_user::text) returning pg_catalog.oideq($1::pg_catalog.oid, $2::pg_catalog.oid) $f$;
create operator g294_evil.= (leftarg = regclass, rightarg = regclass, function = g294_evil.eq);
grant usage on schema g294_evil to public;
grant execute on function g294_evil.eq(regclass, regclass) to public;

select pgpm.set_regrain('public.g294', '50');
call pgpm.maintain('public.g294');   -- prepare: capture on the source, the delta minted
select ok(exists (select 1 from pg_trigger where tgname = 'pgpm_regrain_capture'
                   and tgrelid = 'public.g294_p0000000000000000000_to_0000000000000000300'::regclass)
          and not has_table_privilege('g294_vw', 'public.g294', 'INSERT')
          and not has_table_privilege('g294_vw', 'public.g294', 'UPDATE')
          and not has_table_privilege('g294_vw', 'public.g294', 'DELETE')
          and not has_table_privilege('g294_vw', 'public.g294_p0000000000000000000_to_0000000000000000300', 'DELETE')
          and not has_table_privilege('g294_vw', 'public.g294_pgpm_regrain_delta', 'INSERT')
          and has_table_privilege('g294_vw', 'public.g294_v', 'DELETE'),
          'LIVENESS: capture is on the source, and the view writer holds DML on the view and nothing on the table, the source or the delta');

-- (A)
set role g294_vw;
do $$ begin
  update public.g294_v set payload = 'vw-10' where id = 10;
  delete from public.g294_v where id = 20;
  insert into public.g294_outcome values ('A', null);
exception when others then insert into public.g294_outcome values ('A', sqlstate || ' ' || sqlerrm);
end $$;
reset role;
select is((select coalesce(err, 'ok') from public.g294_outcome where step = 'A'), 'ok',
          'right after the prepare tick the view writer updates and deletes rows of the regraining partition through the view');
select is((select array_agg(id order by pgpm_seq) from public.g294_pgpm_regrain_delta),
          array[10, 10, 20]::bigint[],
          'and both writes were captured (the UPDATE as its old and new key, the DELETE as its old)');

-- (B)
call pgpm.maintain('public.g294');   -- copies [0, 50)
set role g294_vw;
set search_path = g294_evil, pg_catalog, public;
select 'public.g294'::regclass = 'public.g294'::regclass;
do $$ begin
  delete from public.g294_v where id = 120;
  insert into public.g294_v values (205, 'vw-205');
  insert into public.g294_outcome values ('B', null);
exception when others then insert into public.g294_outcome values ('B', sqlstate || ' ' || sqlerrm);
end $$;
reset search_path;
reset role;
select ok(exists (select 1 from public.g294_seen where who = 'g294_vw'),
          'LIVENESS: with its own schema ahead of pg_catalog, the writer''s own regclass `=` is the one its queries run');
select is((select coalesce(err, 'ok') from public.g294_outcome where step = 'B'), 'ok',
          'under that search_path the view writer deletes and inserts rows of the regraining partition through the view');
select ok(exists (select 1 from public.g294_pgpm_regrain_delta where id = 120)
          and exists (select 1 from public.g294_pgpm_regrain_delta where id = 205),
          'and both writes were captured');
select is((select array_agg(distinct who order by who) from public.g294_seen), array['g294_vw'],
          'the writer''s operator never ran as anyone but the writer: the capture, run as the table''s owner, resolved none of its names through the writer''s search_path');

-- (C)
create table public.g294_mine (id bigint primary key, payload text);
alter table public.g294_mine owner to g294_other;
set role g294_other;
select lives_ok($$ create trigger g294_mine_capture after insert on public.g294_mine for each row execute function public.g294_pgpm_regrain_capture() $$,
                'EXECUTE on the capture function stays PUBLIC''s: a role other than its owner creates a trigger with it, as TimescaleDB does on each new chunk as the hypertable''s owner');
select lives_ok($$ insert into public.g294_mine values (7, 'forged'), (999, 'forged') $$,
                'and that trigger fires on g294_other''s own table');
reset role;
select ok(exists (select 1 from public.g294_pgpm_regrain_delta where id = 7)
          and exists (select 1 from public.g294_pgpm_regrain_delta where id = 999),
          'LIVENESS: the keys g294_other wrote through its own table are in the delta');

-- (D) the capture as a release before this one minted it
alter function public.g294_pgpm_regrain_capture() security invoker;
alter function public.g294_pgpm_regrain_capture() reset search_path;
grant execute on function public.g294_pgpm_regrain_capture() to public;
set role g294_vw;
select throws_ok($$ update public.g294_v set payload = 'vw-40' where id = 40 $$,
                 '42501', 'permission denied for table g294_pgpm_regrain_delta',
                 'LIVENESS: with the capture disarmed to the pre-fix shape the view writer is refused, as #1073 found');
reset role;
call pgpm.maintain('public.g294');   -- a resuming tick
select ok((select prosecdef and proconfig = array['search_path=pg_catalog, pg_temp']
             from pg_proc where oid = 'public.g294_pgpm_regrain_capture()'::regprocedure),
          'the next tick arms the capture again: it writes as its owner, its search_path pinned');
set role g294_vw;
select lives_ok($$ update public.g294_v set payload = 'vw-40' where id = 40 $$,
                'and the view writer updates a row of the regraining partition through the view again');
reset role;

-- (E)
do $$ declare v_st text; begin
  for i in 1..20 loop
    call pgpm.maintain('public.g294', v_st);
    exit when v_st like '%regrain=swapped:%';
  end loop;
end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.g294'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          'LIVENESS: the regrain swapped the monolith into fine children');
select is((select array_agg(id || ':' || payload order by id) from public.g294
            where id in (7, 9, 10, 11, 19, 20, 21, 39, 40, 41, 119, 120, 121, 199, 200, 204, 205, 206, 999)),
          array['7:a7', '9:a9', '10:vw-10', '11:a11', '19:a19', '21:a21', '39:a39', '40:vw-40', '41:a41',
                '119:a119', '121:a121', '199:a199', '200:a200', '205:vw-205'],
          'after the swap every write through the view is in the table: the two updates hold, the two deleted rows are gone, the inserted one is there, their neighbours are untouched; and the keys g294_other added changed no row (7 as the source holds it, no 999)');
select is((select count(*)::int from public.g294), 200,
          'and the table holds its 201 rows less the two deleted plus the one inserted');

-- (F)
do $$ begin create role g294f_own; exception when duplicate_object then null; end $$;
do $$ begin create role g294f_app; exception when duplicate_object then null; end $$;
create schema g294f;
revoke all on schema g294f from public;
grant usage on schema g294f to g294f_app;
create table g294f.t (id bigint primary key, payload text);
insert into g294f.t select g, 'a' || g from generate_series(1, 200) g;
call pgpm.transmute('g294f.t', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('g294f.t');
insert into g294f.t values (450, 'frontier');   -- the monolith [0, 300) freezes
alter table g294f.t owner to g294f_own;          -- by a superuser, as an ownership role is assigned
grant select, insert, update, delete on g294f.t to g294f_app;
select pgpm.set_regrain('g294f.t', '50');
call pgpm.maintain('g294f.t');   -- prepare: capture on the source, the delta minted, owned by g294f_own
select ok(not has_schema_privilege('g294f_own', 'g294f', 'USAGE')
          and has_schema_privilege('g294f_app', 'g294f', 'USAGE')
          and (select pg_get_userbyid(proowner) = 'g294f_own' from pg_proc where oid = 'g294f.t_pgpm_regrain_capture()'::regprocedure)
          and (select pg_get_userbyid(relowner) = 'g294f_own' from pg_class where oid = 'g294f.t_pgpm_regrain_delta'::regclass)
          and has_table_privilege('g294f_app', 'g294f.t_pgpm_regrain_delta', 'INSERT')
          and exists (select 1 from pg_trigger where tgname = 'pgpm_regrain_capture'
                       and tgrelid = 'g294f.t_p0000000000000000000_to_0000000000000000300'::regclass),
          'LIVENESS: capture is on; the table''s owner owns the capture and the delta and holds no USAGE on their schema, and the application role holds USAGE and INSERT on the delta');
set role g294f_app;
select lives_ok($$ update g294f.t set payload = 'app-10' where id = 10 $$,
                'with the owner unable to name its own schema, the application role updates a row of the regraining partition');
select lives_ok($$ delete from g294f.t where id in (20, 30) $$, 'deletes two');
select lives_ok($$ insert into g294f.t values (205, 'app-205') $$, 'and inserts one');
reset role;
select is((select array_agg(id order by pgpm_seq) from g294f.t_pgpm_regrain_delta), array[10, 10, 20, 30, 205]::bigint[],
          'all three writes were captured, by key');
do $$ declare v_st text; begin
  for i in 1..20 loop
    call pgpm.maintain('g294f.t', v_st);
    exit when v_st like '%regrain=swapped:%';
  end loop;
end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'g294f.t'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          'LIVENESS: the regrain of g294f.t swapped the monolith into fine children');
select is((select array_agg(id || ':' || payload order by id) from g294f.t
            where id in (9, 10, 11, 19, 20, 21, 29, 30, 31, 199, 200, 205)),
          array['9:a9', '10:app-10', '11:a11', '19:a19', '21:a21', '29:a29', '31:a31', '199:a199', '200:a200', '205:app-205'],
          'after the swap the application role''s writes are in the table: the update holds, the two deleted rows are gone, the inserted one is there');
select is((select count(*)::int from g294f.t), 200,
          'and the table holds its 201 rows less the two deleted plus the one inserted');

-- (G)
do $$ begin create role g294m_own; exception when duplicate_object then null; end $$;
do $$ begin create role g294m_w;   exception when duplicate_object then null; end $$;
grant usage on schema public to g294m_own, g294m_w;
create table public.g294m (id bigint primary key, payload text);
insert into public.g294m select g, 'a' || g from generate_series(1, 200) g;
call pgpm.transmute('public.g294m', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.g294m');
insert into public.g294m values (450, 'frontier');   -- the monolith [0, 300) freezes
alter table public.g294m owner to g294m_own;
grant select, insert, update, delete on public.g294m to g294m_w;
create schema g294m2;
revoke all on schema g294m2 from public;
grant usage on schema g294m2 to g294m_w;
select pgpm.set_regrain('public.g294m', '50');
call pgpm.maintain('public.g294m');   -- prepare: the definer capture, the delta in public
select ok((select prosecdef from pg_proc where oid = 'public.g294m_pgpm_regrain_capture()'::regprocedure),
          'LIVENESS: the prepare tick armed the definer capture, its owner able to reach the delta in public');
alter table public.g294m_pgpm_regrain_delta set schema g294m2;   -- a superuser moves the delta mid-run
call pgpm.maintain('public.g294m');   -- the next tick
select ok(to_regclass('g294m2.g294m_pgpm_regrain_delta') is not null
          and not has_schema_privilege('g294m_own', 'g294m2', 'USAGE')
          and has_schema_privilege('g294m_w', 'g294m2', 'USAGE')
          and has_table_privilege('g294m_w', 'g294m2.g294m_pgpm_regrain_delta', 'INSERT')
          and pgpm._regrain_capture_active('public.g294m', 'g294m_p0000000000000000000_to_0000000000000000300'),
          'LIVENESS: the delta was moved mid-run into a schema its owner cannot use and the writer can; capture is still on');
select ok((select not prosecdef and proconfig is null from pg_proc where oid = 'public.g294m_pgpm_regrain_capture()'::regprocedure),
          'the tick after the move put the writer-run capture back, the owner unable to reach the delta where it now is');
set role g294m_w;
select lives_ok($$ delete from public.g294m where id in (20, 30) $$,
                'the writer deletes two rows of the regraining partition after the move');
select lives_ok($$ insert into public.g294m values (205, 'w-205') $$, 'and inserts one');
reset role;
select is((select array_agg(id order by pgpm_seq) from g294m2.g294m_pgpm_regrain_delta where id in (20, 30, 205)),
          array[20, 30, 205]::bigint[], 'all three are captured in the moved delta, by key');
do $$ declare v_st text; begin
  for i in 1..20 loop
    call pgpm.maintain('public.g294m', v_st);
    exit when v_st like '%regrain=swapped:%';
  end loop;
end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.g294m'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          'LIVENESS: the regrain of g294m swapped the monolith into fine children');
select is((select array_agg(id || ':' || payload order by id) from public.g294m
            where id in (19, 20, 21, 29, 30, 31, 199, 200, 205)),
          array['19:a19', '21:a21', '29:a29', '31:a31', '199:a199', '200:a200', '205:w-205'],
          'after the swap the writer''s changes are in the table: the two deleted rows are gone, the inserted one is there');
select is((select count(*)::int from public.g294m), 200,
          'and the table holds its 201 rows less the two deleted plus the one inserted');

select * from finish();

drop table public.g294m;
drop schema g294m2 cascade;
drop owned by g294m_own, g294m_w cascade;
drop role g294m_own;
drop role g294m_w;
drop schema g294f cascade;
drop owned by g294f_own, g294f_app cascade;
drop role g294f_own;
drop role g294f_app;
drop schema g294_evil cascade;
drop table public.g294_mine, public.g294_seen, public.g294_outcome;
drop view public.g294_v;
drop owned by g294_own, g294_vw, g294_other cascade;
drop role g294_own;
drop role g294_vw;
drop role g294_other;
