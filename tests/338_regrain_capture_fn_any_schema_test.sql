-- untransmute and uninstall.sql drop the recorded regrain capture function wherever it lives (issue #1271).
--
-- pgpm._regrain_capture_names is the one resolver both exits use for a parent's regrain change capture: the
-- delta table and the SECURITY DEFINER trigger function whose oids the prepare tick recorded in pgpm.config.
-- It looked the function up by its oid only inside the DELTA's current schema, so once either object had been
-- moved (ALTER TABLE <delta> SET SCHEMA, or ALTER FUNCTION <fn> SET SCHEMA) the function resolved to null:
-- untransmute dropped the delta and left the function behind, and uninstall.sql did the same. docs/reference.md
-- and docs/guide.md say the delta and the function are found by oid, so one renamed or moved since is still
-- found. The resolver now returns the function's own schema (fn_nsp), and both drop sites use it.
--
-- ASYMMETRIC FIXTURE. Five parents, each with a regrain prepared and cancelled on its monolith, so the delta
-- and the function are recorded and still exist, and every row is back in the monolith (untransmute's door):
--   a338 (120 rows): the recorded DELTA moved to s338_a; the operator then creates a function of the capture's
--     name in s338_a. untransmute must drop the recorded function in public and leave the operator's.
--   b338 (70 rows): the recorded FUNCTION moved to s338_b, the delta left in public; the operator then creates
--     a function of the capture's name in public. untransmute must drop the moved one and leave the operator's.
--   c338 (40 rows), the control: nothing moved; untransmute drops both.
--   d338 (90 rows): as a338, under uninstall.sql instead of untransmute (namesake in s338_d).
--   e338 (60 rows): as b338, under uninstall.sql (the function moved to s338_e, namesake in public).
-- Every "gone" is by the recorded oid and paired with a witness that the object was there and where; every
-- namesake that must survive is checked by its own oid and body. The namesakes are what a drop in the wrong
-- schema would take instead of the recorded function, so the fix cannot pass by dropping "the" name anywhere.
--
-- The uninstall script is read with \ir, relative to this file. bench/regrain_capture_fn_any_schema.sh runs
-- this file against a mutant install.sql (regrain_capture_fn_in_delta_schema), where it is required to FAIL.
\if :{?uninstall}
\else
\set uninstall ../pgpm_core/uninstall.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(35);

create schema s338_a;
create schema s338_b;
create schema s338_d;
create schema s338_e;

-- a regrain prepared and cancelled: the delta and the function are recorded and kept, the trigger is gone
create table public.a338 (id bigint primary key, payload text);
insert into public.a338 select g, 'a' from generate_series(1, 120) g;
create table public.b338 (id bigint primary key, payload text);
insert into public.b338 select g, 'b' from generate_series(1, 70) g;
create table public.c338 (id bigint primary key, payload text);
insert into public.c338 select g, 'c' from generate_series(1, 40) g;
create table public.d338 (id bigint primary key, payload text);
insert into public.d338 select g, 'd' from generate_series(1, 90) g;
create table public.e338 (id bigint primary key, payload text);
insert into public.e338 select g, 'e' from generate_series(1, 60) g;
call pgpm.transmute('public.a338', 'id', 1000);
call pgpm.transmute('public.b338', 'id', 1000);
call pgpm.transmute('public.c338', 'id', 1000);
call pgpm.transmute('public.d338', 'id', 1000);
call pgpm.transmute('public.e338', 'id', 1000);

create function pg_temp.prepare_and_cancel(p_parent regclass) returns text language plpgsql as $f$
declare v_child name; v_step text;
begin
  perform pgpm.obtain(p_parent);
  execute format('insert into %s values (1500, %L)', p_parent::text, 'frontier');
  select child_name into v_child from pgpm.part where parent_table = p_parent and attached order by lo::numeric limit 1;
  v_step := pgpm.regrain_step(p_parent, v_child, '100');
  perform pgpm.regrain_cancel(p_parent);
  execute format('delete from %s where id = 1500', p_parent::text);   -- every row back in the monolith
  return v_step;
end $f$;

select is(pg_temp.prepare_and_cancel('public.a338') || ',' || pg_temp.prepare_and_cancel('public.b338') || ','
          || pg_temp.prepare_and_cancel('public.c338') || ',' || pg_temp.prepare_and_cancel('public.d338') || ','
          || pg_temp.prepare_and_cancel('public.e338'),
  'prepared,prepared,prepared,prepared,prepared',
  'LIVENESS: each parent''s regrain prepared, so each has a delta and a capture function to record');

select regrain_capture_fn_oid as a_fn, regrain_delta_oid as a_delta from pgpm.config where parent_table = 'public.a338'::regclass \gset
select regrain_capture_fn_oid as b_fn, regrain_delta_oid as b_delta from pgpm.config where parent_table = 'public.b338'::regclass \gset
select regrain_capture_fn_oid as c_fn, regrain_delta_oid as c_delta from pgpm.config where parent_table = 'public.c338'::regclass \gset
select regrain_capture_fn_oid as d_fn, regrain_delta_oid as d_delta from pgpm.config where parent_table = 'public.d338'::regclass \gset
select regrain_capture_fn_oid as e_fn, regrain_delta_oid as e_delta from pgpm.config where parent_table = 'public.e338'::regclass \gset

-- the operator's moves, and the operator's functions under the capture's names
alter table public.a338_pgpm_regrain_delta set schema s338_a;
alter function public.b338_pgpm_regrain_capture() set schema s338_b;
alter table public.d338_pgpm_regrain_delta set schema s338_d;
alter function public.e338_pgpm_regrain_capture() set schema s338_e;
create function s338_a.a338_pgpm_regrain_capture() returns int language sql as 'select 1338';
create function public.b338_pgpm_regrain_capture() returns int language sql as 'select 2338';
create function s338_d.d338_pgpm_regrain_capture() returns int language sql as 'select 4338';
create function public.e338_pgpm_regrain_capture() returns int language sql as 'select 5338';
select 's338_a.a338_pgpm_regrain_capture()'::regprocedure::oid as a_mine,
       'public.b338_pgpm_regrain_capture()'::regprocedure::oid as b_mine,
       's338_d.d338_pgpm_regrain_capture()'::regprocedure::oid as d_mine,
       'public.e338_pgpm_regrain_capture()'::regprocedure::oid as e_mine \gset

create function pg_temp.fn_at(p_oid oid) returns text language sql as $f$
  select n.nspname || '.' || p.proname || '()' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where p.oid = p_oid
$f$;
create function pg_temp.rel_at(p_oid oid) returns text language sql as $f$
  select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.oid = p_oid
$f$;

select is(array[pg_temp.fn_at(:'a_fn'), pg_temp.rel_at(:'a_delta')],
  array['public.a338_pgpm_regrain_capture()', 's338_a.a338_pgpm_regrain_delta'],
  'LIVENESS: (A) the recorded function is in public and the recorded delta now sits in s338_a');
select is(array[pg_temp.fn_at(:'b_fn'), pg_temp.rel_at(:'b_delta')],
  array['s338_b.b338_pgpm_regrain_capture()', 'public.b338_pgpm_regrain_delta'],
  'LIVENESS: (B) the recorded function now sits in s338_b and the recorded delta is in public');
select is(array[pg_temp.fn_at(:'c_fn'), pg_temp.rel_at(:'c_delta')],
  array['public.c338_pgpm_regrain_capture()', 'public.c338_pgpm_regrain_delta'],
  'LIVENESS: (C) the control''s recorded function and delta are both where the prepare minted them');
select is(array[pg_temp.fn_at(:'d_fn'), pg_temp.rel_at(:'d_delta')],
  array['public.d338_pgpm_regrain_capture()', 's338_d.d338_pgpm_regrain_delta'],
  'LIVENESS: (D) the recorded function is in public and the recorded delta now sits in s338_d');
select is(array[pg_temp.fn_at(:'e_fn'), pg_temp.rel_at(:'e_delta')],
  array['s338_e.e338_pgpm_regrain_capture()', 'public.e338_pgpm_regrain_delta'],
  'LIVENESS: (E) the recorded function now sits in s338_e and the recorded delta is in public');
select is(array[pg_temp.fn_at(:'a_mine'), pg_temp.fn_at(:'b_mine'), pg_temp.fn_at(:'d_mine'), pg_temp.fn_at(:'e_mine')],
  array['s338_a.a338_pgpm_regrain_capture()', 'public.b338_pgpm_regrain_capture()',
        's338_d.d338_pgpm_regrain_capture()', 'public.e338_pgpm_regrain_capture()'],
  'LIVENESS: the operator''s functions sit under the capture names in the recorded DELTA''s schema');
select ok(:'a_mine'::oid not in (:'a_fn'::oid, :'b_fn'::oid, :'d_fn'::oid, :'e_fn'::oid)
          and :'b_mine'::oid not in (:'a_fn'::oid, :'b_fn'::oid, :'d_fn'::oid, :'e_fn'::oid)
          and :'d_mine'::oid not in (:'a_fn'::oid, :'b_fn'::oid, :'d_fn'::oid, :'e_fn'::oid)
          and :'e_mine'::oid not in (:'a_fn'::oid, :'b_fn'::oid, :'d_fn'::oid, :'e_fn'::oid),
  'LIVENESS: none of the operator''s functions is one pgpm recorded');

-- ==================== untransmute (A, B, C) ====================
select lives_ok($$ select pgpm.untransmute('public.a338') $$, '(A) untransmute hands a338 back');
select lives_ok($$ select pgpm.untransmute('public.b338') $$, '(B) untransmute hands b338 back');
select lives_ok($$ select pgpm.untransmute('public.c338') $$, '(C) untransmute hands c338 back');
select is((select array_agg(c.relname::text || '=' || c.relkind::text order by c.relname)
             from pg_class c where c.oid in ('public.a338'::regclass, 'public.b338'::regclass, 'public.c338'::regclass)),
  array['a338=r', 'b338=r', 'c338=r'], 'LIVENESS: each is a plain table again, so each untransmute ran to its end');

select is((select count(*)::int from pg_proc where oid = :'a_fn'::oid), 0,
  '(A) untransmute drops the recorded capture function public.a338_pgpm_regrain_capture() after its delta moved');
select is((select count(*)::int from pg_class where oid = :'a_delta'::oid), 0,
  '(A) and the recorded delta it moved to s338_a');
select is((select prosrc from pg_proc where oid = :'a_mine'::oid), 'select 1338',
  '(A) the operator''s s338_a.a338_pgpm_regrain_capture(), beside the moved delta, survives');

select is((select count(*)::int from pg_proc where oid = :'b_fn'::oid), 0,
  '(B) untransmute drops the recorded capture function it moved to s338_b');
select is((select count(*)::int from pg_class where oid = :'b_delta'::oid), 0,
  '(B) and the recorded delta in public');
select is((select prosrc from pg_proc where oid = :'b_mine'::oid), 'select 2338',
  '(B) the operator''s public.b338_pgpm_regrain_capture(), beside the delta, survives');

select is((select count(*)::int from pg_proc where oid = :'c_fn'::oid), 0,
  '(C) the control: untransmute drops the recorded capture function');
select is((select count(*)::int from pg_class where oid = :'c_delta'::oid), 0,
  '(C) the control: and the recorded delta');

-- ==================== uninstall.sql (D, E) ====================
select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.config),
  array['d338', 'e338'], 'LIVENESS: d338 and e338 are still managed, with their capture recorded, for the uninstall');

begin;
\ir :uninstall
commit;

select is(to_regnamespace('pgpm'), null, 'LIVENESS: the uninstall went through and removed the pgpm schema');

select is((select count(*)::int from pg_proc where oid = :'d_fn'::oid), 0,
  '(D) uninstall drops the recorded capture function public.d338_pgpm_regrain_capture() after its delta moved');
select is((select count(*)::int from pg_class where oid = :'d_delta'::oid), 0,
  '(D) and the recorded delta it moved to s338_d');
select is((select prosrc from pg_proc where oid = :'d_mine'::oid), 'select 4338',
  '(D) the operator''s s338_d.d338_pgpm_regrain_capture(), beside the moved delta, survives');

select is((select count(*)::int from pg_proc where oid = :'e_fn'::oid), 0,
  '(E) uninstall drops the recorded capture function it moved to s338_e');
select is((select count(*)::int from pg_class where oid = :'e_delta'::oid), 0,
  '(E) and the recorded delta in public');
select is((select prosrc from pg_proc where oid = :'e_mine'::oid), 'select 5338',
  '(E) the operator''s public.e338_pgpm_regrain_capture(), beside the delta, survives');

-- nothing of any of the five captures is left anywhere, under any name
select is((select count(*)::int from pg_proc
            where oid in (:'a_fn'::oid, :'b_fn'::oid, :'c_fn'::oid, :'d_fn'::oid, :'e_fn'::oid)), 0,
  'no recorded capture function is left, in any schema');
select is((select count(*)::int from pg_class
            where oid in (:'a_delta'::oid, :'b_delta'::oid, :'c_delta'::oid, :'d_delta'::oid, :'e_delta'::oid)), 0,
  'no recorded delta is left, in any schema');
select is((select array_agg(n.nspname || '.' || p.proname || '=' || left(p.prosrc, 11) order by n.nspname, p.proname)
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where p.proname like '%338_pgpm_regrain_capture'),
  array['public.b338_pgpm_regrain_capture=select 2338', 'public.e338_pgpm_regrain_capture=select 5338',
        's338_a.a338_pgpm_regrain_capture=select 1338', 's338_d.d338_pgpm_regrain_capture=select 4338'],
  'exactly the operator''s four functions remain under the capture names, by schema and body');
select is((select array_agg(id order by id) from public.a338 where id in (1, 120, 121)), array[1, 120]::bigint[],
  '(A) the restored table keeps its rows, 1 to 120');
select is((select array_agg(id order by id) from public.b338 where id in (1, 70, 71)), array[1, 70]::bigint[],
  '(B) the restored table keeps its rows, 1 to 70');
select is((select array_agg(id order by id) from public.d338 where id in (1, 90, 91)), array[1, 90]::bigint[],
  '(D) the uninstalled table keeps its rows, 1 to 90');
select lives_ok($$ insert into public.e338 values (61, 'after') $$,
  '(E) the uninstalled table takes a write');

select * from finish();

drop table public.a338, public.b338, public.c338, public.d338, public.e338;
drop function public.b338_pgpm_regrain_capture(), public.e338_pgpm_regrain_capture();
drop schema s338_a cascade;
drop schema s338_b cascade;
drop schema s338_d cascade;
drop schema s338_e cascade;
