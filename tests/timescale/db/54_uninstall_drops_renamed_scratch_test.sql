-- uninstall.sql drops a from_hypertable copy's recorded scratch objects by oid, whatever they are called now
-- (issue #985).
--
-- from_hypertable_copy records the copy <rel>_pgpm_dest, and for a tracking copy the delta <rel>_pgpm_delta and
-- the trigger function <rel>_pgpm_delta_fn(), in pgpm.scratch, and also comments each table. uninstall.sql's
-- record sweep took only a recorded object that had LOST its comment and left the rest to the comment sweeps,
-- which also require the _pgpm_delta / _pgpm_dest name suffix. So a copy and delta the operator renamed in the
-- hypertable's schema (which the drains and the cutover still find by oid) matched neither and survived the
-- uninstall, the capture trigger still on the live hypertable and on every chunk, against docs/reference.md
-- ("uninstall.sql find[s] them here, by oid, never by name") and guide.md ("Nothing else pgpm made remains in
-- your schema"). tests/282 states the same contract in the core suite, on plain tables.
--
-- ASYMMETRIC FIXTURE:
--   A  public.u985_a, a 2-chunk hypertable of 40 rows with a TRACKING copy never cut over, its copy, delta and
--      function then renamed: all three go, and the trigger from the hypertable and from every chunk
--   B  public.u985_b, a hypertable of 3 rows with an APPEND-ONLY copy never cut over, its copy renamed: it goes
--   C  public.u985_a_pgpm_dest, the operator's own table under the name A's copy gave up, no record: survives
-- Every "gone" is paired with a witness that it was there, every survivor with a witness that the sweep ran.
--
-- The uninstall script is read with \ir, relative to this file. bench/uninstall_hypertable_scratch_by_record.sh
-- runs this file against a mutant uninstall.sql by setting the psql variable `uninstall` to its path.
\if :{?uninstall}
\else
\set uninstall ../../../pgpm_core/uninstall.sql
\endif
select plan(15);

-- ======================================================================================================
-- fixture
-- ======================================================================================================
create table public.u985_a (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.u985_a', 'ts', chunk_time_interval => interval '1 day');
insert into public.u985_a select timestamptz '2024-01-01 00:00+00' + g * interval '1 hour', g, g
  from generate_series(1, 40) g;
call pgpm.from_hypertable_copy('public.u985_a', 'ts', p_track_changes => true);
update public.u985_a set v = 400 where id = 4;                             -- captured while the trigger is live

create table public.u985_b (ts timestamptz not null, v int);
select create_hypertable('public.u985_b', 'ts', chunk_time_interval => interval '1 day');
insert into public.u985_b values ('2025-03-01 00:00+00', 31), ('2025-03-02 00:00+00', 32), ('2025-03-03 00:00+00', 33);
call pgpm.from_hypertable_copy('public.u985_b', 'ts');

select s.obj as a_dest from pgpm.scratch s where s.parent_oid = 'public.u985_a'::regclass::oid and s.kind = 'hypertable_dest' \gset
select s.obj as a_delta from pgpm.scratch s where s.parent_oid = 'public.u985_a'::regclass::oid and s.kind = 'hypertable_delta' \gset
select s.obj as a_fn from pgpm.scratch s where s.parent_oid = 'public.u985_a'::regclass::oid and s.kind = 'hypertable_delta_fn' \gset
select s.obj as b_dest from pgpm.scratch s where s.parent_oid = 'public.u985_b'::regclass::oid and s.kind = 'hypertable_dest' \gset

select is((select array_agg(id order by id) from public.u985_a_pgpm_delta), array[4, 4]::bigint[],
  'LIVENESS: A''s capture trigger was live and logged the update of id 4 (old and new)');

-- the operator renames pgpm's scratch objects (the comments and the records stay with them, the names do not)
alter table public.u985_a_pgpm_dest rename to u985_a_backup;
alter table public.u985_a_pgpm_delta rename to u985_a_changes;
alter function public.u985_a_pgpm_delta_fn() rename to u985_a_capture;
alter table public.u985_b_pgpm_dest rename to u985_b_backup;

-- C: the operator's own table, under the name A's copy gave up
create table public.u985_a_pgpm_dest (id int, note text);
insert into public.u985_a_pgpm_dest values (7, 'mine');

-- what a survivor holds, read dynamically, so a sweep that wrongly drops it fails its assertion below rather
-- than killing the file with a raw "relation does not exist"
create function pg_temp.u985_rows(p_rel text, p_expr text) returns text[] language plpgsql as $f$
declare v text[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select array_agg((%1$s)::text order by (%1$s)::text) from %2$s', p_expr, p_rel) into v;
  return v;
end $f$;

-- ======================================================================================================
-- liveness
-- ======================================================================================================
select is(
  (select array_agg(c.oid::regclass::text || '=' || coalesce(obj_description(c.oid, 'pg_class'), '-')
                    order by c.oid::regclass::text collate "C")
     from pg_class c where c.oid in (:'a_dest'::oid, :'a_delta'::oid, :'b_dest'::oid)),
  array['u985_a_backup=pgpm from_hypertable copy of ' || 'public.u985_a'::regclass::oid,
        'u985_a_changes=' || obj_description(:'a_delta'::oid, 'pg_class'),
        'u985_b_backup=pgpm from_hypertable copy of ' || 'public.u985_b'::regclass::oid],
  'LIVENESS: pgpm.scratch records each renamed copy and delta by oid, and each still carries the copy''s comment');
select matches(obj_description(:'a_delta'::oid, 'pg_class'), '^pgpm from_hypertable horizon [0-9]+$',
  'LIVENESS: the renamed delta''s comment is the copy''s horizon record');
select is((select p.oid::regprocedure::text from pg_proc p where p.oid = :'a_fn'::oid), 'u985_a_capture()',
  'LIVENESS: pgpm.scratch records the renamed capture function by oid');
select cmp_ok((select count(*)::int from pg_trigger where tgfoid = :'a_fn'::oid
                 and tgrelid in (select c.oid from pg_class c join pg_inherits i on i.inhrelid = c.oid
                                  where i.inhparent = 'public.u985_a'::regclass)), '>=', 2,
  'LIVENESS: the capture trigger is on at least two of the hypertable''s chunks');
select is((select count(*)::int from pg_trigger where tgfoid = :'a_fn'::oid and tgrelid = 'public.u985_a'::regclass), 1,
  'LIVENESS: the capture trigger is on the hypertable itself');

-- ======================================================================================================
-- the uninstall, in one transaction, as the script says to run it
-- ======================================================================================================
begin;
\ir :uninstall
commit;

select is(to_regnamespace('pgpm'), null, 'LIVENESS: the uninstall went through and removed the pgpm schema');

-- A
select is((select count(*)::int from pg_trigger where tgfoid = :'a_fn'::oid), 0,
  'A: the capture trigger is gone from the hypertable and from every chunk');
select is((select count(*)::int from pg_proc where oid = :'a_fn'::oid), 0, 'A: the recorded function u985_a_capture() is gone');
select is((select count(*)::int from pg_class where oid = :'a_delta'::oid), 0, 'A: the recorded delta u985_a_changes is gone');
select is((select count(*)::int from pg_class where oid = :'a_dest'::oid), 0, 'A: the recorded copy u985_a_backup is gone');
select lives_ok('insert into public.u985_a values (timestamptz ''2024-01-01 00:00+00'', 41, 41)',
  'A: the hypertable takes a write after the uninstall');
select is((select array_agg(id order by id) from public.u985_a),
  (select array_agg(g::bigint order by g) from generate_series(1, 41) g),
  'A: the hypertable keeps its 40 rows and the new one');

-- B
select is((select count(*)::int from pg_class where oid = :'b_dest'::oid), 0, 'B: the recorded copy u985_b_backup is gone');

-- C
select is(pg_temp.u985_rows('public.u985_a_pgpm_dest', $$id || ':' || note$$), array['7:mine'],
  'C: the operator''s table under the copy''s old name survives with its row');

select * from finish();
