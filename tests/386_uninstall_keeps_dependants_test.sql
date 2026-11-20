-- uninstall.sql refuses, naming them, while objects outside schema pgpm depend on it (issue #1040).
--
-- THE GAP. uninstall.sql ends in `drop schema pgpm cascade`, and CASCADE takes everything that depends on an object
-- in pgpm, wherever it lives: an operator's monitoring view over pgpm.status() in their own schema, a function of
-- theirs returning pgpm.archive_result (the archive strategy contract), a column default calling a pgpm function.
-- None is pgpm's to remove; the guide says only the pgpm schema's own views go, and install.sql already refuses a
-- change a view depends on (#983), naming it. The uninstall dropped all of them silently.
--
-- THE CONTRACT.
--   PART A  with such dependants the uninstall refuses (2BP01), naming each one, and drops nothing: the pgpm schema,
--           every dependant, and the operator's table under the default are as they were.
--   PART B  pgpm's own objects are not named: a view the operator put IN schema pgpm (the schema drop's to take, as
--           the guide says), and the pgpm_regrain_truncate_guard trigger pgpm put on a partition it is regraining.
--   PART C  with the named dependants dropped, the uninstall goes through, and what is the operator's and does not
--           depend on pgpm (a view over their own table) stays, answering what it answered.
--
-- The uninstall script is read with \ir, relative to this file. bench/uninstall_keeps_dependants.sh runs this file
-- against a mutant uninstall.sql by setting the psql variable `uninstall` to its path.
\if :{?uninstall}
\else
\set uninstall ../pgpm_core/uninstall.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(16);

create schema ops386;
create view ops386.health as select parent, paused from pgpm.status();
create materialized view ops386.recent as select id, action from pgpm.log;
create function ops386.strategy(p_parent regclass, p_child regclass, p_lo text, p_hi text)
returns pgpm.archive_result language sql as $$ select null::pgpm.archive_result $$;
create table ops386.notes (id int primary key, kind text default pgpm._native_type('id'));
insert into ops386.notes (id) values (1), (2);
create view ops386.plain as select id from ops386.notes;
create view pgpm.ops386_inside as select parent from pgpm.status();

-- a regrain in flight, so a pgpm trigger that calls a pgpm function sits on a partition in public
create table public.t386 (id bigint primary key, body text);
insert into public.t386 select g, 'b' || g from generate_series(1, 3000) g;
call pgpm.transmute('public.t386', 'id', 1000, p_obtain => 2, p_paused => true);
insert into public.t386 values (4500, 'sentinel');
select is(pgpm.regrain_step('public.t386',
            (select child_name from pgpm.part where parent_table = 'public.t386'::regclass and attached order by lo::numeric limit 1),
            '1000', 100),
  'prepared', 'LIVENESS: a regrain of t386''s monolith is prepared');
select is((select string_agg(t.tgname || ':' || p.oid::regprocedure::text, ',') from pg_trigger t join pg_proc p on p.oid = t.tgfoid
            where t.tgrelid in (select inhrelid from pg_inherits where inhparent = 'public.t386'::regclass)
              and p.pronamespace = 'pgpm'::regnamespace),
  'pgpm_regrain_truncate_guard:pgpm._regrain_truncate_guard()',
  'LIVENESS: pgpm''s TRUNCATE guard, which calls a pgpm function, is on the partition being regrained');

-- ======================================================================================================
-- first uninstall: refused, in one transaction, as the script says to run it
-- ======================================================================================================
\set ON_ERROR_STOP 0
begin;
\ir :uninstall
rollback;
\set ON_ERROR_STOP 1

select is(:'LAST_ERROR_SQLSTATE'::text, '2BP01', '(A) the uninstall refused with dependent_objects_still_exist');
select matches(:'LAST_ERROR_MESSAGE'::text, '^pg_partition_magician: refusing to uninstall: dropping schema pgpm would also drop ',
  '(A) in pgpm''s words');
select matches(:'LAST_ERROR_MESSAGE'::text, 'view ops386\.health[,.]', '(A) naming the view over pgpm.status()');
select matches(:'LAST_ERROR_MESSAGE'::text, 'materialized view ops386\.recent[,.]', '(A) the materialized view over pgpm.log');
select matches(:'LAST_ERROR_MESSAGE'::text, 'function ops386\.strategy\(regclass,regclass,text,text\)', '(A) the strategy function returning a pgpm type');
select matches(:'LAST_ERROR_MESSAGE'::text, 'default value for column kind of table ops386\.notes', '(A) and the default calling a pgpm function');
select doesnt_match(:'LAST_ERROR_MESSAGE'::text, 'ops386_inside|truncate_guard|ops386\.plain',
  '(B) and naming neither a view inside pgpm, nor pgpm''s own trigger, nor a view that does not depend on pgpm');
select ok(to_regnamespace('pgpm') is not null
          and to_regclass('ops386.health') is not null and to_regclass('ops386.recent') is not null
          and to_regprocedure('ops386.strategy(regclass,regclass,text,text)') is not null
          and pg_get_expr((select adbin from pg_attrdef where adrelid = 'ops386.notes'::regclass), 'ops386.notes'::regclass) ~ 'pgpm\._native_type',
  '(A) the refusal dropped nothing: the schema and every dependant are as they were');

-- ======================================================================================================
-- second uninstall: the named dependants dropped by the operator, it goes through
-- ======================================================================================================
drop view ops386.health;
drop materialized view ops386.recent;
drop function ops386.strategy(regclass, regclass, text, text);
alter table ops386.notes alter column kind drop default;

begin;
\ir :uninstall
commit;

select is(to_regnamespace('pgpm'), null, 'LIVENESS: the second uninstall went through and removed the pgpm schema');
select is(to_regclass('pgpm.ops386_inside'), null, '(B) the view inside schema pgpm went with it');
select is((select count(*)::int from pg_trigger where tgname = 'pgpm_regrain_truncate_guard'), 0,
  '(B) and so did pgpm''s TRUNCATE guard on the partition');
select is((select array_agg(id order by id) from ops386.plain), array[1, 2],
  '(C) the operator''s view over their own table stays, answering what it answered');
select is((select array_agg(id order by id) from public.t386 where id in (1, 3000, 4500)), array[1, 3000, 4500]::bigint[],
  '(C) the transmuted table keeps its rows');
select is((select count(*)::int from public.t386), 3001, '(C) all of them');

select * from finish();
