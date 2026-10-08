-- Issue #1070: the regrain reconcile applied and consumed delta rows it had not judged eligible.
--
-- A reconcile tick judges which captured keys it may apply: those whose control value lies in a sub-range
-- the copy has already finished. It cut that batch in one snapshot (#497) and then addressed it in every
-- later statement by the rows' pgpm_seq values. pgpm_seq is GENERATED ALWAYS but not unique, and every
-- writer of the table holds INSERT on the delta (the capture trigger writes it as the writer), which allows
-- OVERRIDING SYSTEM VALUE. So a role with INSERT alone wrote two delta rows on one pgpm_seq: key 3 (below
-- the cursor) and key 18 (in the sub-range still being copied). The tick judged key 3, then applied and
-- consumed every row on that pgpm_seq: key 18 was written into the part-copied sub-range, the copy resumed
-- above it (it resumes at max(dest.ctl)) and never copied 16, and the swap dropped 16 with the source.
--
-- The fix addresses the batch by the rows themselves, the tuple identities read in the snapshot that judged
-- them, so a row the tick did not judge is neither applied nor consumed, whatever pgpm_seq it carries.
--
-- And the junk such a role can write that NO reconcile can consume: a row whose control value is NULL (the
-- delta has no NOT NULL of its own). The swap gate's purge deleted `not (<ctl> in range)`, which is NULL for
-- it, so it was never purged, while the gate counted it: more of them than the batch held the regrain at
-- reconciling:N on every tick after the copy finished. The purge now deletes every row whose range test is
-- not TRUE, and logs regrain_delta_purge with how many.
--
-- Fixture, asymmetric: the INSERT-only role makes one real write in the completed sub-range (a new row 5,
-- captured by the trigger), forges two rows on one pgpm_seq (3, eligible; 18, not), and writes four rows with
-- a NULL key (more than the batch of 3 the run is driven at). The next tick must apply 5 and 3 and leave 18
-- and the four NULL rows in the delta; once the copy is done the next tick must purge the four (and nothing
-- else) and swap; the swap must keep 16 and 5. Every row is named, so a stray write and a lost one cannot
-- cancel.
-- bench/regrain_reconcile_judged_rows.sh runs this file against two mutants, one whose reconcile addresses the
-- batch by pgpm_seq again (regrain_reconcile_batch_by_seq) and one whose purge is blind to a NULL control
-- value again (regrain_delta_purge_null_blind), so it is also required to FAIL on each.
create extension if not exists pgtap;
select plan(17);

do $$ begin
  create role t291_inserter; exception when duplicate_object then null; end $$;

create table public.ev291 (id bigint primary key, payload text);
insert into public.ev291 select g, 'p' || g from generate_series(0, 98, 2) g;   -- even ids 0..98
call pgpm.transmute('public.ev291', 'id', 10, p_obtain => 3);
insert into public.ev291 values (125, 'frontier');                               -- freezes the monolith [0, 100)

grant usage on schema public to t291_inserter;
grant insert on public.ev291 to t291_inserter;                                   -- INSERT only: no DELETE, no UPDATE

create function pg_temp.src() returns name language sql as $$
  select child_name from pgpm.part where parent_table = 'public.ev291'::regclass and attached and lo = '0' $$;
-- the ids a not-yet-attached copy holds, by the oid pgpm.part recorded for it
create function pg_temp.copy_ids(p_lo text) returns bigint[] language plpgsql as $f$
declare v_rel regclass; v bigint[];
begin
  select child_oid::regclass into v_rel from pgpm.part
   where parent_table = 'public.ev291'::regclass and not attached and lo = p_lo;
  if v_rel is null then return null; end if;
  execute format('select array_agg(id order by id) from %s', v_rel) into v;
  return v;
end $f$;
-- the delta's rows, each as <id, or null>@<whether it carries the forged pgpm_seq>
create function pg_temp.delta_rows() returns text[] language plpgsql as $f$
declare v text[];
begin
  execute format('select array_agg(coalesce(id::text, ''null'') || ''@'' || (pgpm_seq = 1000000) order by id nulls last) from %s',
                 (select regrain_delta_oid::regclass from pgpm.config where parent_table = 'public.ev291'::regclass))
    into v;
  return v;
end $f$;
create function pg_temp.cursor() returns text language sql as $$
  select regrain_cursor from pgpm.config where parent_table = 'public.ev291'::regclass $$;

select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10'), 'prepared', 'fixture: capture is prepared');
select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3), 'copied:3', 'fixture: [0, 10) first batch (0, 2, 4)');
select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3), 'copied:2', 'fixture: [0, 10) complete (6, 8), cursor at 10');
select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3), 'copied:3', 'fixture: [10, 20) first batch (10, 12, 14)');
select ok(pg_temp.cursor() = '10' and pg_temp.copy_ids('10') = array[10, 12, 14]::bigint[],
  'LIVENESS: [10, 20) is part-copied (10, 12, 14 and not 16, 18) with the cursor at 10');

select regrain_delta_oid::regclass::text as t291_delta from pgpm.config where parent_table = 'public.ev291'::regclass \gset
select set_config('t291.delta', :'t291_delta', false) is not null as t291_set \gset
set role t291_inserter;
insert into public.ev291 values (5, 'new-5');                                   -- a real write, captured
do $$ begin
  execute format('insert into %s (id, pgpm_seq) overriding system value values (3, 1000000), (18, 1000000)',
                 current_setting('t291.delta'));
  execute format('insert into %s (id) select null from generate_series(1, 4)', current_setting('t291.delta'));
end $$;
reset role;

select is(pg_temp.delta_rows(), array['3@true', '5@false', '18@true', 'null@false', 'null@false', 'null@false', 'null@false'],
  'LIVENESS: the INSERT-only role wrote keys 3 and 18 on one pgpm_seq, and four NULL keys, beside the captured 5');

select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3), 'reconciled:2',
  'the next tick reconciles the two eligible keys (5 and 3)');
select is(pg_temp.delta_rows(), array['18@true', 'null@false', 'null@false', 'null@false', 'null@false'],
  'it consumed exactly the rows it judged: key 18, on the same pgpm_seq as 3, and the NULL keys are still in the delta');
select is(pg_temp.copy_ids('10'), array[10, 12, 14]::bigint[],
  'and wrote nothing into the part-copied sub-range [10, 20): 18 is not there ahead of 16');
select is(pg_temp.copy_ids('0'), array[0, 2, 4, 5, 6, 8]::bigint[],
  'while the captured write in the completed sub-range [0, 10) was applied (5 is there)');

-- drive the copy to its end, at the same batch of 3: every sub-range copied, the cursor at hi
do $$ declare i int := 0;
begin
  while pg_temp.cursor() <> '100' and i < 80 loop
    perform pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3);
    i := i + 1;
  end loop;
end $$;

select ok(pg_temp.cursor() = '100'
          and pg_temp.delta_rows() = array['null@false', 'null@false', 'null@false', 'null@false']
          and not exists (select 1 from pgpm.log where parent_table = 'public.ev291'::regclass and action = 'regrain_delta_purge'),
  'LIVENESS: the copy has finished (cursor at 100), 18 was reconciled, and the four NULL-key rows, more than the batch of 3, are all that is left in the delta, unpurged so far');

-- the next tick reconciles what it can, reaches the swap gate, and must swap
create temp table t291_gate as
  select pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3) as v;

select is((select v from t291_gate), 'swapped:10',
  'the tick after the copy swaps: the NULL-key rows no reconcile can consume do not hold the gate at reconciling:N');
select is((select array_agg(lo || '/' || hi || '/' || rows) from pgpm.log
            where parent_table = 'public.ev291'::regclass and action = 'regrain_delta_purge'),
  array['0/100/4'],
  'the purge discarded exactly the four NULL-key rows, once, logged as regrain_delta_purge over [0, 100)');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.ev291'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '100'),
  'LIVENESS: the regrain swapped [0, 100) into fine children');
select is((select array_agg(id order by id) from public.ev291 where id < 20),
  array[0, 2, 4, 5, 6, 8, 10, 12, 14, 16, 18]::bigint[],
  'after the swap every row below 20 is in the table: 16 was not dropped with the source, 5 was kept');
select is((select count(*)::int from pgpm.part where parent_table = 'public.ev291'::regclass and not attached), 0,
  'and no copy is left unattached');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.ev291'::regclass), null,
  'the run is over: the cursor is cleared');

select * from finish();

revoke all on public.ev291 from t291_inserter;
revoke usage on schema public from t291_inserter;
drop owned by t291_inserter;
drop role t291_inserter;
