-- set_regrain accepts the in-flight run's own target in any spelling of the same step, and still refuses a
-- step that lays another grid (issue #1165, review pass 11 F3-03).
--
-- THE DEFECT. set_regrain refuses a CHANGE of target while a run is in flight (#554: the run's copies were cut
-- on the step it was started at), and docs/reference.md promises "re-stating the target already set is not a
-- change and is accepted". The test compared p_target_step with config.regrain_to as TEXT, so with a run in
-- flight at '50' the call set_regrain(t, '050') was refused as a change of target, and the message sent the
-- operator to regrain_cancel, which throws the copy work away. regrain_step reads the run's step off the grid
-- (#905), so '050' walks exactly the run's grid there.
--
-- THE CONTRACT. Two steps are the same target when they lay the same grid: for an id key the same number,
-- for a time key the same whole number of calendar months, or (with no months) the same fixed number of
-- seconds, which is how the grid itself reads a step (_grid_floor, _grid_next, _part_name). So '050' is '50',
-- '1 mon' is '1 month' and '24 hours' is '1 day', each accepted with the run left as it was and completed on
-- the new spelling; while '30 days', which interval comparison calls EQUAL to '1 month', lays a fixed 30-day
-- lattice and stays refused, as do a plainly different step and any target while an operator-driven run is
-- in flight with regrain_to null.
--   (A) id key, auto-regrain to 50 in flight: '25' refused; '050' accepted and the ticks finish the run.
--   (B) uuidv7 key on a '3 months' grid, run at '1 month': '30 days' refused; '1 mon' accepted, run continues.
--   (C) uuidv7 key on a '7 days' grid, run at '1 day': '12 hours' refused; '24 hours' accepted, run continues.
--   (D) auto-regrain off, a run started by hand at 20: set_regrain(t, '20') is still refused.
-- Fixtures asymmetric: each run's copies are named by their bounds, and the rows a copy took are counted
-- per cell of different sizes (49, 31, 29, 5), so a step that walked another grid cannot read the same.
-- bench/set_regrain_restated_target.sh runs this file against the mutants set_regrain_target_compared_as_text
-- and same_step_interval_equality, and `./test.sh discriminate` requires it to FAIL against each.
set timezone = 'UTC';
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(27);

create function pg_temp.u7(p_ts timestamptz, n int) returns uuid language sql as $$
  select (substr(h,1,8)||'-'||substr(h,9,4)||'-'||substr(h,13,4)||'-'||substr(h,17,4)||'-'||substr(h,21,12))::uuid
    from (select lpad(to_hex(floor(extract(epoch from p_ts) * 1000)::bigint), 12, '0') || '7' || lpad(to_hex(n), 3, '0')
                 || '8' || lpad(to_hex(n), 15, '0') as h) x $$;

-- ======================================================================================================
-- (A) id key: an auto-regrain to 50 is in flight
-- ======================================================================================================
create table public.ra319 (id bigint primary key, note text);
insert into public.ra319 select g, 'old' || g from generate_series(1, 200) g;
call pgpm.transmute('public.ra319', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.ra319');
insert into public.ra319 values (450, 'frontier');   -- the monolith [0, 300) freezes
select pgpm.set_regrain('public.ra319', '50');
call pgpm.maintain('public.ra319');   -- prepare
call pgpm.maintain('public.ra319');   -- copy [0, 50): 49 rows
select child_name as mon_a from pgpm.part
 where parent_table = 'public.ra319'::regclass and attached and lo = '0' \gset

select ok((select regrain_to = '50' and regrain_cursor = '50' from pgpm.config where parent_table = 'public.ra319'::regclass)
          and pgpm._regrain_in_flight('public.ra319')
          and exists (select 1 from pgpm.log where parent_table = 'public.ra319'::regclass
                       and action = 'regrain_copy' and lo = '0' and hi = '50' and rows = 49),
          'LIVENESS (A): an auto-regrain to 50 is in flight: [0, 50) copied with its 49 rows, cursor at 50');

select throws_like($$ select pgpm.set_regrain('public.ra319', '25') $$,
                   '%set_regrain(ra319, 25) refused -- a regrain of ra319 is in flight%',
                   '(A) a different step (25) is still refused while the run to 50 is in flight');
select lives_ok($$ select pgpm.set_regrain('public.ra319', '050') $$,
                '(A) the run''s own target spelled 050 is accepted: it is the same step as 50');
select is((select regrain_to from pgpm.config where parent_table = 'public.ra319'::regclass), '050',
          '(A) the accepted call wrote the target it was given');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.ra319'::regclass and not attached),
          array['0-50'], '(A) and left the run''s copy as it was');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.ra319'::regclass), '50',
          '(A) and its cursor where the run had it');

do $$ declare v_st text; begin
  for i in 1..20 loop
    call pgpm.maintain('public.ra319', v_st);
    exit when v_st like '%regrain=swapped:%';
  end loop;
end $$;
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.ra319'::regclass and attached and hi::numeric <= 300),
          array['0-50', '50-100', '100-150', '150-200', '200-250', '250-300'],
          '(A) the ticks finished the run on the respelled target: [0, 300) is replaced by six 50-wide children');
select is((select array_agg(left(method, 80) order by id) from pgpm.log
            where parent_table = 'public.ra319'::regclass and action = 'skip_regrain'), null,
          '(A) no tick of the run was refused');
select is((select array_agg(id || ':' || note order by id) from public.ra319 where id in (1, 49, 50, 51, 199, 200, 450)),
          array['1:old1', '49:old49', '50:old50', '51:old51', '199:old199', '200:old200', '450:frontier'],
          '(A) every row reads as inserted after the swap');

-- ======================================================================================================
-- (B) uuidv7 key on a '3 months' grid: a run at '1 month' is in flight
-- ======================================================================================================
create table public.rb319 (id uuid primary key, note text);
insert into public.rb319 select pg_temp.u7('2024-01-01'::timestamptz + make_interval(days => g), g), 'old' || g
  from generate_series(0, 89) g;   -- 31 rows in January 2024, 29 in February, 30 in March
call pgpm.transmute('public.rb319', 'id', interval '3 months', p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
insert into public.rb319 select pg_temp.u7(max(hi::timestamptz) - interval '1 day', 999), 'frontier'
  from pgpm.part where parent_table = 'public.rb319'::regclass;   -- the frontier passes the monolith: it freezes
select child_name as mon_b from pgpm.part
 where parent_table = 'public.rb319'::regclass and attached and lo::timestamptz = '2024-01-01' \gset
select pgpm.set_regrain('public.rb319', '1 month');
select is(pgpm.regrain_step('public.rb319', :'mon_b', '1 month'), 'prepared', 'LIVENESS (B): a run at 1 month is prepared');
select is(pgpm.regrain_step('public.rb319', :'mon_b', '1 month'), 'copied:31', 'LIVENESS (B): and copies January 2024');
select ok(pgpm._regrain_in_flight('public.rb319'), 'LIVENESS (B): the run at 1 month is in flight');

select throws_like($$ select pgpm.set_regrain('public.rb319', '30 days') $$,
                   '%set_regrain(rb319, 30 days) refused -- a regrain of rb319 is in flight%',
                   '(B) 30 days, which interval comparison calls equal to 1 month, lays another grid and is refused');
select lives_ok($$ select pgpm.set_regrain('public.rb319', '1 mon') $$,
                '(B) the run''s own target spelled 1 mon is accepted');
select is((select regrain_to from pgpm.config where parent_table = 'public.rb319'::regclass), '1 mon',
          '(B) the accepted call wrote the target it was given');
select is(pgpm.regrain_step('public.rb319', :'mon_b',
                            (select regrain_to from pgpm.config where parent_table = 'public.rb319'::regclass)),
          'copied:29', '(B) and the run continues on it: the next step copies February 2024''s 29 rows');
select is((select array_agg(child_name::text order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.rb319'::regclass and not attached),
          array['rb319_p2024_01', 'rb319_p2024_02'], '(B) the run''s copies are its January and February cells');

-- ======================================================================================================
-- (C) uuidv7 key on a '7 days' grid: a run at '1 day' is in flight
-- ======================================================================================================
create table public.rc319 (id uuid primary key, note text);
insert into public.rc319 select pg_temp.u7('2024-01-01'::timestamptz + make_interval(hours => 5 * g), g), 'old' || g
  from generate_series(0, 89) g;   -- every 5 hours: 5 rows on 1 January 2024
call pgpm.transmute('public.rc319', 'id', interval '7 days', p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
insert into public.rc319 select pg_temp.u7(max(hi::timestamptz) - interval '1 day', 999), 'frontier'
  from pgpm.part where parent_table = 'public.rc319'::regclass;
-- the weekly lattice from the default anchor (a Saturday) puts the monolith's lo at 2023-12-30
select child_name as mon_c from pgpm.part
 where parent_table = 'public.rc319'::regclass and attached and lo::timestamptz = '2023-12-30' \gset
select pgpm.set_regrain('public.rc319', '1 day');
select is(pgpm.regrain_step('public.rc319', :'mon_c', '1 day'), 'prepared', 'LIVENESS (C): a run at 1 day is prepared');
select is(pgpm.regrain_step('public.rc319', :'mon_c', '1 day'), 'copied:0', 'LIVENESS (C): and copies 30 December 2023');
select ok(pgpm._regrain_in_flight('public.rc319'), 'LIVENESS (C): the run at 1 day is in flight');

select throws_like($$ select pgpm.set_regrain('public.rc319', '12 hours') $$,
                   '%set_regrain(rc319, 12 hours) refused -- a regrain of rc319 is in flight%',
                   '(C) a different fixed step (12 hours) is refused');
select lives_ok($$ select pgpm.set_regrain('public.rc319', '24 hours') $$,
                '(C) the run''s own target spelled 24 hours is accepted: the grid steps 1 day by 86400 seconds too');
select is(pgpm.regrain_step('public.rc319', :'mon_c',
                            (select regrain_to from pgpm.config where parent_table = 'public.rc319'::regclass)),
          'copied:0', '(C) the run continues on it: 31 December 2023');
select is(pgpm.regrain_step('public.rc319', :'mon_c',
                            (select regrain_to from pgpm.config where parent_table = 'public.rc319'::regclass)),
          'copied:5', '(C) and 1 January 2024 with its 5 rows');
select is((select array_agg(child_name::text order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.rc319'::regclass and not attached),
          array['rc319_p2023_12_30', 'rc319_p2023_12_31', 'rc319_p2024_01_01'],
          '(C) the run''s copies are its three day cells, named as the 1 day grid names them');

-- ======================================================================================================
-- (D) auto-regrain off, a run started by hand at 20: its step is not recorded, so any target is a change
-- ======================================================================================================
create table public.rd319 (id bigint primary key, note text);
insert into public.rd319 select g, 'old' || g from generate_series(1, 150) g;
call pgpm.transmute('public.rd319', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rd319');
insert into public.rd319 values (450, 'frontier');
select child_name as mon_d from pgpm.part
 where parent_table = 'public.rd319'::regclass and attached and lo = '0' \gset
select is(pgpm.regrain_step('public.rd319', :'mon_d', '20'), 'prepared',
          'LIVENESS (D): a hand regrain_step at 20 starts a run while auto-regrain is off');
select throws_like($$ select pgpm.set_regrain('public.rd319', '20') $$,
                   '%set_regrain(rd319, 20) refused -- a regrain of rd319 is in flight%a step it was started at by hand (regrain_to is null)%',
                   '(D) set_regrain(t, ''20'') is refused: with regrain_to null the run''s step is unknown');

drop function pg_temp.u7(timestamptz, int);
select * from finish();
