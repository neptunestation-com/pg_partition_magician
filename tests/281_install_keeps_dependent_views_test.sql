-- Re-running install.sql keeps an operator's views over pgpm's set-returning functions (issue #983).
--
-- THE DEFECT. install.sql ran `drop function if exists` before creating status(), progress(regclass),
-- observe_window(regclass, interval), check_uuidv7 and check_text_time, on every run, whatever was installed,
-- so that a widened result could be created at all (CREATE OR REPLACE cannot change a function's result or
-- rename an argument). PostgreSQL refuses to drop a function a view depends on, so one monitoring view over
-- pgpm.status() made the documented upgrade, re-running the same file, fail: the whole run rolled back under
-- --single-transaction, and plain psql -f printed the ERROR and carried on without the function's new body.
--
-- THE CONTRACT. pgpm._surface_shapes() declares the shape each of those functions is created with. A re-run
-- whose shapes did not change replaces them in place (same oid), so a view over each survives, under its own
-- oid, answering what it answered before. A function whose shape does change is dropped only when nothing
-- depends on it; when something does, pgpm._surface_prepare(), the first thing install.sql runs, refuses
-- naming the function, the dependant and the remedy, before anything else in the file has run (that half
-- needs a run without a transaction around it, so bench/install_keeps_dependent_views.sh asserts it). And a
-- declaration that drifts from what the file creates fails the install at its end (pgpm._surface_settled()).
--
-- Fixtures, asymmetric: two managed tables with different steps (so their partition counts differ), one view
-- over each declared function, each view's answer pinned by value before the re-runs and compared after.
-- bench/install_keeps_dependent_views.sh runs this file against the mutant that puts the unconditional drops
-- back (install_drops_surface_unconditionally), so it is also required to FAIL there.
--
-- install.sql is read with \ir, relative to this file; the psql variable `install` overrides the path, which
-- is how the guard points this file at a mutant.
\if :{?install}
\else
\set install ../pgpm_core/install.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(16);

create schema t281;
create table t281.ev_a (id bigint primary key, body text);
create table t281.ev_b (id bigint primary key, body text);
insert into t281.ev_a select g, 'a' || g from generate_series(1, 2500) g;
insert into t281.ev_b select g, 'b' || g from generate_series(1, 700) g;
call pgpm.transmute('t281.ev_a', 'id', 1000::bigint, p_obtain => 2);
call pgpm.transmute('t281.ev_b', 'id', 500::bigint, p_obtain => 3);
create table t281.u (id uuid);
insert into t281.u select gen_random_uuid() from generate_series(1, 3);
create table t281.tt (id text);
insert into t281.tt values ('c00000001aaaa'), ('c00000002bbbb'), ('c00000003cccc'), ('c00000004dddd');

create view t281.v_status as
  select parent, n_partitions from pgpm.status() where parent::text like 't281.%';
create view t281.v_progress as
  select parent, control_kind from pgpm.progress() where parent::text like 't281.%';
create view t281.v_window as
  select parent_table, log_rows > 0 as active from pgpm.observe_window('t281.ev_a');
create view t281.v_uuid as
  select sampled from pgpm.check_uuidv7('t281.u', 'id');
create view t281.v_tt as
  select sampled from pgpm.check_text_time('t281.tt', 'id', 'c', 8, 36, 'ms');

-- each view's answer, as one line
create function pg_temp.t281_answers() returns text language sql as $$
  select concat_ws(' / ',
    (select string_agg(parent::text || ':' || n_partitions, ',' order by parent::text) from t281.v_status),
    (select string_agg(parent::text || ':' || control_kind, ',' order by parent::text) from t281.v_progress),
    (select string_agg(parent_table::text || ':' || active, ',') from t281.v_window),
    (select string_agg(sampled::text, ',') from t281.v_uuid),
    (select string_agg(sampled::text, ',') from t281.v_tt))
$$;
-- each view and the function its rule depends on, with both oids
create function pg_temp.t281_deps() returns text language sql as $$
  select string_agg(distinct format('%s:%s->%s:%s', c.relname, c.oid, d.refobjid::regprocedure, d.refobjid),
                    ', ')
    from pg_depend d join pg_rewrite w on d.classid = 'pg_rewrite'::regclass and w.oid = d.objid
    join pg_class c on c.oid = w.ev_class
   where c.relnamespace = 't281'::regnamespace and d.refclassid = 'pg_proc'::regclass
     and d.refobjid in (select p.oid from pg_proc p where p.pronamespace = 'pgpm'::regnamespace)
$$;
-- an error as SQLSTATE: message, or 'no error'
create function pg_temp.t281_err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'no error';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;

-- ============================== (A) the views survive two re-runs, under their own oids ==============================
select is(
  (select string_agg(distinct format('%s->%s', c.relname, d.refobjid::regprocedure), ', ')
     from pg_depend d join pg_rewrite w on d.classid = 'pg_rewrite'::regclass and w.oid = d.objid
     join pg_class c on c.oid = w.ev_class
    where c.relnamespace = 't281'::regnamespace and d.refclassid = 'pg_proc'::regclass
      and d.refobjid in (select p.oid from pg_proc p where p.pronamespace = 'pgpm'::regnamespace)),
  'v_progress->pgpm.progress(regclass), v_status->pgpm.status(), '
    || 'v_tt->pgpm.check_text_time(regclass,name,text,integer,integer,text,integer,text,integer,timestamp with time zone), '
    || 'v_uuid->pgpm.check_uuidv7(regclass,name,integer), v_window->pgpm.observe_window(regclass,interval)',
  'LIVENESS: each of the five views depends on its pgpm function, so a drop of any of them would be refused');
select is(pg_temp.t281_answers(),
  't281.ev_a:3,t281.ev_b:4 / t281.ev_a:id,t281.ev_b:id / t281.ev_a:true / 3 / 4',
  'LIVENESS: and each answers, by value');
select is((select count(*)::int from pgpm._surface_unreplaceable()), 0,
  'LIVENESS: every declared function is installed in its declared shape, so a re-run has nothing to drop');

create temp table t281_before as
  select pg_temp.t281_deps() as deps, pg_temp.t281_answers() as answers,
         (select max(id) from pgpm.installed) as installed_max;

\ir :install
set client_min_messages = warning;
\ir :install
set client_min_messages = warning;

select is((select count(*)::int from pgpm.installed where id > (select installed_max from t281_before)), 2,
  'LIVENESS: both re-runs of install.sql reached the end of the file');
select is(pg_temp.t281_deps(), (select deps from t281_before),
  'every view is the relation it was, over the function it was: the same oids, replaced in place');
select is(pg_temp.t281_answers(), (select answers from t281_before),
  'and every view answers what it answered before the re-runs');
select is(pg_temp.t281_answers(),
  't281.ev_a:3,t281.ev_b:4 / t281.ev_a:id,t281.ev_b:id / t281.ev_a:true / 3 / 4',
  'which is still the pinned answer');

-- ============================== (B) a function whose shape changes, under a view ==============================
-- observe_window as it was before #304 narrowed it, an older shape, with an operator's view over it
drop view t281.v_window;
drop function pgpm.observe_window(regclass, interval);
create function pgpm.observe_window(p_parent regclass, p_since interval default '7 days')
returns table (parent_table regclass, drains bigint) language sql stable as $$ select p_parent, 0::bigint $$;
create view t281.v_old as select parent_table, drains from pgpm.observe_window('t281.ev_b');
select is((select string_agg(fn::text || ' <- ' || dependants, '; ') from pgpm._surface_unreplaceable()),
  'pgpm.observe_window(regclass,interval) <- view t281.v_old',
  'LIVENESS: the older observe_window cannot be replaced in place, and only the view over it depends on it');
select is(pg_temp.t281_err('select pgpm._surface_prepare()'),
  '2BP01: pg_partition_magician: install.sql cannot replace pgpm.observe_window(regclass,interval) (on which '
    || 'view t281.v_old depends) in place: its result or its arguments change, and PostgreSQL will not drop a '
    || 'function another object depends on. Nothing has been changed. Save each dependant''s definition (a '
    || 'view''s: select pg_get_viewdef(''<view>''::regclass, true)), drop it, re-run install.sql, then recreate '
    || 'it against the new shape.',
  'the install refuses naming the function, its dependant (and not the views over unchanged functions) and the remedy');
select is(pg_temp.t281_err('select pgpm._surface_settled()'),
  'P0001: pg_partition_magician: install.sql created pgpm.observe_window(regclass,interval) as '
    || '(p_parent regclass, p_since interval) returns TABLE(parent_table regclass, drains bigint) with 1 '
    || 'default(s), not the shape pgpm._surface_shapes() declares for it: (p_parent regclass, p_since interval) '
    || 'returns TABLE(parent_table regclass, window_start timestamp with time zone, window_end timestamp with '
    || 'time zone, duration interval, log_rows bigint, rows_copied bigint, regrains bigint, retains bigint) with '
    || '1 default(s). Update the declaration to what the file creates.',
  'and a declaration that does not match what the file created fails the install at its end');

-- ============================== (C) the same change with nothing depending on it ==============================
drop view t281.v_old;
select pg_temp.t281_deps() as deps_c \gset
select is(pg_temp.t281_err('select pgpm._surface_prepare()'), 'no error',
  'with the view gone, the install goes ahead');
select is(to_regprocedure('pgpm.observe_window(regclass,interval)'), null,
  'and drops the function whose shape changes');
select is(pg_temp.t281_deps(), :'deps_c',
  'and nothing else: the other views and their functions keep their oids');
select is(pg_temp.t281_err('select pgpm._surface_settled()'),
  'P0001: pg_partition_magician: install.sql did not create pgpm.observe_window(regclass,interval), which '
    || 'pgpm._surface_shapes() declares',
  'a declared function the file did not create fails the install at its end too');
\ir :install
set client_min_messages = warning;
select is(pg_get_function_result('pgpm.observe_window(regclass,interval)'::regprocedure),
  'TABLE(parent_table regclass, window_start timestamp with time zone, window_end timestamp with time zone, '
    || 'duration interval, log_rows bigint, rows_copied bigint, regrains bigint, retains bigint)',
  'and the re-run creates it in the shape it declares');
select is(pg_temp.t281_deps(), :'deps_c',
  'while the views over the unchanged functions stay the relations they were');

select * from finish();
