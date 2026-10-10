-- Every regrain site finds the source and the delta where they ARE, after the parent has moved schema
-- (issues #768 F3-04, #555 F3-11).
--
-- ALTER TABLE <parent> SET SCHEMA is safe by contract: the managed table moves, its partitions stay where
-- they were, and pgpm tracks the parent by oid. The regrain family still resolved its two relations as
-- <the parent's CURRENT schema>.<name>:
--   the SOURCE (regrain_step's read of it, the capture install, _regrain_capture_active, the reconcile's
--     read of the source rows, the janitor, _regrain_reclaim): after the move every auto-regrain tick
--     failed 'relation <new schema>.<monolith> does not exist', and the monolith could never be regrained;
--   the DELTA (regrain_cancel's truncate, the swap's, _regrain_reclaim's delete, the purge, the reconcile,
--     the per-tick grant): the delta stays in the schema it was minted in, so those statements reached
--     whatever bore its name in the new schema, or nothing: a cancel emptied an unrelated table and left
--     the real delta holding its captured change.
-- The contract: the source is the relation pgpm.part recorded (child_oid), the delta the one pgpm.config
-- recorded (regrain_delta_oid), each in its own schema, so a regrain moved mid-flight or before it began
-- behaves exactly as an unmoved one, and nothing in the destination schema that merely shares a name is
-- touched.
--
-- Every part plants a STRANGER: an operator table named <parent>_pgpm_regrain_delta in the destination
-- schema, holding two rows whose ids lie outside the regrained range, so the purge's out-of-range delete,
-- a truncate and a delete-all would each show on it.
--   (A) moved after the prepare tick, driven by auto-regrain to the swap, with writes through the moved
--       parent in between: an UPDATE of a copied row, a DELETE of two, an INSERT, and a cross-partition
--       UPDATE out of the range (captured as a DELETE). Six keys touched, four outcomes.
--   (B) moved before set_regrain (the issue's own shape): the delta is minted in the new schema, the source
--       stays in the old one, and the regrain completes.
--   (C) regrain_cancel after the move: the real delta is emptied, the source loses both triggers.
--   (D) the janitor after the move: an orphaned capture (its cursor cleared by hand) is torn down from the
--       source where it is, not logged as a failure.
--   (E) retire() of an in-flight source after the move: _regrain_reclaim clears the real delta and the
--       source's triggers.
-- The #650 upgrade block's half of the class (F3-12) needs install.sql re-run, which one pgTAP file cannot
-- do, so bench/regrain_moved_parent_identity.sh checks it after running this file; it also runs both
-- against the mutants that put a parent-schema resolution back (regrain_step_source_parent_schema,
-- regrain_cancel_delta_parent_schema, regrain_upgrade_guard_parent_schema), and each must FAIL there.
create extension if not exists pgtap;
select plan(26);

create schema mvh;
-- a table of ids 1..200, which each part transmutes to one monolith [0, 300) and freezes by a write at 450
create function pg_temp.mk(p_rel text) returns void language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_rel);
  execute format('insert into public.%I select g, ''a'' || g from generate_series(1, 200) g', p_rel);
end $$;
create function pg_temp.stranger(p_rel text) returns void language plpgsql as $$
begin
  execute format('create table mvh.%I (id bigint primary key, note text)', p_rel || '_pgpm_regrain_delta');
  execute format('insert into mvh.%I values (1000, ''keep-1''), (2000, ''keep-2'')', p_rel || '_pgpm_regrain_delta');
end $$;
create function pg_temp.stranger_rows(p_rel text) returns text[] language plpgsql as $$
declare v text[];
begin
  execute format('select array_agg(id || '':'' || note order by id) from mvh.%I', p_rel || '_pgpm_regrain_delta') into v;
  return v;
end $$;
-- the keys a delta holds, oldest capture first, or null when no relation bears that name: never an error,
-- so a mutant that never minted one fails the assertion instead of ending the file
create function pg_temp.keys_in(p_rel text) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if to_regclass(p_rel) is null then return null; end if;
  execute format('select coalesce(array_agg(id order by pgpm_seq), ''{}'') from %s', to_regclass(p_rel)) into v;
  return v;
end $$;
create function pg_temp.triggers_on(p_rel regclass) returns text[] language sql as $$
  select coalesce(array_agg(tgname::text order by tgname), '{}') from pg_trigger where tgrelid = p_rel and not tgisinternal $$;

-- ======================================================================================================
-- (A) moved after the prepare tick; auto-regrain to the swap
-- ======================================================================================================
select pg_temp.mk('ra');
call pgpm.transmute('public.ra', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.ra');
insert into public.ra values (450, 'frontier');
select pgpm.set_regrain('public.ra', '50');
call pgpm.maintain('public.ra');   -- prepare: capture on the source, public.ra_pgpm_regrain_delta minted
alter table public.ra set schema mvh;
select pg_temp.stranger('ra');
select ok((select regrain_delta_oid from pgpm.config where parent_table = 'mvh.ra'::regclass)
            = to_regclass('public.ra_pgpm_regrain_delta')::oid
          and pg_temp.triggers_on('public.ra_p0000000000000000000_to_0000000000000000300')
            = array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard']
          and (select regrain_cursor from pgpm.config where parent_table = 'mvh.ra'::regclass) = '0',
          'LIVENESS: (A) prepared before the move, the parent is in mvh and its source and delta stayed in public');
call pgpm.maintain('mvh.ra');      -- copies [0, 50)
select ok(exists (select 1 from pgpm.log where parent_table = 'mvh.ra'::regclass
                   and action = 'regrain_copy' and lo = '0' and hi = '50' and rows = 49),
          'A: the first tick after the move copies [0, 50) out of the source in public');
update mvh.ra set payload = 'upd-10' where id = 10;
delete from mvh.ra where id in (20, 30);
insert into mvh.ra values (250, 'ins-250');
update mvh.ra set id = 350, payload = 'moved-199' where id = 199;   -- leaves [0, 300): captured as a DELETE
select is(pg_temp.keys_in('public.ra_pgpm_regrain_delta'),
          array[10, 10, 20, 30, 250, 199]::bigint[],
          'LIVENESS: (A) the writes through the moved parent were captured in the real delta');
do $$ declare v_st text; begin
  for i in 1..20 loop
    call pgpm.maintain('mvh.ra', v_st);
    exit when v_st like '%regrain=swapped:%';
  end loop;
end $$;
select is((select string_agg(distinct left(method, 160), ' | ') from pgpm.log
            where parent_table = 'mvh.ra'::regclass and action = 'skip_regrain'),
          null, 'A: no auto-regrain tick fails after the move');
select ok(exists (select 1 from pgpm.log where parent_table = 'mvh.ra'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300')
          and exists (select 1 from pgpm.log where parent_table = 'mvh.ra'::regclass and action = 'regrain_reconcile'),
          'A: the moved table''s monolith reconciled its captured changes and swapped');
select is((select array_agg(id || ':' || payload order by id) from mvh.ra
            where id in (9, 10, 11, 19, 20, 21, 30, 198, 199, 250, 350)),
          array['9:a9', '10:upd-10', '11:a11', '19:a19', '21:a21', '198:a198', '250:ins-250', '350:moved-199'],
          'A: every write made through the moved parent mid-regrain holds after the swap');
select is(pg_temp.keys_in('public.ra_pgpm_regrain_delta'), '{}'::bigint[], 'A: the swap emptied the real delta');
select is(pg_temp.stranger_rows('ra'), array['1000:keep-1', '2000:keep-2'],
          'A: the unrelated mvh.ra_pgpm_regrain_delta keeps both rows through the purge and the swap');

-- ======================================================================================================
-- (B) moved before set_regrain: the issue's shape
-- ======================================================================================================
select pg_temp.mk('rb');
call pgpm.transmute('public.rb', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rb');
insert into public.rb values (450, 'frontier');
alter table public.rb set schema mvh;
select ok(exists (select 1 from pgpm.part where parent_table = 'mvh.rb'::regclass and attached
                   and child_name = 'rb_p0000000000000000000_to_0000000000000000300'
                   and child_oid = 'public.rb_p0000000000000000000_to_0000000000000000300'::regclass::oid),
          'LIVENESS: (B) the parent moved to mvh and its monolith stayed in public, recorded by oid');
select pgpm.set_regrain('mvh.rb', '50');
call pgpm.maintain('mvh.rb');   -- prepare
update mvh.rb set payload = 'upd-60' where id = 60;
select ok((select regrain_delta_oid from pgpm.config where parent_table = 'mvh.rb'::regclass)
            = to_regclass('mvh.rb_pgpm_regrain_delta')::oid
          and pg_temp.triggers_on('public.rb_p0000000000000000000_to_0000000000000000300')
            = array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard']
          and pg_temp.keys_in('mvh.rb_pgpm_regrain_delta') = array[60, 60]::bigint[],
          'B: the prepare tick puts capture on the source in public, writing to the delta it minted in mvh');
do $$ declare v_st text; begin
  for i in 1..20 loop
    call pgpm.maintain('mvh.rb', v_st);
    exit when v_st like '%regrain=swapped:%';
  end loop;
end $$;
select is((select string_agg(distinct left(method, 160), ' | ') from pgpm.log
            where parent_table = 'mvh.rb'::regclass and action = 'skip_regrain'),
          null, 'B: no auto-regrain tick fails');
select ok(exists (select 1 from pgpm.log where parent_table = 'mvh.rb'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          'B: the monolith of a table moved before its regrain began regrains');
select is((select array_agg(id || ':' || payload order by id) from mvh.rb where id in (59, 60, 61)),
          array['59:a59', '60:upd-60', '61:a61'], 'B: and the write made mid-regrain holds');

-- ======================================================================================================
-- (C) regrain_cancel after the move
-- ======================================================================================================
select pg_temp.mk('rc');
call pgpm.transmute('public.rc', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => true);
select pgpm.obtain('public.rc');
insert into public.rc values (450, 'frontier');
select pgpm.regrain_step('public.rc', 'rc_p0000000000000000000_to_0000000000000000300', '50', 1000);   -- prepare
alter table public.rc set schema mvh;
select pg_temp.stranger('rc');
update mvh.rc set payload = 'x' where id = 10;
select ok((select regrain_delta_oid from pgpm.config where parent_table = 'mvh.rc'::regclass)
            = to_regclass('public.rc_pgpm_regrain_delta')::oid
          and pg_temp.keys_in('public.rc_pgpm_regrain_delta') = array[10, 10]::bigint[],
          'LIVENESS: (C) the real delta, recorded by oid and left in public, holds the captured change');
select is(pgpm.regrain_cancel('mvh.rc'), 0, 'C: regrain_cancel runs (no copy had been made)');
select is(pg_temp.stranger_rows('rc'), array['1000:keep-1', '2000:keep-2'],
          'C: regrain_cancel leaves the unrelated mvh.rc_pgpm_regrain_delta and its rows alone');
select is(pg_temp.keys_in('public.rc_pgpm_regrain_delta'), '{}'::bigint[], 'C: and empties the regrain''s own delta');
select is(pg_temp.triggers_on('public.rc_p0000000000000000000_to_0000000000000000300'), '{}'::text[],
          'C: and takes both regrain triggers off the source in public');

-- ======================================================================================================
-- (D) the janitor after the move
-- ======================================================================================================
select pg_temp.mk('rd');
call pgpm.transmute('public.rd', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => true);
select pgpm.obtain('public.rd');
insert into public.rd values (450, 'frontier');
select pgpm.regrain_step('public.rd', 'rd_p0000000000000000000_to_0000000000000000300', '50', 1000);   -- prepare
alter table public.rd set schema mvh;
update pgpm.config set regrain_cursor = null where parent_table = 'mvh.rd'::regclass;   -- the hand edit
select ok(pg_temp.triggers_on('public.rd_p0000000000000000000_to_0000000000000000300')
            = array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard'],
          'LIVENESS: (D) the moved table''s source in public still carries the capture its cleared cursor orphaned');
select ok(pgpm._regrain_capture_active('mvh.rd', 'rd_p0000000000000000000_to_0000000000000000300'),
          'D: _regrain_capture_active reads that source as captured');
select pgpm._enforce_regrain_capture('mvh.rd');
select is(pg_temp.triggers_on('public.rd_p0000000000000000000_to_0000000000000000300'), '{}'::text[],
          'D: the janitor tears the orphaned capture and its TRUNCATE guard off the source where it is');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'mvh.rd'::regclass
            and action in ('regrain_capture_orphan', 'skip_regrain_capture')),
          array['regrain_capture_orphan'], 'D: logged as one orphan torn down, not as a failure');

-- ======================================================================================================
-- (E) retire() of an in-flight source after the move: _regrain_reclaim
-- ======================================================================================================
select pg_temp.mk('re');
call pgpm.transmute('public.re', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => true, p_retain => 100);
select pgpm.obtain('public.re');
insert into public.re values (450, 'frontier');
select pgpm.regrain_step('public.re', 're_p0000000000000000000_to_0000000000000000300', '50', 1000);   -- prepare
alter table public.re set schema mvh;
select pg_temp.stranger('re');
update mvh.re set payload = 'x' where id = 10;
select ok(pg_temp.keys_in('public.re_pgpm_regrain_delta') = array[10, 10]::bigint[]
          and pg_temp.triggers_on('public.re_p0000000000000000000_to_0000000000000000300')
            = array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard'],
          'LIVENESS: (E) an in-flight regrain''s source and delta stayed in public, the delta holding a captured change');
select ok(pgpm.retire('mvh.re', 're_p0000000000000000000_to_0000000000000000300'),
          'E: retire drops the in-flight source of the moved table');
select is((select method from pgpm.log where parent_table = 'mvh.re'::regclass and action = 'regrain_cancel'),
          'retire dropped public.re_p0000000000000000000_to_0000000000000000300, the source of this regrain, whole: its range is past the retention horizon and archiving covers it, so the regrain had nothing left to win for retention; 0 fine copies discarded, 2 captured changes discarded, regrain_cursor cleared',
          'E: the reclaim found the capture on the source and discarded the real delta''s two captured changes');
select ok(pg_temp.stranger_rows('re') = array['1000:keep-1', '2000:keep-2']
          and pg_temp.keys_in('public.re_pgpm_regrain_delta') = '{}'::bigint[],
          'E: the real delta is empty and the unrelated mvh.re_pgpm_regrain_delta keeps both rows');

select * from finish();
