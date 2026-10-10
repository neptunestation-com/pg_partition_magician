-- A regrain step at a target other than the in-flight run's own is refused (issue #905).
--
-- THE DEFECT. set_regrain refuses to change the target of a run in flight (#554: the run's copies belong to
-- the step it was started at), and regrain_step refuses a second run on a DIFFERENT child of the parent
-- (#267), but regrain_step itself, and so regrain(), never asked whether the run in flight on the SAME
-- child was cut on the grid it was now asked to walk. With an auto-regrain to 50 in flight on the monolith
-- ([0, 50) copied, cursor at 50), one hand regrain_step at 20 resumed the run on the 20 grid and minted a
-- copy [40, 60) beside the run's [0, 50); every later swap tick then failed 'would overlap' (skip_regrain)
-- until regrain_cancel. The other order reaches the same wedge: a run started by hand at 20 while
-- regrain_to is 50 was resumed by the next maintain tick on the 50 grid.
--
-- THE CONTRACT. Nothing records the step a run was started at, so it is read off the run itself: while
-- capture is on the source, every copy of it already made must be exactly a sub-range of the requested
-- step's grid (clamped to the source, as regrain_step cuts them) and the cursor one of that grid's
-- boundaries. A step at a target the run was not cut on is refused before it mutates anything, by
-- whichever driver issues it (a hand regrain_step, regrain(), a maintain tick); the run stays as it was and
-- completes at its own step; the run's own target, spelled any way, is accepted.
--   (A) auto-regrain to 50 in flight: regrain_step and regrain() at 20, and regrain_step with no target
--       (partition_step 100), are refused and change nothing; regrain_step at 50 by hand is accepted; the
--       ticks then swap the monolith into six 50-wide children with no skip_regrain, every row intact.
--   (B) a run started by hand at 20 while regrain_to is 50: the maintain tick refuses (skip_regrain, the
--       refusal's own message) instead of minting a 50-grid copy over it, and regrain() at 20 finishes it.
-- Fixtures asymmetric: the monoliths hold ids 1..200 in [0, 300), so a 50-wide copy holds 49 or 50 rows and
-- a 20-wide one 19 or 20, and each refusal is checked by WHICH copies exist, not how many.
-- bench/regrain_retarget_in_flight.sh runs this file against the mutant with the check removed
-- (regrain_step_retarget_unchecked), and `./test.sh discriminate` requires it to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(20);

-- ======================================================================================================
-- (A) auto-regrain to 50 is in flight; hand steps at another target are refused
-- ======================================================================================================
create table public.rt261 (id bigint primary key, note text);
insert into public.rt261 select g, 'old' || g from generate_series(1, 200) g;
call pgpm.transmute('public.rt261', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rt261');
insert into public.rt261 values (450, 'frontier');   -- the monolith [0, 300) freezes
select pgpm.set_regrain('public.rt261', '50');
call pgpm.maintain('public.rt261');   -- prepare
call pgpm.maintain('public.rt261');   -- copy [0, 50): 49 rows, complete
select child_name as mon_a from pgpm.part
 where parent_table = 'public.rt261'::regclass and attached and lo = '0' \gset

select ok((select regrain_to = '50' and regrain_cursor = '50' from pgpm.config where parent_table = 'public.rt261'::regclass)
          and pgpm._regrain_capture_active('public.rt261', :'mon_a')
          and exists (select 1 from pgpm.log where parent_table = 'public.rt261'::regclass
                       and action = 'regrain_copy' and lo = '0' and hi = '50' and rows = 49),
          'LIVENESS: (A) an auto-regrain to 50 is in flight on the monolith: capture on, [0, 50) copied, cursor at 50');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.rt261'::regclass and not attached),
          array['0-50'], 'LIVENESS: (A) the run''s one copy is [0, 50)');

select throws_like(format($$ select pgpm.regrain_step('public.rt261', %L, '20') $$, :'mon_a'),
                   '%cannot regrain % at target step 20 -- the regrain in flight on it was not cut on that step''s grid: its copy [0, 50)%',
                   'a hand regrain_step at 20 on the child whose run to 50 is in flight is refused, naming the copy that is off its grid');
select throws_like(format($$ select pgpm.regrain('public.rt261', %L, '20') $$, :'mon_a'),
                   '%cannot regrain % at target step 20 -- the regrain in flight on it was not cut on that step''s grid%',
                   'and regrain() at 20 is refused the same way');
select throws_like(format($$ select pgpm.regrain_step('public.rt261', %L) $$, :'mon_a'),
                   '%cannot regrain % at target step 100 -- the regrain in flight on it was not cut on that step''s grid%',
                   'and so is a hand step with no target, which walks partition_step''s grid (100)');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.rt261'::regclass and not attached),
          array['0-50'], 'the refused steps minted no copy: [0, 50) is still the only one, and nothing over [40, 60)');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rt261'::regclass), '50',
          'and left the cursor where the run had it');

select is(pgpm.regrain_step('public.rt261', :'mon_a', '50'), 'copied:50',
          'the run''s own target by hand is accepted: it copies the run''s next sub-range [50, 100)');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.rt261'::regclass and not attached),
          array['0-50', '50-100'], 'LIVENESS: (A) the accepted hand step cut its copy on the run''s grid');

do $$ declare v_st text; begin
  for i in 1..20 loop
    call pgpm.maintain('public.rt261', v_st);
    exit when v_st like '%regrain=swapped:%';
  end loop;
end $$;
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.rt261'::regclass and attached and hi::numeric <= 300),
          array['0-50', '50-100', '100-150', '150-200', '200-250', '250-300'],
          'the run completed at its own step: [0, 300) is replaced by the six 50-wide children');
select is((select array_agg(left(method, 60) order by id) from pgpm.log
            where parent_table = 'public.rt261'::regclass and action = 'skip_regrain'), null,
          'no tick of the run was refused');
select is((select array_agg(id || ':' || note order by id) from public.rt261 where id in (1, 45, 50, 55, 150, 200, 450)),
          array['1:old1', '45:old45', '50:old50', '55:old55', '150:old150', '200:old200', '450:frontier'],
          'every row reads as inserted after the swap');

-- ======================================================================================================
-- (B) a run started by hand at 20 while regrain_to is 50: the tick refuses rather than resume it on 50
-- ======================================================================================================
create table public.rh261 (id bigint primary key, note text);
insert into public.rh261 select g, 'old' || g from generate_series(1, 200) g;
call pgpm.transmute('public.rh261', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rh261');
insert into public.rh261 values (450, 'frontier');
select pgpm.set_regrain('public.rh261', '50');   -- nothing in flight yet, so this is accepted
select child_name as mon_b from pgpm.part
 where parent_table = 'public.rh261'::regclass and attached and lo = '0' \gset
select is(pgpm.regrain_step('public.rh261', :'mon_b', '20'), 'prepared',
          'LIVENESS: (B) a hand regrain_step at 20 starts a run while regrain_to is 50');
select is(pgpm.regrain_step('public.rh261', :'mon_b', '20'), 'copied:19',
          'LIVENESS: (B) and a second one copies [0, 20)');

call pgpm.maintain('public.rh261');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.rh261'::regclass and not attached),
          array['0-20'], 'the tick at 50 minted no copy over the hand-started run: [0, 20) is still the only one');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rh261'::regclass), '20',
          'and left its cursor at 20');
select is((select array_agg(left(method, 100) order by id) from pgpm.log
            where parent_table = 'public.rh261'::regclass and action = 'skip_regrain'),
          array[left(format('pg_partition_magician: cannot regrain %s at target step 50 -- the regrain in flight on it was not cut on that step''s grid: its copy [0, 20)', :'mon_b'), 100)],
          'the tick logged the refusal, once, with its own message');

select is(pgpm.regrain('public.rh261', :'mon_b', '20'), 15,
          'regrain() at the run''s own step finishes it: 15 children of 20');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.rh261'::regclass and attached and hi::numeric <= 60),
          array['0-20', '20-40', '40-60'], 'LIVENESS: (B) the swap attached the run''s 20-grid children');
select is((select array_agg(id || ':' || note order by id) from public.rh261 where id in (1, 19, 20, 21, 150, 200)),
          array['1:old1', '19:old19', '20:old20', '21:old21', '150:old150', '200:old200'],
          'every row reads as inserted after it');

select * from finish();
