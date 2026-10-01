-- Issue #729: maintain() must dispatch auto-regrain from the regrain_to in force once it holds the
-- per-parent regrain lock, not from the one it read at the top of the tick.
--
-- THE DEFECT. maintain() reads the parent's pgpm.config row once, at the top of the tick, then runs three
-- committed steps (write block, archive, retain) before its auto-regrain block, which dispatched
--   regrain_step(p_parent, <candidate>, cfg.regrain_to, ...)
-- from that first read. regrain_step takes pgpm._regrain_lock but never looks at config.regrain_to (it is
-- also the operator's manual entry point and takes any target). So a set_regrain(t, null) committed while
-- the tick was archiving (a step docs/reference.md sizes in seconds) did not stop it: the tick PREPARED a
-- new run at the old target (capture trigger and TRUNCATE guard on the source, regrain_cursor set) after
-- auto-regrain had been turned off. Nothing drives such a run (maintain dispatches only while regrain_to
-- is set), and a second set_regrain(t, null) finds auto-regrain already off and by design changes nothing:
-- the stranded state #516 exists to prevent.
--
-- THE FIX. The auto-regrain block takes the regrain lock itself and re-reads regrain_to under it, and
-- dispatches nothing when it is null. set_regrain takes the same lock before it reads, so the two are
-- ordered whichever comes first: a set_regrain committed first is seen here, and one that arrives after
-- this tick took the lock waits for the tick's commit and then cancels the run it finds (#516).
--
-- Deterministic interleaving, no timing: each table's archive strategy is an instrument that, on its call
-- inside the tick's archive step, has a SECOND session (dblink) run and commit a set_regrain for that table,
-- then reports partial coverage, so retain keeps the coarse monolith and the tick goes on to its regrain
-- block. Two tables, asymmetric on purpose: rg_off has auto-regrain turned OFF mid-tick and must prepare
-- nothing; rg_on has the same second session re-state its target mid-tick and must prepare as before, so
-- the dispatch is shown alive through the same path that the off switch takes.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(16);

create schema s191;
create table s191.calls (parent text, regrain_to_seen text);
create table s191.quiet (on_ boolean);   -- a row here: the operator does nothing this tick
create function s191.archiver(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_target text;
begin
  if exists (select 1 from s191.quiet) then
    v.covered_hi := (p_lo::numeric + 1)::text; v.rows_archived := 1;
    return v;
  end if;
  -- what the operator does in another session while this tick is archiving
  v_target := case p_parent when 'public.rg_off'::regclass then 'null' else '''5''' end;
  perform dblink_connect('op191', 'dbname=' || current_database());
  perform * from dblink('op191',
    format('select pgpm.set_regrain(%L, %s)::text', p_parent::text, v_target)) as t(x text);
  insert into s191.calls
    select p_parent::text, r from dblink('op191',
      format('select coalesce(regrain_to, ''<null>'') from pgpm.config where parent_table = %L::regclass',
             p_parent::text)) as t(r text);
  perform dblink_disconnect('op191');
  v.covered_hi := (p_lo::numeric + 1)::text;   -- bounded progress: the partition is not yet covered
  v.rows_archived := 1;
  return v;
end $$;

-- Two tables of the same shape: monolith [0, 20) at step 10, frozen and aged by a frontier row at 55
-- (floor 50, horizon 30), auto-regrain on at 5.
create table public.rg_off (id bigint primary key, payload text);
insert into public.rg_off values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.rg_off', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rg_off', '60');
insert into public.rg_off values (55, 'frontier');
select pgpm.set_regrain('public.rg_off', '5');
select pgpm.set_archive_fn('public.rg_off', 's191.archiver(regclass,name,text,text)'::regprocedure);
select child_name as off_mono from pgpm.part where parent_table = 'public.rg_off'::regclass and lo = '0' \gset

create table public.rg_on (id bigint primary key, payload text);
insert into public.rg_on values (3, 'a'), (4, 'b'), (12, 'c'), (17, 'd');
call pgpm.transmute('public.rg_on', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.rg_on', '60');
insert into public.rg_on values (55, 'frontier');
select pgpm.set_regrain('public.rg_on', '5');
select pgpm.set_archive_fn('public.rg_on', 's191.archiver(regclass,name,text,text)'::regprocedure);
select child_name as on_mono from pgpm.part where parent_table = 'public.rg_on'::regclass and lo = '0' \gset

select is((select array_agg(parent_table::text || '=' || regrain_to order by parent_table::text) from pgpm.config
            where parent_table in ('public.rg_off'::regclass, 'public.rg_on'::regclass)),
  array['rg_off=5', 'rg_on=5'],
  'LIVENESS: auto-regrain is on (regrain_to 5) for both tables when their ticks start');
select ok(not pgpm._regrain_in_flight('public.rg_off') and not pgpm._regrain_in_flight('public.rg_on'),
  'LIVENESS: no regrain is in flight for either table before its tick');

-- rg_off: auto-regrain turned off while the tick archives
call pgpm.maintain('public.rg_off') \gset off_
select is((select array_agg(regrain_to_seen) from s191.calls where parent = 'rg_off'), array['<null>'],
  'LIVENESS: rg_off''s archive step ran once, and the operator''s set_regrain(rg_off, null) committed inside it');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.rg_off'::regclass
                   and attached and child_name = :'off_mono' and lo = '0' and hi = '20'),
  'LIVENESS: rg_off''s coarse, frozen monolith [0, 20) was kept (not yet covered), so it was a regrain candidate');
select ok(:'off_p_status' like '%regrain=skipped%',
  'rg_off''s tick dispatched no regrain once auto-regrain was off: ' || :'off_p_status');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.rg_off'::regclass
                       and action = 'regrain_prepare'),
  'no regrain_prepare was logged for rg_off');
select ok((select regrain_cursor is null from pgpm.config where parent_table = 'public.rg_off'::regclass)
          and not pgpm._regrain_capture_active('public.rg_off', :'off_mono'),
  'rg_off''s cursor stays null and no capture trigger is on its monolith, as set_regrain(null) promises');
select ok(not pgpm._regrain_in_flight('public.rg_off'),
  'no regrain of rg_off is in flight after the tick');

-- rg_on: the same second session re-states the target while the tick archives
call pgpm.maintain('public.rg_on') \gset on_
select is((select array_agg(regrain_to_seen) from s191.calls where parent = 'rg_on'), array['5'],
  'LIVENESS: rg_on''s archive step ran once, and the operator''s set_regrain(rg_on, 5) committed inside it');
select ok(:'on_p_status' like '%regrain=prepared%',
  'rg_on''s tick, with auto-regrain still on, prepared its regrain: ' || :'on_p_status');
select is((select array_agg(lo || ',' || hi || ',' || method) from pgpm.log
            where parent_table = 'public.rg_on'::regclass and action = 'regrain_prepare'),
  array['0,20,' || :'on_mono'],
  'and the prepare is of rg_on''s monolith [0, 20)');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rg_on'::regclass), '0',
  'rg_on''s cursor is set at the monolith''s lo');
select ok(pgpm._regrain_capture_active('public.rg_on', :'on_mono'),
  'and capture is on rg_on''s monolith');

-- A later rg_off tick, with nothing changing under it and the monolith still a candidate, dispatches
-- nothing either: the off switch holds.
insert into s191.quiet values (true);
call pgpm.maintain('public.rg_off') \gset off2_
select ok(exists (select 1 from pgpm.part where parent_table = 'public.rg_off'::regclass
                   and attached and child_name = :'off_mono' and lo = '0' and hi = '20'),
  'LIVENESS: rg_off''s monolith [0, 20) is still there for the later tick to find');
select ok(:'off2_p_status' like '%regrain=skipped%' and not pgpm._regrain_in_flight('public.rg_off'),
  'a later rg_off tick leaves auto-regrain off and no regrain in flight: ' || :'off2_p_status');
select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.config
            where parent_table in ('public.rg_off'::regclass, 'public.rg_on'::regclass) and regrain_cursor is not null),
  array['rg_on'],
  'of the two, only rg_on has a regrain in flight');

select * from finish();
