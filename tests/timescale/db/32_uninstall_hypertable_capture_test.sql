-- uninstall.sql removes from_hypertable's change capture from the operator's schema (issue #737).
--
-- from_hypertable_copy(p_track_changes => true) installs three objects OUTSIDE the pgpm schema, in the
-- hypertable's own: the delta table <rel>_pgpm_delta, its trigger function <rel>_pgpm_delta_fn(), and the
-- row trigger <rel>_pgpm_delta_trg on the LIVE hypertable. The cutover drops all three; a copy that is
-- never cut over (abandoned, or uninstalled mid-window) keeps them. uninstall.sql swept only regrain's
-- change capture, so all three survived `drop schema pgpm cascade` and the trigger went on logging every
-- write of the production table into a delta nothing would ever drain, where docs/guide.md says nothing
-- else pgpm made remains in the schema.
--
-- uninstall now finds each tracking copy by the record the copy keeps on its own delta (the
-- `pgpm from_hypertable horizon <xid>` comment, written in the same transaction as the trigger and the
-- function), never by a name pattern, and drops the function (taking the trigger on the hypertable and on
-- every chunk with it) and the delta.
--
-- The fixture is asymmetric on purpose. Two tracking copies, in two schemas (one schema and table name
-- need quoting), with different window writes (two keys in one delta, one in the other), so a sweep that
-- reaches only one of them, or that misquotes a name, fails on the one it missed. And a THIRD set of
-- objects, made by the operator, that has exactly the module's names (u737_c_pgpm_delta,
-- u737_c_pgpm_delta_fn(), u737_c_pgpm_delta_trg) but no record: a name-pattern sweep would drop it, and it
-- must survive with its trigger still firing. Every "gone" is paired with a witness that it was there and
-- live before.
--
-- Since #985 uninstall drops whatever pgpm.scratch records by that record alone, so the comment sweep this file
-- states is what finds a tracking copy made by a release before the record (it keeps the comment and has no
-- row). "EvB"'s copy is made one: its rows in pgpm.scratch are deleted, as such a release would have left it.
-- u737_a's stays recorded, so the two copies leave by the two paths.
--
-- The uninstall script is read with \ir, relative to this file. bench/uninstall_hypertable_capture.sh runs
-- this file against a mutant uninstall.sql by setting the psql variable `uninstall` to its path.
\if :{?uninstall}
\else
\set uninstall ../../../pgpm_core/uninstall.sql
\endif
select plan(16);

-- ======================================================================================================
-- fixture: two tracking copies not cut over, and the operator's own look-alike
-- ======================================================================================================
create table public.u737_a (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.u737_a', 'ts', chunk_time_interval => interval '1 day');
insert into public.u737_a select g, timestamptz '2026-09-01 00:00+00' + g * interval '7 hours', 'a' || g
  from generate_series(1, 6) g;

create schema "U737";
create table "U737"."EvB" (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('"U737"."EvB"', 'ts', chunk_time_interval => interval '1 day');
insert into "U737"."EvB" select g, timestamptz '2026-09-01 00:00+00' + g * interval '5 hours', 'b' || g
  from generate_series(10, 13) g;

-- the operator's own audit trail, which happens to use the module's names, on a table pgpm never touched
create table public.u737_c (id bigint primary key, v text);
create table public.u737_c_pgpm_delta (id bigint);
comment on table public.u737_c_pgpm_delta is 'audit trail of u737_c, kept by the application';
create function public.u737_c_pgpm_delta_fn() returns trigger language plpgsql as $f$
begin insert into public.u737_c_pgpm_delta values (new.id); return new; end $f$;
create trigger u737_c_pgpm_delta_trg after insert on public.u737_c
  for each row execute function public.u737_c_pgpm_delta_fn();
insert into public.u737_c values (1, 'c1');
-- what the look-alike's delta holds, read dynamically, so a sweep that wrongly drops it fails the assertion
-- below rather than killing the file with a raw "relation does not exist"
create function pg_temp.u737_c_logged() returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  if to_regclass('public.u737_c_pgpm_delta') is null then return null; end if;
  execute 'select array_agg(id order by id) from public.u737_c_pgpm_delta' into v;
  return v;
end $f$;

call pgpm.from_hypertable_copy('public.u737_a', 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('"U737"."EvB"', 'ts', p_track_changes => true);
-- "EvB"'s copy as a release before pgpm.scratch made it: the comment record alone (#985)
delete from pgpm.scratch where parent_oid = '"U737"."EvB"'::regclass::oid;

-- the online window: two keys touched on one, one on the other
update public.u737_a set v = 'a2-upd' where id = 2;
delete from public.u737_a where id = 5;
insert into "U737"."EvB" values (30, timestamptz '2026-09-01 20:00+00', 'b30');

select is(
  (select array_agg(c.relname || '.' || t.tgname order by c.relname) from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
    where t.tgrelid in ('public.u737_a'::regclass, '"U737"."EvB"'::regclass, 'public.u737_c'::regclass)
      and t.tgname in ('u737_a_pgpm_delta_trg', 'EvB_pgpm_delta_trg', 'u737_c_pgpm_delta_trg')),
  array['EvB.EvB_pgpm_delta_trg', 'u737_a.u737_a_pgpm_delta_trg', 'u737_c.u737_c_pgpm_delta_trg'],
  'LIVENESS: each tracking copy put its trigger on its live hypertable, and the operator''s look-alike is on u737_c');
select is((select array_agg(distinct id order by id) from public.u737_a_pgpm_delta), array[2, 5]::bigint[],
  'LIVENESS: u737_a''s capture logged the two keys written in its window');
select is((select array_agg(distinct id order by id) from "U737"."EvB_pgpm_delta"), array[30]::bigint[],
  'LIVENESS: "EvB"''s capture logged the one key written in its window');
select is(pg_temp.u737_c_logged(), array[1]::bigint[],
  'LIVENESS: the operator''s look-alike trigger fires');
select is(
  (select array_agg(c.oid::regclass::text order by c.relname collate "C") from pg_class c
    where c.oid in ('public.u737_a_pgpm_delta'::regclass, '"U737"."EvB_pgpm_delta"'::regclass,
                    'public.u737_c_pgpm_delta'::regclass)
      and obj_description(c.oid, 'pg_class') ~ '^pgpm from_hypertable horizon [0-9]+$'),
  array['"U737"."EvB_pgpm_delta"', 'u737_a_pgpm_delta'],
  'LIVENESS: the two copies'' deltas carry the module''s record and the look-alike does not');
select is(
  (select array_agg(c.relname::text || ':' || s.kind order by s.kind) from pgpm.scratch s join pg_class c on c.oid = s.parent_oid
    where s.parent_oid in ('public.u737_a'::regclass::oid, '"U737"."EvB"'::regclass::oid)),
  array['u737_a:hypertable_delta', 'u737_a:hypertable_delta_fn', 'u737_a:hypertable_dest'],
  'LIVENESS: u737_a''s copy is in pgpm.scratch and "EvB"''s is not, so only the comment sweep can find it');

-- ======================================================================================================
-- the uninstall, in one transaction, as the script says to run it
-- ======================================================================================================
begin;
\ir :uninstall
commit;

select is(to_regnamespace('pgpm'), null, 'LIVENESS: the uninstall went through and removed the pgpm schema');

-- writes after the uninstall: one more row on each copied hypertable, and on the look-alike's table
insert into public.u737_a values (99, timestamptz '2026-09-01 12:30+00', 'after');
insert into "U737"."EvB" values (98, timestamptz '2026-09-01 13:30+00', 'after');
insert into public.u737_c values (7, 'c7');

select is(
  (select coalesce(array_agg(t.tgrelid::regclass::text || ':' || t.tgname order by t.tgname), '{}') from pg_trigger t
    where t.tgname in ('u737_a_pgpm_delta_trg', 'EvB_pgpm_delta_trg')),
  '{}'::text[],
  'no capture trigger of either copy survives, on either hypertable or on any of their chunks');
select is(to_regprocedure('public.u737_a_pgpm_delta_fn()'), null, 'u737_a''s capture function is gone');
select is(to_regprocedure('"U737"."EvB_pgpm_delta_fn"()'), null, '"EvB"''s capture function is gone');
select is(to_regclass('public.u737_a_pgpm_delta'), null, 'u737_a''s delta is gone');
select is(to_regclass('"U737"."EvB_pgpm_delta"'), null, '"EvB"''s delta is gone');

select is((select array_agg(id || ':' || v order by id) from public.u737_a),
  array['1:a1', '2:a2-upd', '3:a3', '4:a4', '6:a6', '99:after'],
  'u737_a keeps every row, the window''s update and delete, and takes a write after the uninstall');
select is((select array_agg(id || ':' || v order by id) from "U737"."EvB"),
  array['10:b10', '11:b11', '12:b12', '13:b13', '30:b30', '98:after'],
  '"EvB" keeps every row, the window''s insert, and takes a write after the uninstall');

select is(
  (select array_agg(x order by x) from unnest(array[
     to_regclass('public.u737_c_pgpm_delta')::text, to_regprocedure('public.u737_c_pgpm_delta_fn()')::text,
     (select tgname::text from pg_trigger where tgrelid = 'public.u737_c'::regclass and tgname = 'u737_c_pgpm_delta_trg')]) x),
  array['u737_c_pgpm_delta', 'u737_c_pgpm_delta_fn()', 'u737_c_pgpm_delta_trg'],
  'the operator''s look-alike (the module''s names, no record) survives whole');
select is(pg_temp.u737_c_logged(), array[1, 7]::bigint[],
  'and its trigger still fires after the uninstall');

select * from finish();
