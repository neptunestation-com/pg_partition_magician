-- Issue #878 bullet 2: a regrain run never adopts a source mark over copies it did not make under that mark.
--
-- THE DEFECT. #824 (PR #858) records what a regrain's copies are made FROM in config.regrain_source_mark (the
-- source's relfilenode and its columns' attnums) at the prepare tick, and every resumed tick with copies
-- compares the source with it, so DDL that changes the source's values without changing its column signature
-- (ALTER COLUMN ... TYPE <same type> USING, a column dropped and added back) restarts the run. A run already
-- in flight across the upgrade that added the column has a NULL mark: its prepare tick ran before there was
-- anywhere to record one. _regrain_source_drift answered null for a null mark ("no drift"), and regrain_step's
-- no-drift branch then recorded the source AS IT IS NOW as the mark, blessing copies made before it. A
-- value-changing ALTER between the upgrade and that tick, or before the upgrade, was therefore never seen, and
-- the swap attached the stale copies: the regrained range served the pre-rewrite values, with no
-- regrain_restart anywhere.
--
-- THE FIX, two levers. regrain_step treats a null mark on a run that has copies as drift: nothing records what
-- those copies were made from, so they are discarded and the range copied again (regrain_restart), and only
-- then is a mark recorded, before any copy exists. That lever is what this file proves. The other, the
-- upgrade block in install.sql that restarts such a run at the upgrade itself, is proved by the in-flight
-- stage of bench/upgrade_in_place.sh; this file models the upgraded state with an UPDATE that nulls the mark,
-- which is the state the upgrade's ADD COLUMN leaves, so the upgrade block never runs here.
--
-- Part A is the verifier's reproduction (A878-2), its statements unchanged, with the restart asserted by
-- identity added after it. Part B: a null mark over copies with NO DDL at all still restarts, because nothing
-- shows the copies are current; the restart is not keyed on a rewrite that happened to be visible. Part C is
-- the negative's witness: a null mark on a run with no copies yet is recorded and the run goes on copying,
-- with no restart, since nothing stale exists to discard. Fixtures asymmetric (230, 200 and 170 rows).
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(15);

-- ---------------------------------------------------------------------------- Part A: the reproduction
create table public.rg878 (id bigint primary key, payload text, note text);
insert into public.rg878 select g, 'p' || g, 'old' || g from generate_series(1, 230) g;
call pgpm.transmute('public.rg878', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rg878');
insert into public.rg878 (id, payload) values (450, 'frontier');
select pgpm.set_regrain('public.rg878'::regclass, '50');
call pgpm.maintain('public.rg878'); call pgpm.maintain('public.rg878');   -- prepare, copy [0, 50)

create temp table copy0 as select child_oid from pgpm.part
 where parent_table = 'public.rg878'::regclass and not attached and lo = '0' and hi = '50';

select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg878'::regclass
                   and action = 'regrain_copy' and lo = '0' and hi = '50' and rows = 49)
          and (select regrain_cursor from pgpm.config where parent_table = 'public.rg878'::regclass) = '50'
          and (select count(*) from copy0 c join pg_class k on k.oid = c.child_oid) = 1,
          'LIVENESS: the run is mid-flight: one copy of [0, 50) holds 49 rows and the cursor is at 50');

-- the pre-upgrade state: the run was prepared before regrain_source_mark existed
update pgpm.config set regrain_source_mark = null where parent_table = 'public.rg878'::regclass;
select ok((select regrain_source_mark from pgpm.config where parent_table = 'public.rg878'::regclass) is null,
          'GUARD: the in-flight run carries a null source mark, as one prepared before the upgrade does');

alter table public.rg878 alter column note type text using upper(note);   -- same type: a rewrite only
create temp table want as select id, payload, note from public.rg878 where id < 300;

create function pg_temp.copy_note(p_id bigint) returns text language plpgsql as $f$
declare r text; begin
  execute format('select note from %s where id = $1', (select child_oid::regclass from copy0)) into r using p_id;
  return r;
end $f$;
select ok((select note from want where id = 10) = 'OLD10' and pg_temp.copy_note(10) = 'old10',
          'LIVENESS: the rewrite gave the source OLD10 and the copy made before it still holds old10');

-- The first tick after the "upgrade", on its own, so what it did can be read before the run goes on.
create temp table src878 as
  select child_oid from pgpm.part where parent_table = 'public.rg878'::regclass and attached and lo = '0';
call pgpm.maintain('public.rg878');
select is((select array_agg(rows || ':' || (method like '%no source mark records what the copies were made from%')
                            order by id)
             from pgpm.log where parent_table = 'public.rg878'::regclass and action = 'regrain_restart'),
          array['1:true'],
          'the first tick restarts the run, discarding its one copy, and says the mark was missing');
select ok(not exists (select 1 from copy0 c join pg_class k on k.oid = c.child_oid),
          'the copy made before the rewrite is gone, by its oid');
select is((select regrain_source_mark from pgpm.config where parent_table = 'public.rg878'::regclass),
          (select pgpm._regrain_source_mark(child_oid::regclass) from src878),
          'the restart recorded the mark of the source as rewritten, before any copy of it exists');

do $$ declare v text; begin for i in 1..30 loop call pgpm.maintain('public.rg878', v); end loop; end $$;

select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg878'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          'LIVENESS: the regrain swapped [0, 300)');
select results_eq('select id, payload, note from public.rg878 where id < 300 order by id',
                  'select id, payload, note from want order by id',
                  'the regrained range holds the rewritten values (OLD1 .. OLD230), not the copy''s pre-rewrite ones');

-- ---------------------------------------------------------------------------- Part B: no DDL, still a restart
create table public.rg243b (id bigint primary key, payload text, note text);
insert into public.rg243b select g, 'b' || g, 'old' || g from generate_series(1, 200) g;
call pgpm.transmute('public.rg243b', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rg243b');
insert into public.rg243b (id, payload) values (450, 'frontier');
select pgpm.set_regrain('public.rg243b'::regclass, '50');
call pgpm.maintain('public.rg243b'); call pgpm.maintain('public.rg243b');   -- prepare, copy [0, 50)
create temp table copyb as select child_oid from pgpm.part
 where parent_table = 'public.rg243b'::regclass and not attached and lo = '0' and hi = '50';
update pgpm.config set regrain_source_mark = null where parent_table = 'public.rg243b'::regclass;
select ok((select count(*) from copyb c join pg_class k on k.oid = c.child_oid) = 1
          and (select regrain_cursor from pgpm.config where parent_table = 'public.rg243b'::regclass) = '50'
          and (select regrain_source_mark from pgpm.config where parent_table = 'public.rg243b'::regclass) is null,
          'LIVENESS: rg243b is mid-flight with one copy and a null mark, and its source was never altered');
call pgpm.maintain('public.rg243b');
select is((select array_agg(rows::text order by id) from pgpm.log
            where parent_table = 'public.rg243b'::regclass and action = 'regrain_restart'),
          array['1'],
          'a null mark over a copy restarts the run although no DDL ran: nothing shows the copy is current');
select ok(not exists (select 1 from copyb c join pg_class k on k.oid = c.child_oid),
          'rg243b''s copy made under no mark is gone, by its oid');
do $$ declare v text; begin for i in 1..30 loop call pgpm.maintain('public.rg243b', v); end loop; end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg243b'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300')
          and (select string_agg(id || '=' || note, ',' order by id) from public.rg243b where id in (1, 49, 200))
              = '1=old1,49=old49,200=old200',
          'rg243b swaps [0, 300) after the restart and serves its own rows');

-- ---------------------------------------------------------------------------- Part C: no copies, no restart
create table public.rg243c (id bigint primary key, payload text, note text);
insert into public.rg243c select g, 'c' || g, 'old' || g from generate_series(1, 170) g;
call pgpm.transmute('public.rg243c', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rg243c');
insert into public.rg243c (id, payload) values (450, 'frontier');
select pgpm.set_regrain('public.rg243c'::regclass, '50');
call pgpm.maintain('public.rg243c');   -- prepare only: no copy yet
update pgpm.config set regrain_source_mark = null where parent_table = 'public.rg243c'::regclass;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg243c'::regclass and action = 'regrain_prepare')
          and not exists (select 1 from pgpm.part where parent_table = 'public.rg243c'::regclass and not attached)
          and (select regrain_source_mark from pgpm.config where parent_table = 'public.rg243c'::regclass) is null,
          'LIVENESS: rg243c is prepared with a null mark and no copy');
create temp table srcc as
  select child_oid from pgpm.part where parent_table = 'public.rg243c'::regclass and attached and lo = '0';
call pgpm.maintain('public.rg243c');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg243c'::regclass
                   and action = 'regrain_copy' and lo = '0' and hi = '50' and rows = 49),
          'LIVENESS: the next tick copied [0, 50) of rg243c');
select is((select count(*) from pgpm.log where parent_table = 'public.rg243c'::regclass and action = 'regrain_restart')
          || '/' || ((select regrain_source_mark from pgpm.config where parent_table = 'public.rg243c'::regclass)
                     = (select pgpm._regrain_source_mark(child_oid::regclass) from srcc))::text,
          '0/true',
          'with no copy to judge, the null mark is recorded from the source and the run is not restarted');

select * from finish();
