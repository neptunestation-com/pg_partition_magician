-- Issue #631: regrain_step's copy branch wrote into whatever relation already bore a sub-range's name,
-- and regrain_cancel dropped copies by name.
--
-- #585 made regrain_step find an in-progress sub-range's fine child by its BOUNDS in pgpm.part, and
-- render a name only to CREATE one. But the create was skipped whenever to_regclass(rendered name) was
-- not null, and the copy then inserted into that relation, whoever owned it. A managed table renamed
-- aside (harmless by contract, #496) keeps its partitions' names, so a new table created under the old
-- name and regrained copied its rows INTO the old table's partition: the review verified 49 of the new
-- table's rows landing in another table (F3-05). The same name-keyed step, one layer down: a sub-range
-- whose copy HAS a pgpm.part row copied into whatever its name resolves to now, even when that is not
-- the relation the row recorded (child_oid, #421). And regrain_cancel dropped every not-attached copy
-- with `drop table %I.%I` on its recorded name, so a relation that had taken the copy's name was the
-- one dropped, while the real copy was left behind.
--
-- The fix refuses at the clash, before a row is copied, and drops copies by the oid recorded when
-- regrain_step created them.
--
-- (A) the F3-05 shape: the name belongs to ANOTHER table's attached partition. regrain_step refuses;
--     the other table holds exactly its one row; the new table's rows stay whole in its source; once the
--     other relation is renamed aside the same regrain finishes, so the refusal is the only obstacle.
-- (B) the in-flight shape: a copy's name is taken over by an unrelated table after the copy started.
--     regrain_step refuses rather than copying into the squatter; regrain_cancel then drops the copy the
--     row recorded (by oid, under its new name) and leaves the squatter and its row alone.
--
-- (C) the recorded oid follows a recreate: a copy dropped by hand mid-regrain is created again by the
--     next tick under its row, and regrain_cancel drops that new relation, not nothing.
--
-- Fixtures are asymmetric (1 row in the other table, 2 rows copied, 1 in the squatter) and every row is
-- named, so no pair of errors can cancel.
create extension if not exists pgtap;
select plan(30);

-- A relation's rows as 'id:payload', or null when no relation bears the name: a dropped relation must
-- fail its assertion, not abort the file.
create function pg_temp.rows_of(p_rel text) returns text[] language plpgsql as $f$
declare v text[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg(id || '':'' || payload order by id) from %s', to_regclass(p_rel)) into v;
  return v;
end $f$;

-- ======================================================================================================
-- (A) another table's partition bears the name of a sub-range with no pgpm.part row
-- ======================================================================================================
create table public.nc (id bigint primary key, payload text);
insert into public.nc values (150000, 'old-row');
call pgpm.transmute('public.nc', 'id', 100000, p_obtain => 0);
alter table public.nc rename to nc_old;

select is((select array_agg(id || ':' || payload) from public.nc_old), array['150000:old-row'],
  'LIVENESS (A): the old table holds exactly its one row');
select is((select inhparent::regclass::text from pg_inherits
            where inhrelid = 'public.nc_p0000000000000100000'::regclass),
  'nc_old', 'LIVENESS (A): nc_p0000000000000100000 is an attached partition of the old table');

create table public.nc (id bigint primary key, payload text);
insert into public.nc select g, 'new' from generate_series(1000, 199000, 1000) g;
insert into public.nc values (1999999, 'widen');
call pgpm.transmute('public.nc', 'id', 1000000);
insert into public.nc values (3500000, 'frontier');
select child_name as nc_src from pgpm.part
 where parent_table = 'public.nc'::regclass and attached order by lo::numeric limit 1 \gset

select is(pgpm.regrain_step('public.nc', :'nc_src', '100000', 1000), 'prepared',
  'fixture (A): the prepare tick');
select is(pgpm.regrain_step('public.nc', :'nc_src', '100000', 1000), 'copied:99',
  'LIVENESS (A): the first sub-range [0, 100000) is copied whole (99 rows), so the copy branch runs');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.nc'::regclass), '100000',
  'LIVENESS (A): the cursor sits at the sub-range [100000, 200000) whose name the old table holds');
select is(pgpm._part_name('nc', 'id', '100000', '100000', '200000', 'UTC'), 'nc_p0000000000000100000',
  'LIVENESS (A): that sub-range renders exactly the old table''s partition name');

select throws_like(
  format($$select pgpm.regrain_step('public.nc', %L, '100000', 1000)$$, :'nc_src'),
  '%nc_p0000000000000100000 already exists and this regrain did not create it%',
  '(A) regrain_step refuses at the name clash instead of copying into the other table''s partition');

select is((select array_agg(id || ':' || payload order by id) from public.nc_old), array['150000:old-row'],
  '(A) the old table still holds exactly its one row: none of the new table''s rows went into it');
select is((select count(*) from public.nc_p0000000000000100000 where payload = 'new'), 0::bigint,
  '(A) and its partition holds no row of the new table');
select is((select array_agg(id order by id) from public.nc where id between 100000 and 199999),
  (select array_agg(g::bigint order by g) from generate_series(100000, 199000, 1000) g),
  '(A) every row of the new table''s refused sub-range is still readable through the new table');
select is((select count(*)::int from pgpm.part
            where parent_table = 'public.nc'::regclass and child_name = 'nc_p0000000000000100000'), 0,
  '(A) no pgpm.part row of the new table records the other table''s partition');

-- the operator's remedy: rename the other relation aside, and the same regrain finishes
alter table public.nc_p0000000000000100000 rename to nc_old_p0000000000000100000;
create function pg_temp.finish_regrain(p_src name) returns text language plpgsql as $f$
begin
  return 'swapped:' || pgpm.regrain('public.nc', p_src, '100000');
exception when others then return 'error: ' || sqlerrm;
end $f$;
select is(pg_temp.finish_regrain(:'nc_src'), 'swapped:20',
  '(A) with the other relation renamed aside the same regrain finishes: 20 fine partitions');
select is((select array_agg(id || ':' || payload order by id) from public.nc_old),
  array['150000:old-row'],
  '(A) the old table still holds exactly its one row after the new table''s swap');
select is((select array_agg(id order by id) from public.nc where id < 1000000),
  (select array_agg(g::bigint order by g) from generate_series(1000, 199000, 1000) g),
  '(A) every row of the new table below 1000000 survives the regrain, named one by one');
select is((select inhparent::regclass::text from pg_inherits
            where inhrelid = to_regclass('public.nc_p0000000000000100000')),
  'nc', '(A) and the name now belongs to the new table''s own fine partition');

-- ======================================================================================================
-- (B) a copy's name is taken over mid-regrain by an unrelated table
-- ======================================================================================================
create table public.cx (id bigint primary key, payload text);
insert into public.cx values (10, 'a'), (20, 'b'), (30, 'c'), (150000, 'd'), (1999999, 'widen');
call pgpm.transmute('public.cx', 'id', 1000000);
select pgpm.obtain('public.cx');
insert into public.cx values (3500000, 'frontier');
select child_name as cx_src from pgpm.part
 where parent_table = 'public.cx'::regclass and attached order by lo::numeric limit 1 \gset

select is(pgpm.regrain_step('public.cx', :'cx_src', '100000', 2), 'prepared', 'fixture (B): the prepare tick');
select is(pgpm.regrain_step('public.cx', :'cx_src', '100000', 2), 'copied:2',
  'fixture (B): one partial batch of [0, 100000): 2 of its 3 rows');
create temp table cx_copy as
  select child_oid from pgpm.part
   where parent_table = 'public.cx'::regclass and not attached and child_name = 'cx_p0000000000000000000';

alter table public.cx_p0000000000000000000 rename to cx_copy_aside;
create table public.cx_p0000000000000000000 (id bigint primary key, payload text);
insert into public.cx_p0000000000000000000 values (5, 'squatter');

select ok((select child_oid from cx_copy) = 'public.cx_copy_aside'::regclass::oid
          and (select array_agg(id order by id) from public.cx_copy_aside) = array[10, 20]::bigint[]
          and (select regrain_cursor from pgpm.config where parent_table = 'public.cx'::regclass) = '0',
  'LIVENESS (B): the recorded copy (oid) is the renamed table holding exactly 10 and 20, cursor still at 0');
select isnt('public.cx_p0000000000000000000'::regclass::oid, (select child_oid from cx_copy),
  'LIVENESS (B): the copy''s recorded name now resolves to a different relation');

select throws_like(
  format($$select pgpm.regrain_step('public.cx', %L, '100000', 2)$$, :'cx_src'),
  '%no longer names the copy this regrain created%',
  '(B) regrain_step refuses to copy into the relation that took over its copy''s name');
select is(pg_temp.rows_of('public.cx_p0000000000000000000'),
  array['5:squatter'], '(B) the squatter holds exactly its own row: nothing was copied into it');

select is(pgpm.regrain_cancel('public.cx'), 1, '(B) regrain_cancel reclaims the one in-flight copy');
select ok(not exists (select 1 from pg_class where oid = (select child_oid from cx_copy)),
  '(B) the copy it dropped is the recorded one (its oid is gone), found under its new name');
select is(pg_temp.rows_of('public.cx_p0000000000000000000'),
  array['5:squatter'], '(B) and the relation holding the copy''s old name survives with its one row');

-- ======================================================================================================
-- (C) a copy dropped by hand is recreated under its row, and the row's oid follows it
-- ======================================================================================================
create table public.rc (id bigint primary key, payload text);
insert into public.rc values (10, 'a'), (20, 'b'), (30, 'c'), (150000, 'd'), (1999999, 'widen');
call pgpm.transmute('public.rc', 'id', 1000000);
select pgpm.obtain('public.rc');
insert into public.rc values (3500000, 'frontier');
select child_name as rc_src from pgpm.part
 where parent_table = 'public.rc'::regclass and attached order by lo::numeric limit 1 \gset

select is(pgpm.regrain_step('public.rc', :'rc_src', '100000', 2), 'prepared', 'fixture (C): the prepare tick');
select is(pgpm.regrain_step('public.rc', :'rc_src', '100000', 2), 'copied:2',
  'fixture (C): one partial batch of [0, 100000)');
create temp table rc_first as select 'public.rc_p0000000000000000000'::regclass::oid as first_oid;
drop table public.rc_p0000000000000000000;

select is(pgpm.regrain_step('public.rc', :'rc_src', '100000', 2), 'copied:2',
  'LIVENESS (C): the next tick recreates the dropped copy under its row and copies into it');
select ok(to_regclass('public.rc_p0000000000000000000')::oid <> (select first_oid from rc_first),
  'LIVENESS (C): the relation under the copy''s name is a new one, not the copy first recorded');
select is(pgpm.regrain_cancel('public.rc'), 1, '(C) regrain_cancel reclaims the one in-flight copy');
select is(to_regclass('public.rc_p0000000000000000000'), null,
  '(C) and the recreated copy is the relation it dropped: none is left behind under the name');

select * from finish();
