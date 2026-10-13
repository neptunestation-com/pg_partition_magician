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
-- ASYMMETRIC FIXTURE. Six parents, each with a regrain prepared and cancelled on its monolith, so the delta
-- and the function are recorded and still exist, and every row is back in the monolith (untransmute's door):
--   a338 (120 rows): the recorded DELTA moved to s338_a; the operator then creates a function of the capture's
--     name in s338_a. untransmute must drop the recorded function in public and leave the operator's.
--   b338 (70 rows): the recorded FUNCTION moved to s338_b, the delta left in public; the operator then creates
--     a function of the capture's name in public. untransmute must drop the moved one and leave the operator's.
--   c338 (40 rows), the control: nothing moved; untransmute drops both.
--   d338 (90 rows): as a338, under uninstall.sql instead of untransmute (namesake in s338_d).
--   e338 (60 rows): as b338, under uninstall.sql (the function moved to s338_e, namesake in public).
--   f338 (50 rows), the uninstall control: nothing moved; uninstall.sql drops both.
-- (F) also runs uninstall.sql against a resolver with the row type and the contract it had before fn_nsp,
-- since the script is run against installs older than itself: it must still run to its end there, and drop the
-- function that resolver answers for (f338's, beside its delta). That run is rolled back before (D) and (E).
-- Every "gone" is by the recorded oid and paired with a witness that the object was there and where; every
-- namesake that must survive is checked by its own oid and body. The namesakes are what a drop in the wrong
-- schema would take instead of the recorded function, so the fix cannot pass by dropping "the" name anywhere.
--
-- The uninstall script is read with \ir, relative to this file. bench/regrain_capture_fn_any_schema.sh runs
-- this file against a mutant install.sql (regrain_capture_fn_in_delta_schema,
-- untransmute_capture_fn_dropped_in_delta_schema) or a mutant uninstall.sql
-- (uninstall_capture_fn_dropped_in_delta_schema, uninstall_capture_fn_nsp_read_bare), where it is required to
-- FAIL.
\if :{?uninstall}
\else
\set uninstall ../pgpm_core/uninstall.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(44);

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
create table public.f338 (id bigint primary key, payload text);
insert into public.f338 select g, 'f' from generate_series(1, 50) g;
call pgpm.transmute('public.a338', 'id', 1000);
call pgpm.transmute('public.b338', 'id', 1000);
call pgpm.transmute('public.c338', 'id', 1000);
call pgpm.transmute('public.d338', 'id', 1000);
call pgpm.transmute('public.e338', 'id', 1000);
call pgpm.transmute('public.f338', 'id', 1000);

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
          || pg_temp.prepare_and_cancel('public.e338') || ',' || pg_temp.prepare_and_cancel('public.f338'),
  'prepared,prepared,prepared,prepared,prepared,prepared',
  'LIVENESS: each parent''s regrain prepared, so each has a delta and a capture function to record');

select regrain_capture_fn_oid as a_fn, regrain_delta_oid as a_delta from pgpm.config where parent_table = 'public.a338'::regclass \gset
select regrain_capture_fn_oid as b_fn, regrain_delta_oid as b_delta from pgpm.config where parent_table = 'public.b338'::regclass \gset
select regrain_capture_fn_oid as c_fn, regrain_delta_oid as c_delta from pgpm.config where parent_table = 'public.c338'::regclass \gset
select regrain_capture_fn_oid as d_fn, regrain_delta_oid as d_delta from pgpm.config where parent_table = 'public.d338'::regclass \gset
select regrain_capture_fn_oid as e_fn, regrain_delta_oid as e_delta from pgpm.config where parent_table = 'public.e338'::regclass \gset
select regrain_capture_fn_oid as f_fn, regrain_delta_oid as f_delta from pgpm.config where parent_table = 'public.f338'::regclass \gset

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
select is(array[pg_temp.fn_at(:'f_fn'), pg_temp.rel_at(:'f_delta')],
  array['public.f338_pgpm_regrain_capture()', 'public.f338_pgpm_regrain_delta'],
  'LIVENESS: (F) the uninstall control''s recorded function and delta are both where the prepare minted them');
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

-- ==================== uninstall.sql against a resolver that predates fn_nsp (F) ====================
-- uninstall.sql is also what an operator runs against an install older than the script, whose resolver returns
-- three columns and answers for the function only where it sits in the delta's schema. The script must still
-- run to its end there (a bare read of fn_nsp is 42703, which none of its handlers catch, so the uninstall
-- would stop), and must drop the function that resolver answers for, in the delta's schema, where that
-- resolver found it. The older resolver is stood up over the current one, with that row type and that
-- contract; what the script did is read inside the transaction, which is then rolled back, so (D) and (E)
-- below meet the install under test again. Each value starts as 'unread', so a script that died and left the
-- transaction aborted fails its assertion rather than leaving it unasked. ON_ERROR_STOP is off for the run, as
-- in tests/155, so a script that raises is judged by the assertions below and not by the file stopping; and
-- since pg_prove's ON_ERROR_ROLLBACK lets the script's later blocks run past a block that raised, "ran to its
-- end" is the schema gone AND nothing raised (LAST_ERROR_SQLSTATE, which no statement of this file has set).
\set f_keys unread
\set f_answers unread
\set f_ran unread
\set f_left unread
select is(:'LAST_ERROR_SQLSTATE'::text, '00000', 'LIVENESS: (F) no statement has raised before the script runs');
\set ON_ERROR_STOP 0
begin;
alter function pgpm._regrain_capture_names(regclass) rename to _regrain_capture_names_338;
create function pgpm._regrain_capture_names(p_parent regclass, out nsp name, out delta name, out fn name)
returns record language sql stable as $f$
  select x.nsp, x.delta, case when coalesce(to_jsonb(x) ->> 'fn_nsp', x.nsp::text) = x.nsp::text then x.fn end
    from pgpm._regrain_capture_names_338(p_parent) x
$f$;
select (select string_agg(k, ',' order by k) from jsonb_object_keys(to_jsonb(x)) k) as f_keys
  from pgpm._regrain_capture_names('public.f338') x \gset
select coalesce((select fn::text from pgpm._regrain_capture_names('public.f338')), 'none') || ',' ||
       coalesce((select fn::text from pgpm._regrain_capture_names('public.d338')), 'none') || ',' ||
       coalesce((select fn::text from pgpm._regrain_capture_names('public.e338')), 'none') as f_answers \gset
\ir :uninstall
select (to_regnamespace('pgpm') is null)::text as f_ran \gset
select (select count(*) from pg_proc where oid = :'f_fn'::oid) || ',' ||
       (select count(*) from pg_class where oid = :'f_delta'::oid) as f_left \gset
rollback;
\set ON_ERROR_STOP 1

select is(:'f_keys'::text, 'delta,fn,nsp',
  'LIVENESS: (F) the resolver the script met answers with the older row, which has no fn_nsp');
select is(:'f_answers'::text, 'f338_pgpm_regrain_capture,none,none',
  'LIVENESS: (F) and with the older contract: the function beside its delta, none once either was moved');
select is(array[:'f_ran', :'LAST_ERROR_SQLSTATE'], array['true', '00000'],
  '(F) uninstall.sql runs to its end, raising nothing, against a resolver that predates fn_nsp');
select is(:'f_left'::text, '0,0',
  '(F) and drops the capture function that resolver answers for, in the delta''s schema, and the delta');

-- ==================== uninstall.sql (D, E, and F the control) ====================
select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.config),
  array['d338', 'e338', 'f338'],
  'LIVENESS: d338, e338 and f338 are still managed, with their capture recorded, for the uninstall');
select is(array[pg_temp.fn_at(:'f_fn'), pg_temp.rel_at(:'f_delta'),
                coalesce(to_regprocedure('pgpm._regrain_capture_names_338(regclass)')::text, 'gone')],
  array['public.f338_pgpm_regrain_capture()', 'public.f338_pgpm_regrain_delta', 'gone'],
  'LIVENESS: the rollback put back what the older-resolver run dropped, and took the older resolver away');

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

select is((select count(*)::int from pg_proc where oid = :'f_fn'::oid), 0,
  '(F) the control: uninstall drops the recorded capture function');
select is((select count(*)::int from pg_class where oid = :'f_delta'::oid), 0,
  '(F) the control: and the recorded delta');

-- nothing of any of the six captures is left anywhere, under any name
select is((select count(*)::int from pg_proc
            where oid in (:'a_fn'::oid, :'b_fn'::oid, :'c_fn'::oid, :'d_fn'::oid, :'e_fn'::oid, :'f_fn'::oid)), 0,
  'no recorded capture function is left, in any schema');
select is((select count(*)::int from pg_class
            where oid in (:'a_delta'::oid, :'b_delta'::oid, :'c_delta'::oid, :'d_delta'::oid, :'e_delta'::oid,
                          :'f_delta'::oid)), 0,
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

drop table public.a338, public.b338, public.c338, public.d338, public.e338, public.f338;
drop function public.b338_pgpm_regrain_capture(), public.e338_pgpm_regrain_capture();
drop schema s338_a cascade;
drop schema s338_b cascade;
drop schema s338_d cascade;
drop schema s338_e cascade;
