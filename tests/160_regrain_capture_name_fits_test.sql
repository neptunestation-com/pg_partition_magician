-- regrain's change-capture names are never cut to 63 bytes, so they are never the parent's own (issue #655).
--
-- _regrain_capture_derive named a parent's delta table left(<rel> || '_pgpm_regrain_delta', 63), and its
-- trigger function the same way. For a parent named 63 bytes (any ALTER TABLE ... RENAME to a name that
-- long lands there, since PostgreSQL cuts it) that expression IS the parent's name. A parent that never
-- regrained has nothing recorded in pgpm.config, so _regrain_capture_names fell back to it, and every
-- caller that clears or drops "the delta" acted on the managed table: regrain_cancel TRUNCATEd it,
-- untransmute DROPped the restored plain table, and uninstall.sql DROPped it with every partition. And an
-- upgrade (install.sql re-run over an install) recorded the parent as its OWN delta by oid, the same way.
--
-- The fix: a capture name that does not fit whole is pgpm_regrain_delta_<parent oid> /
-- pgpm_regrain_capture_<parent oid> instead, and the upgrade backfill, which has to look for the cut names
-- older releases minted under, takes only a plain non-partition table for a delta.
--
-- Fixtures are asymmetric (45, 46 and 47 rows on three 63-byte parents, so no two outcomes can be mistaken
-- for one another), and every negative ("the table still holds its rows") is paired with a witness that the
-- condition for losing them was present: the cut name really is the parent's name, nothing is recorded,
-- and the capture really works under the new names on a parent whose readable names would not fit.
-- bench/regrain_capture_name_fits.sh runs this file against mutants that put each defect back
-- (regrain_capture_name_cut, regrain_capture_backfill_adopts_parent), so it is also required to FAIL there.
--
-- install.sql and uninstall.sql are read with \ir, relative to this file; the psql variables `install` and
-- `uninstall` override the paths, which is how the guard points this file at a mutant.
\if :{?install}
\else
\set install ../pgpm_core/install.sql
\endif
\if :{?uninstall}
\else
\set uninstall ../pgpm_core/uninstall.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(28);

-- exact-length relation names (the length is what matters)
\set A customer_order_line_items_with_fulfilment_status_history_archiv
\set B customer_order_line_items_with_fulfilment_status_history_archiw
\set C customer_order_line_items_with_fulfilment_status_history_archix
\set L sensor_minute_readings_by_device_and_region_x

create schema f655;
create table f655.ea (id bigint primary key, v text);
create table f655.eb (id bigint primary key, v text);
create table f655.ec (id bigint primary key, v text);
insert into f655.ea select g, 'a' || g from generate_series(1, 45) g;
insert into f655.eb select g, 'b' || g from generate_series(1, 46) g;
insert into f655.ec select g, 'c' || g from generate_series(1, 47) g;
call pgpm.transmute('f655.ea', 'id', 10::bigint);
call pgpm.transmute('f655.eb', 'id', 1000::bigint);
call pgpm.transmute('f655.ec', 'id', 10::bigint);
alter table f655.ea rename to :A;
alter table f655.eb rename to :B;
alter table f655.ec rename to :C;

select is(
  (select string_agg(c.relname || ':' || octet_length(c.relname) || ':' || c.relkind::text, ',' order by c.relname)
     from pgpm.config g join pg_class c on c.oid = g.parent_table where c.relnamespace = 'f655'::regnamespace),
  :'A' || ':63:p,' || :'B' || ':63:p,' || :'C' || ':63:p',
  'LIVENESS: three managed partitioned parents with 63-byte names');
select is(left(:'A' || '_pgpm_regrain_delta', 63), :'A',
  'LIVENESS: the delta name cut to 63 bytes IS the parent''s name');
select is(
  (select count(*)::int from pgpm.config
    where parent_table in (format('f655.%I', :'A')::regclass, format('f655.%I', :'B')::regclass, format('f655.%I', :'C')::regclass)
      and regrain_delta_oid is null and regrain_capture_fn_oid is null and regrain_cursor is null),
  3, 'LIVENESS: none of them has regrained, so nothing is recorded and the readers fall back to a derived name');

-- ============================== (A) the derived names fit whole and are pgpm's ==============================
select is(
  (select d.delta::text || ' ' || d.fn::text from pgpm._regrain_capture_derive(format('f655.%I', :'A')::regclass) d),
  'pgpm_regrain_delta_' || format('f655.%I', :'A')::regclass::oid || ' pgpm_regrain_capture_' || format('f655.%I', :'A')::regclass::oid,
  'a 63-byte parent''s capture names are the oid form, not its own name');
select is(
  (select d.delta::text || ' ' || d.fn::text from pgpm._regrain_capture_names(format('f655.%I', :'A')::regclass) d),
  'pgpm_regrain_delta_' || format('f655.%I', :'A')::regclass::oid || ' pgpm_regrain_capture_' || format('f655.%I', :'A')::regclass::oid,
  'and with nothing recorded the resolver falls back to those');

-- ============================== (B) regrain_cancel on a parent with nothing in flight ==============================
create temp table a_children as
  select array_agg(child_oid order by lo::numeric) as oids from pgpm.part where parent_table = format('f655.%I', :'A')::regclass;
select is(pgpm.regrain_cancel(format('f655.%I', :'A')::regclass), 0, 'regrain_cancel has no copies to discard');
select is(
  (select array_agg(id order by id) from f655.:A),
  (select array_agg(g::bigint order by g) from generate_series(1, 45) g),
  'and the managed table still holds its ids 1..45 (it was not truncated)');
select is(
  (select array_agg(p.child_oid order by p.lo::numeric) from pgpm.part p where p.parent_table = format('f655.%I', :'A')::regclass),
  (select oids from a_children), 'and every one of its partitions is the relation it was');

-- ============================== (C) the upgrade backfill does not record the parent as its own delta ==============================
select is(to_regclass(format('f655.%I', left(:'A' || '_pgpm_regrain_delta', 63))), format('f655.%I', :'A')::regclass,
  'LIVENESS: the name older releases minted the delta under resolves to the parent itself');
\ir :install
set client_min_messages = warning;
select is((select regrain_delta_oid from pgpm.config where parent_table = format('f655.%I', :'A')::regclass), null::oid,
  'install.sql re-run over the install records no delta for the 63-byte parent');
select is(pgpm.regrain_cancel(format('f655.%I', :'A')::regclass), 0, 'regrain_cancel after the upgrade has nothing to discard');
select is(
  (select array_agg(id order by id) from f655.:A),
  (select array_agg(g::bigint order by g) from generate_series(1, 45) g),
  'and the managed table still holds its ids 1..45 after the upgrade');

-- ============================== (D) a parent whose readable capture names do not fit still regrains ==============================
-- 45 bytes: its minute cells fit (45 + 2 + 15 = 62), its readable capture names do not (64 and 66). uuidv7,
-- whose frontier is its data, so a row past the monolith freezes it at once (as tests/150 section E does).
create table f655.eu (id uuid primary key, payload text);
insert into f655.eu values
  (pgpm._ts_to_uuid(date_trunc('minute', now()) - interval '3 minutes' + interval '10 s'), 'one'),
  (pgpm._ts_to_uuid(date_trunc('minute', now()) - interval '3 minutes' + interval '20 s'), 'two'),
  (pgpm._ts_to_uuid(date_trunc('minute', now()) - interval '3 minutes' + interval '40 s'), 'three'),
  (pgpm._ts_to_uuid(date_trunc('minute', now()) - interval '2 minutes' + interval '10 s'), 'four');
call pgpm.transmute('f655.eu', 'id', interval '1 minute', p_obtain => 6);
insert into f655.eu values (pgpm._ts_to_uuid(date_trunc('minute', now()) + interval '4 minutes 5 s'), 'frontier');
alter table f655.eu rename to :L;
select child_name as mono from pgpm.part where parent_table = format('f655.%I', :'L')::regclass and attached
 order by lo::timestamptz limit 1 \gset
select is(octet_length(:'L') || '/' || octet_length(:'L' || '_pgpm_regrain_delta') || '/' || octet_length(:'L' || '_pgpm_regrain_capture'),
  '45/64/66', 'LIVENESS: the parent''s readable delta and function names would be 64 and 66 bytes');
select ok(:'mono' like '%\_to\_%', 'LIVENESS: its history is one coarse monolith: ' || :'mono');

select is(pgpm.regrain_step(format('f655.%I', :'L')::regclass, :'mono'), 'prepared', 'the prepare tick installs capture');
select is(
  (select regrain_delta_oid::text || ' ' || regrain_capture_fn_oid::text from pgpm.config where parent_table = format('f655.%I', :'L')::regclass),
  to_regclass(format('f655.pgpm_regrain_delta_%s', format('f655.%I', :'L')::regclass::oid))::oid::text || ' '
    || to_regprocedure(format('f655.pgpm_regrain_capture_%s()', format('f655.%I', :'L')::regclass::oid))::oid::text,
  'under the oid-form names, recorded by oid');

update f655.:L set payload = 'one-updated' where payload = 'one';
delete from f655.:L where payload = 'two';
insert into f655.:L values (pgpm._ts_to_uuid(date_trunc('minute', now()) - interval '3 minutes' + interval '50 s'), 'five');
select is(pgpm._regrain_delta_count(format('f655.%I', :'L')::regclass), 4::bigint,
  'LIVENESS: the capture saw the update (old and new), the delete and the insert made during the regrain');

create function pg_temp.finish(p_parent regclass, p_child name) returns text language plpgsql as $f$
begin
  return 'swapped:' || pgpm.regrain(p_parent, p_child);
exception when others then return 'error: ' || sqlerrm;
end $f$;
select matches(pg_temp.finish(format('f655.%I', :'L')::regclass, :'mono'), '^swapped:[0-9]+$', 'the regrain completes');
select is((select string_agg(payload, ',' order by id) from f655.:L),
  'one-updated,three,five,four,frontier',
  'every change made during the regrain is honoured after the swap: the update, the delete and the insert');
select is((select count(*)::int from pgpm.part where parent_table = format('f655.%I', :'L')::regclass and child_name = :'mono'), 0,
  'and the monolith is gone, replaced by its minute cells');

-- ============================== (E) untransmute of a parent that never regrained ==============================
select lives_ok(format($$ select pgpm.untransmute('f655.%I') $$, :'B'), 'untransmute runs');
select is(
  (select relkind::text from pg_class where oid = to_regclass(format('f655.%I', :'B'))) || '|'
    || (select (array_agg(id order by id) = (select array_agg(g::bigint order by g) from generate_series(1, 46) g))::text from f655.:B),
  'r|true', 'and leaves the restored plain table under its name, holding its ids 1..46');

-- ============================== (F) uninstall.sql ==============================
select is(
  (select (to_regclass(format('f655.pgpm_regrain_delta_%s', format('f655.%I', :'L')::regclass::oid)) is not null)::text || '/'
          || (to_regprocedure(format('f655.pgpm_regrain_capture_%s()', format('f655.%I', :'L')::regclass::oid)) is not null)::text),
  'true/true', 'LIVENESS: the regrained parent''s capture table and function exist under their oid-form names');
select format('f655.pgpm_regrain_delta_%s', format('f655.%I', :'L')::regclass::oid) as l_delta,
       format('f655.pgpm_regrain_capture_%s()', format('f655.%I', :'L')::regclass::oid) as l_fn \gset
begin;
\ir :uninstall
commit;
select is(to_regnamespace('pgpm'), null, 'LIVENESS: uninstall.sql went through and removed the pgpm schema');
select is(
  (select relkind::text from pg_class where oid = to_regclass(format('f655.%I', :'C'))) || '|'
    || (select (array_agg(id order by id) = (select array_agg(g::bigint order by g) from generate_series(1, 47) g))::text from f655.:C),
  'p|true', 'uninstall.sql leaves the never-regrained 63-byte table partitioned, holding its ids 1..47');
select is(
  (select array_agg(id order by id) from f655.:A),
  (select array_agg(g::bigint order by g) from generate_series(1, 45) g),
  'and the other one its ids 1..45');
select is((to_regclass(:'l_delta') is null)::text || '/' || (to_regprocedure(:'l_fn') is null)::text, 'true/true',
  'while it does remove the regrained parent''s oid-form capture table and function');
select is((select string_agg(payload, ',' order by id) from f655.:L), 'one-updated,three,five,four,frontier',
  'and leaves that parent''s rows as they were');

select * from finish();
