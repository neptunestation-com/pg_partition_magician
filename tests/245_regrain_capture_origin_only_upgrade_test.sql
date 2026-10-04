-- Issue #892 (F3-04): a regrain in flight across the upgrade from v0.6.0 gets live capture back.
--
-- THE DEFECT. v0.6.0 minted the capture trigger with CREATE TRIGGER alone, which leaves it origin-only
-- (tgenabled = 'O'): skipped by every session running as session_replication_role = replica (a
-- logical-replication apply worker, a loader silencing triggers). #450 made it ENABLE ALWAYS for regrains
-- prepared after the upgrade, and said in so many words that one already in flight "keeps its origin-only
-- trigger until it swaps". The upgrade's #878 block restarts such a run (it has no source mark) but keeps
-- capture as it was, and regrain_step asked only that the trigger exist. So after the upgrade a replica-role
-- UPDATE and DELETE were never captured, and the swap reverted the one and resurrected the other, although
-- the reference says the trigger is enabled ALWAYS without qualification.
--
-- THE FIX is #892's single rule (see tests/244): capture is live only when its trigger is ENABLE ALWAYS, and a
-- resuming tick that finds it otherwise restarts the run with capture re-minted ENABLE ALWAYS. The upgrade
-- block is left as it is, and needs nothing more: a change capture missed between the upgrade and that tick
-- is in no copy the restart keeps, since the restart discards them all and copies the range again from the
-- source. Part A below makes exactly such a change, and its survival is the proof.
--
-- This file models the upgraded state, as tests/243 does: an UPDATE nulls the source mark (the upgrade's ADD
-- COLUMN leaves it null) and ALTER TABLE ... ENABLE TRIGGER puts capture back to the origin-only state v0.6.0
-- minted. The real upgrade from the released v0.6.0 is bench/upgrade_in_place.sh's in-flight stage, which
-- makes the same replica-role DML after it. Fixture asymmetric: 260 rows; one replica-role UPDATE before the
-- first tick, then one UPDATE and two DELETEs after the restarted run has copied their sub-range again.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(11);

create table public.rgu (id bigint primary key, note text);
insert into public.rgu select g, 'old' || g from generate_series(1, 260) g;
call pgpm.transmute('public.rgu', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
\o /dev/null
select pgpm.obtain('public.rgu');
\o
insert into public.rgu values (450, 'frontier');
select pgpm.set_regrain('public.rgu'::regclass, '50');
\o /dev/null
call pgpm.maintain('public.rgu'); call pgpm.maintain('public.rgu');   -- prepare, copy [0, 50)
\o

create temp table src as select child_oid from pgpm.part
 where parent_table = 'public.rgu'::regclass and attached and lo = '0';
create temp table copy0 as select child_oid from pgpm.part
 where parent_table = 'public.rgu'::regclass and not attached and lo = '0' and hi = '50';
create function pg_temp.src() returns regclass language sql as $f$ select child_oid::regclass from src $f$;

-- the state a v0.6.0 run is in right after the upgrade: no source mark, capture origin-only
update pgpm.config set regrain_source_mark = null where parent_table = 'public.rgu'::regclass;
do $$ begin execute format('alter table %s enable trigger pgpm_regrain_capture', pg_temp.src()); end $$;
create temp table trig0 as select oid as tgoid from pg_trigger
 where tgrelid = pg_temp.src() and tgname = 'pgpm_regrain_capture';

select is((select tgenabled::text from pg_trigger where tgrelid = pg_temp.src() and tgname = 'pgpm_regrain_capture')
          || '/' || (select coalesce(regrain_source_mark::text, 'null') || ' ' || regrain_cursor
                       from pgpm.config where parent_table = 'public.rgu'::regclass)
          || '/' || (select count(*) from copy0 c join pg_class k on k.oid = c.child_oid),
          'O/null 50/1',
          'GUARD: the run is in flight as v0.6.0 left it: capture origin-only, no source mark, [0, 50) copied');

-- Part A: between the upgrade and the first tick, a replica-role UPDATE the origin-only trigger skips
set session_replication_role = replica;
update public.rgu set note = 'new30' where id = 30;
reset session_replication_role;
select is((select note from public.rgu where id = 30), 'new30',
          'LIVENESS: the replica-role UPDATE of id 30 committed while capture was origin-only');

\o /dev/null
call pgpm.maintain('public.rgu');
\o
select is((select array_agg(rows || ' ' || (method like '%no source mark records what the copies were made from%')::text
                            || '/' || (method like '%pgpm_regrain_capture%is origin-only, not ENABLE ALWAYS%')::text
                            order by id)
             from pgpm.log where parent_table = 'public.rgu'::regclass and action = 'regrain_restart'),
          array['1 true/true'],
          'the first tick restarts the run once, naming both the missing mark and the origin-only capture');
select is((select count(*) from copy0 c join pg_class k on k.oid = c.child_oid), 0::bigint,
          'the copy made under origin-only capture is gone, by its oid');
select is((select tgenabled::text || ' ' || (oid in (select tgoid from trig0))::text
             from pg_trigger where tgrelid = pg_temp.src() and tgname = 'pgpm_regrain_capture'),
          'A false', 'capture is re-minted ENABLE ALWAYS: a new trigger on the same source');

\o /dev/null
call pgpm.maintain('public.rgu');   -- the restarted run copies [0, 50) again
\o
select ok(exists (select 1 from pgpm.part where parent_table = 'public.rgu'::regclass
                   and not attached and lo = '0' and hi = '50')
          and (select regrain_cursor from pgpm.config where parent_table = 'public.rgu'::regclass) = '50',
          'LIVENESS: the restarted run has copied [0, 50) again (ids 10, 20 and 21 are in the new copy)');

-- Part B: after the restart, replica-role DML into the copied sub-range is captured like any other
set session_replication_role = replica;
update public.rgu set note = 'new10' where id = 10;
delete from public.rgu where id in (20, 21);
reset session_replication_role;
create function pg_temp.delta_ids() returns text language plpgsql as $f$
declare v_nsp name; v_delta name; r text;
begin
  select nsp, delta into v_nsp, v_delta from pgpm._regrain_capture_names('public.rgu'::regclass);
  execute format('select string_agg(distinct id::text, '','' order by id::text) from %I.%I', v_nsp, v_delta) into r;
  return r;
end $f$;
select is(pg_temp.delta_ids(), '10,20,21',
          'capture recorded the replica-role UPDATE and both DELETEs (keys 10, 20, 21 in the delta)');

do $$ declare v text; begin for i in 1..12 loop call pgpm.maintain('public.rgu', v); end loop; end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rgu'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          'LIVENESS: the run went on to swap [0, 300)');
select is((select string_agg(id || '=' || note, ',' order by id) from public.rgu where id in (9, 10, 19, 30, 260)),
          '9=old9,10=new10,19=old19,30=new30,260=old260',
          'the replica-role UPDATEs of ids 10 and 30 survive the swap, beside untouched neighbours');
select is((select count(*) from public.rgu where id in (20, 21)), 0::bigint,
          'the replica-role DELETEs of ids 20 and 21 are not resurrected');
select is((select count(*) from pgpm.log where parent_table = 'public.rgu'::regclass and action = 'regrain_restart'),
          1::bigint, 'capture ENABLE ALWAYS from the restart on: no second restart');

select * from finish();
