-- uninstall.sql removes a from_hypertable copy that was never cut over (issue #773, last bullet).
--
-- from_hypertable_copy builds <rel>_pgpm_dest in the HYPERTABLE's schema: a full second copy of its rows,
-- holding the outgoing foreign keys the copy replayed on it and, for a tracking copy, the pre-built key index
-- <conname>_pgpm_new. The cutover renames it into the hypertable's place; a copy never cut over keeps it.
-- uninstall.sql (#737) swept the tracking copy's delta, function and trigger but left the copy itself, so a
-- full second table of the hypertable survived where its header and docs/guide.md say nothing else pgpm made
-- remains, and its replayed foreign key kept a referenced row the hypertable no longer uses from being
-- deleted.
--
-- uninstall now finds each copy by the record the copy keeps on it (the `pgpm from_hypertable copy of <oid>`
-- comment, written in the transaction that creates it and replaced by the swap), never by its name, and
-- drops it while the hypertable it names still exists (that hypertable holds every row). A copy whose
-- hypertable is gone may be the only home of those rows, so it is left, with a WARNING.
--
-- ASYMMETRIC FIXTURE, five tables that each fail a different wrong sweep:
--   A  public.u773_a, a TRACKING copy of 40 rows, never cut over: its dest and its key index must go
--   B  "U773"."EvB", an APPEND-ONLY copy of 2 rows with an outgoing foreign key to u773_ref, never cut over,
--      in a schema and under a name that need quoting: its dest must go, and with it the replayed key
--   C  public.u773_c_pgpm_dest, the operator's own table with the module's name and no record: must survive
--   D  public.u773_d, an append-only copy of 3 rows whose hypertable the operator then dropped: its dest has
--      the record but no hypertable holding its rows, so it must survive
--   E  public.u773_e, a completed from_hypertable (no comment of its own): the migrated table must carry no
--      record, and must survive with its rows
-- Every "gone" is paired with a witness that it was there before, and every survivor with a witness that
-- the sweep ran.
--
-- Since #985 uninstall drops whatever pgpm.scratch records by that record alone, so the comment sweep this file
-- states is what finds a copy made by a release before the record (it keeps the comment and has no row). B's
-- and D's copies are made such copies: their rows in pgpm.scratch are deleted, as such a release would have
-- left them. A's stays recorded, so the copies leave by both paths.
--
-- The uninstall script is read with \ir, relative to this file. bench/uninstall_hypertable_copy.sh runs this
-- file against a mutant uninstall.sql by setting the psql variable `uninstall` to its path.
\if :{?uninstall}
\else
\set uninstall ../../../pgpm_core/uninstall.sql
\endif
select plan(23);

-- ======================================================================================================
-- fixture
-- ======================================================================================================
create table public.u773_ref (id int primary key);
insert into public.u773_ref values (1), (2), (3);

-- A: a tracking copy of a 2-chunk hypertable, never cut over
create table public.u773_a (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.u773_a', 'ts', chunk_time_interval => interval '1 day');
insert into public.u773_a select timestamptz '2024-01-01 00:00+00' + g * interval '1 hour', g, g
  from generate_series(1, 40) g;
call pgpm.from_hypertable_copy('public.u773_a', 'ts', p_track_changes => true);

-- B: an append-only copy with an outgoing foreign key, never cut over
create schema "U773";
create table "U773"."EvB" (ts timestamptz not null, ref_id int not null references public.u773_ref (id), v int);
select create_hypertable('"U773"."EvB"', 'ts', chunk_time_interval => interval '1 day');
insert into "U773"."EvB" values ('2026-01-01 00:00+00', 1, 10), ('2026-01-02 00:00+00', 2, 20);
call pgpm.from_hypertable_copy('"U773"."EvB"', 'ts');
delete from pgpm.scratch where parent_oid = '"U773"."EvB"'::regclass::oid;   -- a pre-record copy (#985)

-- C: the operator's own table, with the module's name and a comment that is not the module's record
create table public.u773_c (id int primary key);
create table public.u773_c_pgpm_dest (id int, note text);
comment on table public.u773_c_pgpm_dest is 'staging copy of u773_c, kept by the application';
insert into public.u773_c_pgpm_dest values (7, 'kept'), (8, 'kept too');

-- D: an append-only copy whose hypertable is dropped afterwards
create table public.u773_d (ts timestamptz not null, v int);
select create_hypertable('public.u773_d', 'ts', chunk_time_interval => interval '1 day');
insert into public.u773_d values ('2025-03-01 00:00+00', 31), ('2025-03-02 00:00+00', 32), ('2025-03-03 00:00+00', 33);
call pgpm.from_hypertable_copy('public.u773_d', 'ts');
select oid as d_oid from pg_class where oid = 'public.u773_d'::regclass \gset
delete from pgpm.scratch where parent_oid = :'d_oid'::oid;                      -- a pre-record copy (#985)
drop table public.u773_d;

-- E: a completed migration
create table public.u773_e (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.u773_e', 'ts', chunk_time_interval => interval '1 day');
insert into public.u773_e values ('2024-02-01 00:00+00', 51, 1), ('2024-02-02 00:00+00', 52, 2),
                                 ('2024-02-03 00:00+00', 53, 3), ('2024-02-04 00:00+00', 54, 4);
call pgpm.from_hypertable('public.u773_e', 'ts', interval '1 day', p_paused => true);

-- the operator abandons B's migration: the row that used ref 2 goes from the hypertable
delete from "U773"."EvB" where ref_id = 2;

-- what a survivor holds, read dynamically, so a sweep that wrongly drops it fails the assertion below rather
-- than killing the file with a raw "relation does not exist"
create function pg_temp.u773_rows(p_rel text, p_expr text) returns text[] language plpgsql as $f$
declare v text[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg((%1$s)::text order by (%1$s)::text) from %2$s', p_expr, p_rel) into v;
  return v;
end $f$;

-- ======================================================================================================
-- liveness: every copy is there, holding its rows, and carrying the record that names its hypertable
-- ======================================================================================================
select is((select array_agg(v order by v) from public.u773_a_pgpm_dest),
  (select array_agg(g::int order by g) from generate_series(1, 40) g),
  'LIVENESS: A''s copy holds the hypertable''s 40 rows');
select is((select i.indrelid::regclass::text from pg_index i where i.indexrelid = to_regclass('public.u773_a_pkey_pgpm_new')),
  'u773_a_pgpm_dest', 'LIVENESS: A''s tracking copy pre-built its key index u773_a_pkey_pgpm_new on its copy');
select is((select array_agg(v order by v) from "U773"."EvB_pgpm_dest"), array[10, 20],
  'LIVENESS: B''s copy holds both rows, the one the hypertable has since lost included');
select throws_ok('delete from public.u773_ref where id = 2', '23503', null,
  'LIVENESS: B''s copy carries the replayed foreign key, which keeps u773_ref 2 from being deleted');
select is(
  (select array_agg(c.oid::regclass::text || '=' || coalesce(obj_description(c.oid, 'pg_class'), '-')
                    order by c.relname collate "C")
     from pg_class c
    where c.oid in ('public.u773_a_pgpm_dest'::regclass, '"U773"."EvB_pgpm_dest"'::regclass,
                    'public.u773_c_pgpm_dest'::regclass, 'public.u773_d_pgpm_dest'::regclass)),
  array['"U773"."EvB_pgpm_dest"=pgpm from_hypertable copy of ' || '"U773"."EvB"'::regclass::oid,
        'u773_a_pgpm_dest=pgpm from_hypertable copy of ' || 'public.u773_a'::regclass::oid,
        'u773_c_pgpm_dest=staging copy of u773_c, kept by the application',
        'u773_d_pgpm_dest=pgpm from_hypertable copy of ' || :'d_oid'],
  'LIVENESS: each copy carries the module''s record naming its hypertable, and the look-alike does not');
select is((select count(*)::int from pg_class where oid = :'d_oid'::oid), 0,
  'LIVENESS: D''s hypertable is gone, so its copy is the only home of its rows');
select is(
  (select c.relkind::text || ' ' || coalesce(obj_description(c.oid, 'pg_class'), 'no comment')
     from pg_class c where c.oid = 'public.u773_e'::regclass),
  'p no comment',
  'E was migrated, and the swap left the migrated table no record of the copy it was');
select is(to_regclass('public.u773_e_pgpm_dest'), null, 'LIVENESS: E''s copy is the migrated table, nothing under the copy''s name');
select is(
  (select array_agg(s.obj::regclass::text || ':' || s.kind order by s.kind) from pgpm.scratch s
    where s.obj in ('public.u773_a_pgpm_dest'::regclass::oid, '"U773"."EvB_pgpm_dest"'::regclass::oid,
                    'public.u773_d_pgpm_dest'::regclass::oid)),
  array['u773_a_pgpm_dest:hypertable_dest'],
  'LIVENESS: A''s copy is in pgpm.scratch and B''s and D''s are not, so only the comment sweep can find them');

-- ======================================================================================================
-- the uninstall, in one transaction, as the script says to run it
-- ======================================================================================================
begin;
\ir :uninstall
commit;

select is(to_regnamespace('pgpm'), null, 'LIVENESS: the uninstall went through and removed the pgpm schema');

-- A
select is(to_regclass('public.u773_a_pgpm_dest'), null, 'A''s abandoned copy is gone');
select is(to_regclass('public.u773_a_pkey_pgpm_new'), null, 'A''s pre-built key index is gone with it');
select is(to_regclass('public.u773_a_pgpm_delta'), null, 'LIVENESS: A''s change capture went too (#737)');
select is((select array_agg(v order by v) from public.u773_a),
  (select array_agg(g::int order by g) from generate_series(1, 40) g),
  'A''s hypertable keeps all 40 rows');

-- B
select is(to_regclass('"U773"."EvB_pgpm_dest"'), null, 'B''s abandoned copy is gone');
select is((select array_agg(v order by v) from "U773"."EvB"), array[10], 'B''s hypertable keeps its one row');
select lives_ok('delete from public.u773_ref where id = 2',
  'u773_ref 2, referenced by nothing of the operator''s, can be deleted after the uninstall');
select is((select array_agg(id order by id) from public.u773_ref), array[1, 3],
  'the delete took u773_ref 2 and only it: 1, which B''s hypertable still references, is still there');

-- C
select is(pg_temp.u773_rows('public.u773_c_pgpm_dest', $$id || ':' || note$$), array['7:kept', '8:kept too'],
  'the operator''s look-alike (the module''s name, no record) survives with its rows');

-- D
select is(pg_temp.u773_rows('public.u773_d_pgpm_dest', 'v'), array['31', '32', '33'],
  'D''s copy, whose hypertable is gone, is left with its rows');

-- E
select is((select relkind::text from pg_class where oid = to_regclass('public.u773_e')), 'p',
  'E, the migrated table, is still a partitioned table');
select is(pg_temp.u773_rows('public.u773_e', 'id'), array['51', '52', '53', '54'],
  'E keeps every row');
select is(obj_description(to_regclass('public.u773_e'), 'pg_class'), null,
  'E still carries no record after the uninstall');

select * from finish();
