-- Issue #892 (F3-01): regrain's change capture counts only while its trigger is ENABLE ALWAYS.
--
-- THE DEFECT. regrain_step resumed a run whenever the source carried a trigger NAMED pgpm_regrain_capture
-- (_regrain_capture_active asks only that it exists), never whether it fires. An owner's bulk-load idiom on
-- the regraining partition, ALTER TABLE <partition> DISABLE TRIGGER USER ... ENABLE TRIGGER USER, disables
-- it and then leaves it origin-only ('O', not the 'A' pgpm installed), and ALTER TABLE <parent> DISABLE
-- TRIGGER USER reaches it the same way. Every change made while it was off (or, origin-only, every change a
-- session_replication_role = replica writer made) never reached the delta, the run carried on from copies
-- that missed them, and the swap attached those copies: an UPDATE in an already-copied sub-range reverted, a
-- DELETE resurrected. The sibling write block has treated a trigger that is not ENABLE ALWAYS as no block
-- since #651; capture had no such rule.
--
-- THE FIX. Capture is live only when the trigger exists AND is ENABLE ALWAYS (_regrain_capture_unarmed).
-- A resuming tick that finds it in any other state restarts the run as capture drift does: the copies are
-- discarded, capture is re-minted ENABLE ALWAYS, and the range is copied again from the source, which holds
-- every committed change. And the swap asks again once its DETACH holds ACCESS EXCLUSIVE on the source, so a
-- trigger disabled between that tick's check and its swap rolls the swap back instead of dropping the source.
--
-- Part A is the finder's reproduction (repro.sql), its statements unchanged, with the restart asserted by
-- identity. Part B is the negative's witness: a run whose trigger stays ENABLE ALWAYS throughout is not
-- restarted, and capture carries its mid-regrain changes through the swap, so the restart in Part A is keyed
-- on the trigger's state and not on any DML. Part C is the swap's own check: an event trigger stands in for
-- an operator disabling capture concurrently, at the one instant a single session cannot otherwise reach
-- (after the swap tick's start-of-tick check, under the DETACH's lock). Fixtures asymmetric: 200, 200, 170
-- and 230 rows, and each part's DML mixes UPDATEs and DELETEs on different rows so a lost update and a
-- resurrected delete cannot cancel.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(25);

-- ---------------------------------------------------------------------------- Part A: the reproduction
create function pg_temp.mk(p_rel text) returns void language plpgsql as $f$
begin
  execute format('create table public.%I (id bigint primary key, note text)', p_rel);
  execute format('insert into public.%I select g, ''old'' || g from generate_series(1, 200) g', p_rel);
end $f$;
select pg_temp.mk('rga'); select pg_temp.mk('rgb');
call pgpm.transmute('public.rga', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
call pgpm.transmute('public.rgb', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rga'), pgpm.obtain('public.rgb');
insert into public.rga values (450, 'frontier'); insert into public.rgb values (450, 'frontier');
select pgpm.set_regrain('public.rga', '50'), pgpm.set_regrain('public.rgb', '50');
\o /dev/null
call pgpm.maintain('public.rga'); call pgpm.maintain('public.rga');   -- prepare, copy [0, 50)
call pgpm.maintain('public.rgb'); call pgpm.maintain('public.rgb');
\o

select ok(exists (select 1 from pgpm.log where parent_table = 'public.rga'::regclass and action = 'regrain_copy'
                   and lo = '0' and hi = '50' and rows = 49),
          'LIVENESS: (A) rga''s first sub-range [0, 50) was copied before the DML (ids 10 and 20 are in the copy)');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rgb'::regclass and action = 'regrain_copy'
                   and lo = '0' and hi = '50' and rows = 49),
          'LIVENESS: (B) rgb''s first sub-range [0, 50) was copied before the DML');

-- what the restart must discard and what it must re-arm, by oid, taken before the operator's DDL
create temp table copy_a as select parent_table, child_oid from pgpm.part
 where parent_table in ('public.rga'::regclass, 'public.rgb'::regclass) and not attached and lo = '0' and hi = '50';
create temp table trig_a as select tgrelid, oid as tgoid from pg_trigger
 where tgname = 'pgpm_regrain_capture'
   and tgrelid in ('public.rga_p0000000000000000000_to_0000000000000000300'::regclass,
                   'public.rgb_p0000000000000000000_to_0000000000000000300'::regclass);

-- the operator's bulk edit, on the partition holding the rows
alter table public.rga_p0000000000000000000_to_0000000000000000300 disable trigger user;
alter table public.rgb_p0000000000000000000_to_0000000000000000300 disable trigger user;
update public.rga set note = 'new10' where id = 10;  delete from public.rga where id = 20;
update public.rgb set note = 'new11' where id = 11;  delete from public.rgb where id = 21;
alter table public.rgb_p0000000000000000000_to_0000000000000000300 enable trigger user;

select is((select tgenabled::text from pg_trigger where tgname = 'pgpm_regrain_capture'
            and tgrelid = 'public.rga_p0000000000000000000_to_0000000000000000300'::regclass), 'D',
          'LIVENESS: (A) rga''s capture trigger is present and disabled when the next tick runs');
select is((select tgenabled::text from pg_trigger where tgname = 'pgpm_regrain_capture'
            and tgrelid = 'public.rgb_p0000000000000000000_to_0000000000000000300'::regclass), 'O',
          'LIVENESS: (B) rgb''s capture trigger is present and origin-only (not ENABLE ALWAYS) when the next tick runs');
select ok((select note from public.rga where id = 10) = 'new10' and not exists (select 1 from public.rga where id = 20),
          'LIVENESS: (A) the UPDATE and the DELETE committed on rga before the swap');
select ok((select note from public.rgb where id = 11) = 'new11' and not exists (select 1 from public.rgb where id = 21),
          'LIVENESS: (B) the UPDATE and the DELETE committed on rgb before the swap');
select is((select count(*) from copy_a c join pg_class k on k.oid = c.child_oid), 2::bigint,
          'LIVENESS: both copies of [0, 50) made before the DML exist when the next tick runs');

-- the first tick after the DDL, on its own, so what it did can be read before the run goes on
\o /dev/null
call pgpm.maintain('public.rga'); call pgpm.maintain('public.rgb');
\o

select is((select array_agg(parent_table::text || ' ' || lo || '/' || hi || ' rows=' || rows || ' '
                            || (method like '%pgpm_regrain_capture%is disabled, not ENABLE ALWAYS%')::text
                            || '/' || (method like '%pgpm_regrain_capture%is origin-only, not ENABLE ALWAYS%')::text
                            order by parent_table::text)
             from pgpm.log where parent_table in ('public.rga'::regclass, 'public.rgb'::regclass)
              and action = 'regrain_restart'),
          array['rga 0/300 rows=1 true/false', 'rgb 0/300 rows=1 false/true'],
          'each run restarted once, discarding its one copy, naming the state its capture trigger was in');
select is((select count(*) from copy_a c join pg_class k on k.oid = c.child_oid), 0::bigint,
          'both copies made while capture was off are gone, by their oids');
select is((select array_agg(t.tgrelid::regclass::text || '=' || t.tgenabled::text
                            || (t.oid = any (select tgoid from trig_a))::text order by t.tgrelid::regclass::text)
             from pg_trigger t
            where t.tgname = 'pgpm_regrain_capture' and t.tgrelid in (select tgrelid from trig_a)),
          array['rga_p0000000000000000000_to_0000000000000000300=Afalse',
                'rgb_p0000000000000000000_to_0000000000000000300=Afalse'],
          'the restart re-minted each source''s capture trigger, ENABLE ALWAYS (a new trigger, not the disabled one)');

\o /dev/null
call pgpm.maintain('public.rga'); call pgpm.maintain('public.rga'); call pgpm.maintain('public.rga');
call pgpm.maintain('public.rga'); call pgpm.maintain('public.rga'); call pgpm.maintain('public.rga');
call pgpm.maintain('public.rga'); call pgpm.maintain('public.rga'); call pgpm.maintain('public.rga');
call pgpm.maintain('public.rgb'); call pgpm.maintain('public.rgb'); call pgpm.maintain('public.rgb');
call pgpm.maintain('public.rgb'); call pgpm.maintain('public.rgb'); call pgpm.maintain('public.rgb');
call pgpm.maintain('public.rgb'); call pgpm.maintain('public.rgb'); call pgpm.maintain('public.rgb');
\o

select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.log
            where parent_table in ('public.rga'::regclass, 'public.rgb'::regclass)
              and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          array['rga', 'rgb'],
          'LIVENESS: both runs went on to swap [0, 300) after the restart');
select is((select note from public.rga where id = 10), 'new10', 'rga: the UPDATE of id 10 is not reverted');
select ok(not exists (select 1 from public.rga where id = 20), 'rga: the DELETE of id 20 is not resurrected');
select is((select note from public.rgb where id = 11), 'new11', 'rgb: the UPDATE of id 11 is not reverted');
select ok(not exists (select 1 from public.rgb where id = 21), 'rgb: the DELETE of id 21 is not resurrected');
select is((select array_agg(note order by id) from public.rga where id in (9, 19)), array['old9', 'old19'],
          'fixture: rga''s untouched neighbours are as inserted');
select is((select array_agg(note order by id) from public.rgb where id in (9, 19)), array['old9', 'old19'],
          'fixture: rgb''s untouched neighbours are as inserted');

-- ---------------------------------------------------------------------------- Part B: ENABLE ALWAYS, no restart
create table public.rgc (id bigint primary key, note text);
insert into public.rgc select g, 'old' || g from generate_series(1, 170) g;
call pgpm.transmute('public.rgc', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rgc');
insert into public.rgc values (450, 'frontier');
select pgpm.set_regrain('public.rgc', '50');
\o /dev/null
call pgpm.maintain('public.rgc'); call pgpm.maintain('public.rgc');   -- prepare, copy [0, 50)
\o
-- written AFTER the copy of [0, 50), so only capture can carry them: written before it, the copy itself
-- would pick them up and the assertions below would pass with capture doing nothing
update public.rgc set note = 'new12' where id = 12;
delete from public.rgc where id in (22, 23);
insert into public.rgc values (0, 'ins0');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rgc'::regclass and action = 'regrain_copy'
                   and lo = '0' and hi = '50' and rows = 49)
          and (select t.tgenabled::text from pg_trigger t join pgpm.part p on p.child_oid = t.tgrelid
                where t.tgname = 'pgpm_regrain_capture' and p.parent_table = 'public.rgc'::regclass
                  and p.attached and p.lo = '0') = 'A',
          'LIVENESS: rgc copied [0, 50) before its DML, with its capture trigger ENABLE ALWAYS');
\o /dev/null
call pgpm.maintain('public.rgc'); call pgpm.maintain('public.rgc'); call pgpm.maintain('public.rgc');
call pgpm.maintain('public.rgc'); call pgpm.maintain('public.rgc'); call pgpm.maintain('public.rgc');
call pgpm.maintain('public.rgc'); call pgpm.maintain('public.rgc'); call pgpm.maintain('public.rgc');
\o
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rgc'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '200'),
          'LIVENESS: rgc swapped [0, 200)');
select is((select count(*) from pgpm.log where parent_table = 'public.rgc'::regclass and action = 'regrain_restart'),
          0::bigint, 'a capture trigger that stayed ENABLE ALWAYS restarts nothing');
select is((select string_agg(id || '=' || note, ',' order by id) from public.rgc where id in (0, 11, 12, 13, 22, 23, 24)),
          '0=ins0,11=old11,12=new12,13=old13,24=old24',
          'capture carried rgc''s INSERT, UPDATE and two DELETEs through the swap, beside untouched neighbours');

-- ---------------------------------------------------------------------------- Part C: the swap asks again
create table public.rgd (id bigint primary key, note text);
insert into public.rgd select g, 'old' || g from generate_series(1, 230) g;
call pgpm.transmute('public.rgd', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rgd');
insert into public.rgd values (450, 'frontier');
select pgpm.set_regrain('public.rgd', '50');
\o /dev/null
call pgpm.maintain('public.rgd'); call pgpm.maintain('public.rgd'); call pgpm.maintain('public.rgd');
call pgpm.maintain('public.rgd'); call pgpm.maintain('public.rgd'); call pgpm.maintain('public.rgd');
call pgpm.maintain('public.rgd');   -- prepare and six copies: the cursor reaches the source's hi
\o
create temp table src_d as select child_oid from pgpm.part
 where parent_table = 'public.rgd'::regclass and attached and lo = '0';
select is((select regrain_cursor || '/' || (select count(*) from pgpm.part where parent_table = 'public.rgd'::regclass
                                             and not attached)
                   || '/' || (select count(*) from pgpm.log where parent_table = 'public.rgd'::regclass
                               and action = 'regrain' and method = 'copy_swap_drop')
             from pgpm.config where parent_table = 'public.rgd'::regclass),
          '300/6/0', 'LIVENESS: rgd has copied all six sub-ranges and not swapped: its next step is the swap');

-- The stand-in for an operator's concurrent ALTER TABLE ... DISABLE TRIGGER: it fires at the end of the
-- swap's DETACH (the first ALTER TABLE that leaves the source a standalone table) and disables its capture.
create table public.arm244 (src oid);
insert into public.arm244 select child_oid from src_d;
create function public.et244() returns event_trigger language plpgsql as $f$
declare v_src regclass;
begin
  select src::regclass into v_src from public.arm244;
  if v_src is not null
     and not exists (select 1 from pg_inherits where inhrelid = v_src)
     and exists (select 1 from pg_trigger where tgrelid = v_src and tgname = 'pgpm_regrain_capture' and tgenabled = 'A') then
    execute format('alter table %s disable trigger pgpm_regrain_capture', v_src::text);
  end if;
end $f$;
create event trigger et244 on ddl_command_end when tag in ('ALTER TABLE') execute function public.et244();

select throws_like(
  format($$select pgpm.regrain_step('public.rgd', %L, '50', 1000)$$,
         (select k.relname from src_d s join pg_class k on k.oid = s.child_oid)),
  '%pgpm_regrain_capture%is disabled, not ENABLE ALWAYS%The swap rolls back whole%',
  'a swap that finds capture disabled under its DETACH refuses rather than drop the source');
drop event trigger et244;
select is((select count(*) from pg_inherits i join src_d s on s.child_oid = i.inhrelid
            where i.inhparent = 'public.rgd'::regclass)
          || '/' || (select count(*) from pgpm.part where parent_table = 'public.rgd'::regclass and not attached)
          || '/' || (select tgenabled::text from pg_trigger t join src_d s on s.child_oid = t.tgrelid
                      where t.tgname = 'pgpm_regrain_capture'),
          '1/6/A', 'the refused swap rolled back whole: the source attached, its six copies kept, capture ENABLE ALWAYS');
\o /dev/null
call pgpm.maintain('public.rgd');
\o
select is((select count(*) from pgpm.log where parent_table = 'public.rgd'::regclass
            and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300')
          || '/' || (select string_agg(id || '=' || note, ',' order by id) from public.rgd where id in (1, 49, 230)),
          '1/1=old1,49=old49,230=old230',
          'LIVENESS: with capture left alone the next tick swaps [0, 300) and serves rgd''s own rows');

select * from finish();
