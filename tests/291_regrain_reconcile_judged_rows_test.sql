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
-- Fixture, asymmetric: the INSERT-only role makes one real write in the completed sub-range (a new row 5,
-- captured by the trigger) and forges two rows on one pgpm_seq (3, eligible; 18, not). The next tick must
-- apply 5 and 3 and leave 18 in the delta; the swap must keep 16 and 5. Every row is named, so a stray write
-- and a lost one cannot cancel.
-- bench/regrain_reconcile_judged_rows.sh runs this file against a mutant whose reconcile addresses the batch by
-- pgpm_seq again (regrain_reconcile_batch_by_seq), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(12);

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
-- the delta's rows, each as <id>@<whether it carries the forged pgpm_seq>
create function pg_temp.delta_rows() returns text[] language plpgsql as $f$
declare v text[];
begin
  execute format('select array_agg(id || ''@'' || (pgpm_seq = 1000000) order by id) from %s',
                 (select regrain_delta_oid::regclass from pgpm.config where parent_table = 'public.ev291'::regclass))
    into v;
  return v;
end $f$;

select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10'), 'prepared', 'fixture: capture is prepared');
select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3), 'copied:3', 'fixture: [0, 10) first batch (0, 2, 4)');
select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3), 'copied:2', 'fixture: [0, 10) complete (6, 8), cursor at 10');
select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3), 'copied:3', 'fixture: [10, 20) first batch (10, 12, 14)');
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.ev291'::regclass) = '10'
          and pg_temp.copy_ids('10') = array[10, 12, 14]::bigint[],
  'LIVENESS: [10, 20) is part-copied (10, 12, 14 and not 16, 18) with the cursor at 10');

select regrain_delta_oid::regclass::text as t291_delta from pgpm.config where parent_table = 'public.ev291'::regclass \gset
select set_config('t291.delta', :'t291_delta', false) is not null as t291_set \gset
set role t291_inserter;
insert into public.ev291 values (5, 'new-5');                                   -- a real write, captured
do $$ begin
  execute format('insert into %s (id, pgpm_seq) overriding system value values (3, 1000000), (18, 1000000)',
                 current_setting('t291.delta'));
end $$;
reset role;

select is(pg_temp.delta_rows(), array['3@true', '5@false', '18@true'],
  'LIVENESS: the INSERT-only role wrote keys 3 and 18 on one pgpm_seq beside the captured 5');

select is(pgpm.regrain_step('public.ev291', pg_temp.src(), '10', 3), 'reconciled:2',
  'the next tick reconciles the two eligible keys (5 and 3)');
select is(pg_temp.delta_rows(), array['18@true'],
  'it consumed exactly the rows it judged: key 18, on the same pgpm_seq as 3, is still in the delta');
select is(pg_temp.copy_ids('10'), array[10, 12, 14]::bigint[],
  'and wrote nothing into the part-copied sub-range [10, 20): 18 is not there ahead of 16');
select is(pg_temp.copy_ids('0'), array[0, 2, 4, 5, 6, 8]::bigint[],
  'while the captured write in the completed sub-range [0, 10) was applied (5 is there)');

-- drive the run to its swap
do $$ declare v text; i int := 0;
begin
  loop
    v := pgpm.regrain_step('public.ev291', pg_temp.src(), '10');
    exit when v like 'swapped:%' or i > 40;
    i := i + 1;
  end loop;
end $$;

select ok(exists (select 1 from pgpm.log where parent_table = 'public.ev291'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '100'),
  'LIVENESS: the regrain swapped [0, 100) into fine children');
select is((select array_agg(id order by id) from public.ev291 where id < 20),
  array[0, 2, 4, 5, 6, 8, 10, 12, 14, 16, 18]::bigint[],
  'after the swap every row below 20 is in the table: 16 was not dropped with the source, 5 was kept');

select * from finish();

revoke all on public.ev291 from t291_inserter;
revoke usage on schema public from t291_inserter;
drop owned by t291_inserter;
drop role t291_inserter;
