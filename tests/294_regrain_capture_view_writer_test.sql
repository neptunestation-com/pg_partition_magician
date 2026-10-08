-- A role that writes the table only through a VIEW can write the regraining partition mid-regrain, and its
-- writes are captured and survive the swap (issue #1073).
--
-- A write through an ordinary (not security_invoker) view is permission-checked as the view's OWNER, but the
-- row triggers on the base table fire as the session's role. The capture trigger used to insert into the
-- delta as that role, and _regrain_capture_grant gives INSERT on the delta only to the grantees and owners of
-- the parent and the source, so a view writer got 42501 'permission denied for table <rel>_pgpm_regrain_delta'
-- on every write into the regraining partition for the life of the regrain. The capture function now writes
-- the delta as its owner (SECURITY DEFINER, owned like the parent and the delta), whatever path the write
-- took. Two clauses go with a definer function, and each is held here by a behaviour, not by its spelling:
-- its search_path is pinned (a writer's own `=` ahead of pg_catalog never runs as the table's owner), and
-- its EXECUTE is the owner's alone (no role can attach it to a table of its own). And a capture minted
-- before the change (an in-flight regrain carried across the upgrade) is armed by the next tick.
--
-- Fixture, asymmetric on purpose: g294 holds ids 1..200 in one monolith [0, 300), owned by g294_own, which
-- also owns the view g294_v over it. g294_vw holds DML on the view and nothing on the table or the delta.
-- Through the view it updates ids 10 and 40, deletes ids 20 and 120, and inserts id 205: two in-place
-- changes, two rows out, one in, so a lost write and a resurrected one cannot cancel.
--   (A) after the prepare tick: update 10, delete 20, captured as keys 10, 10, 20;
--   (B) after a copy tick, with a schema of the writer's own (holding an `=` on regclass that records the
--       role it ran as) ahead of pg_catalog: delete 120 and insert 205; the `=` never ran as g294_own;
--   (C) the EXECUTE of the capture function: g294_other cannot attach it to a table of its own;
--   (D) the capture disarmed by hand to the pre-fix shape (SECURITY INVOKER, no search_path, EXECUTE to
--       PUBLIC) refuses the view writer, and the next tick arms it again: update 40 then goes through;
--   (E) the run swaps, and the table holds exactly those changes.
-- bench/regrain_capture_view_writer.sh runs this file against the mutants capture_definer_dropped,
-- capture_definer_search_path_unpinned, capture_definer_execute_kept and capture_definer_not_rearmed, so it
-- is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(16);

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
create function public.g294_mine_fn() returns trigger language plpgsql as $f$ begin return null; end $f$;
alter function public.g294_mine_fn() owner to g294_other;
select ok(not has_function_privilege('g294_other', 'public.g294_pgpm_regrain_capture()', 'EXECUTE')
          and not has_function_privilege('g294_vw', 'public.g294_pgpm_regrain_capture()', 'EXECUTE'),
          'no role but its owner holds EXECUTE on the capture function, PUBLIC included');
set role g294_other;
select lives_ok($$ create trigger g294_mine_own after delete on public.g294_mine for each row execute function public.g294_mine_fn() $$,
                'LIVENESS: g294_other may put a trigger on a table of its own');
select throws_ok($$ create trigger g294_mine_capture after delete on public.g294_mine for each row execute function public.g294_pgpm_regrain_capture() $$,
                 '42501', NULL,
                 'so g294_other cannot attach the capture function, which writes the delta as the table''s owner, to a table of its own');
reset role;

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
             from pg_proc where oid = 'public.g294_pgpm_regrain_capture()'::regprocedure)
          and not has_function_privilege('g294_other', 'public.g294_pgpm_regrain_capture()', 'EXECUTE'),
          'the next tick arms the capture again: it writes as its owner, its search_path pinned, its EXECUTE the owner''s alone');
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
            where id in (9, 10, 11, 19, 20, 21, 39, 40, 41, 119, 120, 121, 199, 200, 204, 205, 206)),
          array['9:a9', '10:vw-10', '11:a11', '19:a19', '21:a21', '39:a39', '40:vw-40', '41:a41',
                '119:a119', '121:a121', '199:a199', '200:a200', '205:vw-205'],
          'after the swap every write through the view is in the table: the two updates hold, the two deleted rows are gone, the inserted one is there, their neighbours are untouched');
select is((select count(*)::int from public.g294), 200,
          'and the table holds its 201 rows less the two deleted plus the one inserted');

select * from finish();

drop schema g294_evil cascade;
drop table public.g294_mine, public.g294_seen, public.g294_outcome;
drop view public.g294_v;
drop owned by g294_own, g294_vw, g294_other cascade;
drop role g294_own;
drop role g294_vw;
drop role g294_other;
