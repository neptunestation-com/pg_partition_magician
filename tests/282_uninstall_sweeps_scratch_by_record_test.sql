-- uninstall.sql drops what pgpm.scratch records by its oid, whatever it is called now (issue #985).
--
-- pgpm.scratch is the record of the scratch objects from_hypertable_copy leaves beside a hypertable: the copy
-- <rel>_pgpm_dest, and for a tracking copy the delta <rel>_pgpm_delta and the trigger function
-- <rel>_pgpm_delta_fn() whose row trigger fires on the live table. docs/reference.md promises that
-- uninstall.sql finds them there, by oid, never by name. Its record sweep took only a recorded object that had
-- LOST the comment the copy also puts on it, and left every commented one to the comment sweeps, which also
-- require the _pgpm_delta / _pgpm_dest name suffix. A recorded copy or delta the operator renamed kept both its
-- comment and its record, matched neither, and survived the uninstall with its capture function, and the
-- trigger stayed on the live table, while the schema drop took the record that named them.
--
-- The record is core's (pgpm.scratch, pgpm._scratch_record), and so is the script, so the fixture builds what
-- from_hypertable_copy records on plain tables, in the core suite, where no TimescaleDB is needed:
-- tests/timescale/db/54 runs the same contract through a real from_hypertable_copy.
--
-- ASYMMETRIC FIXTURE:
--   A  u282.events (3 rows), with a recorded copy, delta and capture function, each still carrying the copy's
--      comment, then RENAMED (the copy also moved to schema u282_aside): all three and the trigger must go,
--      the table must keep its rows and take a write
--   B  u282.gone, a recorded copy holding 2 rows, renamed, whose table the operator then dropped: the copy may
--      be the only home of those rows, so it must survive
--   C  u282.events_pgpm_dest, the operator's own table created under the name A's copy gave up, with no
--      record: must survive with its 1 row
-- Every "gone" is paired with a witness that it was there, and every survivor with a witness that the sweep ran.
--
-- The uninstall script is read with \ir, relative to this file. bench/uninstall_scratch_by_record.sh runs this
-- file against a mutant uninstall.sql by setting the psql variable `uninstall` to its path.
\if :{?uninstall}
\else
\set uninstall ../pgpm_core/uninstall.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(16);

create schema u282;
create schema u282_aside;

-- ======================================================================================================
-- A: a tracking copy's three recorded objects, as from_hypertable_copy builds and records them
-- ======================================================================================================
create table u282.events (id bigint primary key, v text);
insert into u282.events values (1, 'a'), (2, 'b'), (3, 'c');
create table u282.events_pgpm_delta (id bigint, pgpm_seq bigint generated always as identity);
select pgpm._scratch_record('u282.events', 'hypertable_delta', 'u282.events_pgpm_delta'::regclass::oid);
create function u282.events_pgpm_delta_fn() returns trigger language plpgsql as $f$
begin
  if tg_op = 'DELETE' then insert into u282.events_pgpm_delta (id) values (old.id); return old; end if;
  insert into u282.events_pgpm_delta (id) values (new.id); return new;
end $f$;
select pgpm._scratch_record('u282.events', 'hypertable_delta_fn', 'u282.events_pgpm_delta_fn()'::regprocedure::oid);
create trigger events_pgpm_delta_trg after insert or update or delete on u282.events
  for each row execute function u282.events_pgpm_delta_fn();
comment on table u282.events_pgpm_delta is 'pgpm from_hypertable horizon 1234';
create table u282.events_pgpm_dest (like u282.events);
insert into u282.events_pgpm_dest select * from u282.events;
select pgpm._scratch_record('u282.events', 'hypertable_dest', 'u282.events_pgpm_dest'::regclass::oid);
select format('comment on table u282.events_pgpm_dest is %L',
              'pgpm from_hypertable copy of ' || 'u282.events'::regclass::oid) \gexec

insert into u282.events values (4, 'd');                                   -- captured while the trigger is live

select s.obj as a_dest from pgpm.scratch s where s.parent_oid = 'u282.events'::regclass::oid and s.kind = 'hypertable_dest' \gset
select s.obj as a_delta from pgpm.scratch s where s.parent_oid = 'u282.events'::regclass::oid and s.kind = 'hypertable_delta' \gset
select s.obj as a_fn from pgpm.scratch s where s.parent_oid = 'u282.events'::regclass::oid and s.kind = 'hypertable_delta_fn' \gset

-- the operator renames all three (the comment and the record stay with them, the names do not)
alter table u282.events_pgpm_dest rename to events_backup;
alter table u282.events_backup set schema u282_aside;
alter table u282.events_pgpm_delta rename to events_changes;
alter function u282.events_pgpm_delta_fn() rename to events_capture;

-- ======================================================================================================
-- B: a recorded copy, renamed, whose table is then dropped
-- ======================================================================================================
create table u282.gone (id bigint primary key, v text);
insert into u282.gone values (21, 'kept'), (22, 'kept too');
create table u282.gone_pgpm_dest (like u282.gone);
insert into u282.gone_pgpm_dest select * from u282.gone;
select pgpm._scratch_record('u282.gone', 'hypertable_dest', 'u282.gone_pgpm_dest'::regclass::oid);
select format('comment on table u282.gone_pgpm_dest is %L', 'pgpm from_hypertable copy of ' || 'u282.gone'::regclass::oid) \gexec
select 'u282.gone'::regclass::oid as b_parent \gset
alter table u282.gone_pgpm_dest rename to gone_rows;
drop table u282.gone;

-- ======================================================================================================
-- C: the operator's own table, under the name A's copy gave up, with no record
-- ======================================================================================================
create table u282.events_pgpm_dest (id bigint, note text);
insert into u282.events_pgpm_dest values (7, 'mine');

-- what a survivor holds, read dynamically, so a sweep that wrongly drops it fails its assertion below rather
-- than killing the file with a raw "relation does not exist"
create function pg_temp.u282_rows(p_rel text, p_expr text) returns text[] language plpgsql as $f$
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
  (select array_agg(s.kind || '=' || coalesce(c.oid::regclass::text, p.oid::regprocedure::text) order by s.kind)
     from pgpm.scratch s left join pg_class c on c.oid = s.obj and s.kind <> 'hypertable_delta_fn'
                         left join pg_proc p on p.oid = s.obj and s.kind = 'hypertable_delta_fn'
    where s.parent_oid = 'u282.events'::regclass::oid),
  array['hypertable_delta=u282.events_changes', 'hypertable_delta_fn=u282.events_capture()',
        'hypertable_dest=u282_aside.events_backup'],
  'LIVENESS: pgpm.scratch records A''s copy, delta and function by oid, under the names they have now');
select is(
  (select array_agg(c.oid::regclass::text || '=' || coalesce(obj_description(c.oid, 'pg_class'), '-')
                    order by c.oid::regclass::text collate "C")
     from pg_class c where c.oid in (:'a_dest'::oid, :'a_delta'::oid)),
  array['u282.events_changes=pgpm from_hypertable horizon 1234',
        'u282_aside.events_backup=pgpm from_hypertable copy of ' || 'u282.events'::regclass::oid],
  'LIVENESS: both renamed relations still carry the copy''s comment');
select is((select array_agg(id order by id) from u282.events_changes), array[4]::bigint[],
  'LIVENESS: the capture trigger was live on u282.events and logged the write of id 4');
select is((select array_agg(t.tgname::text) from pg_trigger t where t.tgrelid = 'u282.events'::regclass and t.tgfoid = :'a_fn'::oid),
  array['events_pgpm_delta_trg'], 'LIVENESS: the capture trigger is on u282.events before the uninstall');
select is(
  (select s.kind || '=' || s.obj::regclass::text from pgpm.scratch s where s.parent_oid = :'b_parent'::oid),
  'hypertable_dest=u282.gone_rows',
  'LIVENESS: B''s renamed copy is recorded, and its table is gone, so it is the only home of its rows');

-- ======================================================================================================
-- the uninstall, in one transaction, as the script says to run it
-- ======================================================================================================
begin;
\ir :uninstall
commit;

select is(to_regnamespace('pgpm'), null, 'LIVENESS: the uninstall went through and removed the pgpm schema');

-- A
select is((select count(*)::int from pg_trigger where tgrelid = 'u282.events'::regclass and tgfoid = :'a_fn'::oid), 0,
  'A: the capture trigger is gone from u282.events');
select is((select count(*)::int from pg_proc where oid = :'a_fn'::oid), 0,
  'A: the recorded capture function, renamed events_capture(), is gone');
select is((select count(*)::int from pg_class where oid = :'a_delta'::oid), 0,
  'A: the recorded delta, renamed events_changes, is gone');
select is((select count(*)::int from pg_class where oid = :'a_dest'::oid), 0,
  'A: the recorded copy, renamed and moved to u282_aside.events_backup, is gone');
select lives_ok('insert into u282.events values (5, ''e'')', 'A: u282.events takes a write after the uninstall');
select is((select array_agg(id order by id) from u282.events), array[1, 2, 3, 4, 5]::bigint[],
  'A: u282.events keeps every row');

-- B
select is(pg_temp.u282_rows('u282.gone_rows', $$id || ':' || v$$), array['21:kept', '22:kept too'],
  'B: the copy whose table is gone survives with its 2 rows');

-- C
select is(pg_temp.u282_rows('u282.events_pgpm_dest', $$id || ':' || note$$), array['7:mine'],
  'C: the operator''s table under the copy''s old name survives with its row');
select is(to_regclass('u282.events_changes'), null, 'A: nothing is left under the delta''s new name');
select is(to_regclass('u282_aside.events_backup'), null, 'A: nothing is left under the copy''s new name');

select * from finish();

drop schema u282 cascade;
drop schema u282_aside cascade;
