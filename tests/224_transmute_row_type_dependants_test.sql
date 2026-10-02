-- transmute refuses a table whose ROW TYPE other objects are typed by (#815's bullet F1-02).
--
-- #779 refused the objects that name the table by its oid (views, rules, BEGIN ATOMIC bodies, other tables'
-- policies), because the cutover renames the original table, and that oid with it, into the monolith
-- partition. The table's row type (its pg_type, and that type's array type) goes with the oid too, and the
-- refusal asked pg_depend about the table's pg_class row alone. So a function taking the table's row type,
-- or another table's column of that type, followed the type into the monolith: after the conversion
-- f(t) no longer accepted the table's rows (42883), the column rejected them (42804), and the monolith
-- could never be dropped, by retention or by hand, because both depend on its type. They are now refused
-- the same way, named with the rest, before anything is committed and again under the cutover's lock.
--
-- Fixtures, asymmetric on purpose: rt224 has four objects typed by its row type (a function taking a row,
-- a function taking an array of rows, another table's column and a domain), and two that must NOT be
-- named: a function typed by an unrelated table's row type and the unrelated table's own column. The
-- refusal names exactly the four; nothing is committed and the function still takes the table's rows; with
-- the four dropped the same call converts, a function re-created over the converted table takes the
-- forward partition's row as well as the monolith's, and nothing outside pgpm is bound to the monolith's
-- row type, so retention can drop it.
-- The refusal is pinned by its message (throws_like): a committing procedure that does NOT refuse dies at
-- its first COMMIT inside pgTAP with 2D000, which an unpinned assertion would accept.
-- bench/transmute_row_type_dependants.sh runs this file against the mutations that put the defect back
-- (bench/mutations/mutate.py), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(10);

set client_min_messages = warning;

create table public.rt224 (id int8 primary key, v text);
insert into public.rt224 select g, 'r' || g from generate_series(1, 3) g;   -- step 100: monolith [0, 100)
create table public.other224 (id int8);
create function public.row224(r public.rt224) returns int8 language sql as 'select r.id';
create function public.arr224(r public.rt224[]) returns int language sql as 'select cardinality(r)';
create table public.audit224 (r public.rt224, n int);
create domain public.d224 as public.rt224;
-- and the two that are not refused
create function public.oth224(r public.other224) returns int8 language sql as 'select r.id';
create table public.keep224 (o public.other224);

select is((select array_agg(public.row224(x) order by 1) from public.rt224 x), array[1, 2, 3]::int8[],
  'LIVENESS: before the conversion row224 takes the table''s rows (ids 1 to 3)');
select is((select count(distinct d.classid::text || ':' || d.objid || ':' || d.objsubid)::int
             from pg_depend d join pg_type ty on ty.oid = d.refobjid
            where d.refclassid = 'pg_type'::regclass and d.deptype = 'n'
              and (ty.typrelid = 'public.rt224'::regclass
                   or ty.oid = (select typarray from pg_type where typrelid = 'public.rt224'::regclass))),
  4, 'LIVENESS: four objects depend on rt224''s row type or its array type, none of them on its pg_class row');
select throws_like($$ call pgpm.transmute('public.rt224', 'id', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: cannot transmute rt224 -- the object(s) (column audit224.r, function arr224(rt224[]), function row224(rt224), type d224) name it by its oid,%',
  'the refusal names exactly the four objects typed by the table''s row type, and not oth224 or keep224.o');
select is((select relkind::text from pg_class where oid = 'public.rt224'::regclass), 'r', 'rt224 is still a plain table');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.rt224'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.rt224'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.rt224'::regclass),
  'no bound, no claim and no config row were committed');
select is((select array_agg(public.row224(x) order by 1) from public.rt224 x), array[1, 2, 3]::int8[],
  'row224 still takes the table''s rows');

drop function public.row224(public.rt224);
drop function public.arr224(public.rt224[]);
alter table public.audit224 drop column r;
drop domain public.d224;
call pgpm.transmute('public.rt224', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.rt224'::regclass), 'p',
  'LIVENESS: with the four dropped, the same call converts rt224 (oth224 and keep224 did not stop it)');
insert into public.rt224 values (150, 'forward');
select isnt((select tableoid from public.rt224 where id = 150),
            (select monolith_oid from pgpm.config where parent_table = 'public.rt224'::regclass),
  'LIVENESS: id 150 landed in a forward partition, not the monolith');
create function public.row224(r public.rt224) returns int8 language sql as 'select r.id';
select is((select array_agg(public.row224(x) order by 1) from public.rt224 x), array[1, 2, 3, 150]::int8[],
  'a function re-created over the converted table takes the monolith''s rows and the forward partition''s id 150');
select ok(not exists (select 1 from pgpm.config c
                        join pg_type ty on ty.typrelid = c.monolith_oid
                        join pg_depend d on d.refclassid = 'pg_type'::regclass and d.deptype = 'n'
                                        and d.refobjid in (ty.oid, ty.typarray)
                       where c.parent_table = 'public.rt224'::regclass),
  'nothing depends on the monolith partition''s row type, so retention can drop it');

select * from finish();
