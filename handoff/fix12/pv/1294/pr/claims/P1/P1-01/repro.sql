-- P1-01: a parent holding a NOT VALID CHECK that NO row violates could be regrained before this change (the drift
-- check compared both sides by expression, and LIKE gave the copy the CHECK as a validated one, which matched).
-- On this tree _regrain_shape_drift leaves the parent's NOT VALID CHECK out on the parent's side, as the body
-- says, but _regrain_copy_make still makes every copy LIKE the parent INCLUDING CONSTRAINTS and drops nothing
-- after it (the hunk at 6554-6561 is comment only), so every copy holds the CHECK validated and reads as drift,
-- the probe copy _regrain_fresh_copy_drift makes holds it too, and the resumed tick is REFUSED ('a copy made
-- from the parent now would differ from it too') rather than restarted: regrain_history raises, and auto-regrain
-- logs skip_regrain on every tick with capture and the TRUNCATE refusal left on the source until regrain_cancel.
-- Fixture: two identical tables of 400 rows plus a frontier row; only p101b's parent gets the NOT VALID CHECK,
-- which no row violates. p101a is the liveness witness that the same shape regrains without it.
create extension if not exists pgtap;
select plan(8);

create table public.p101a (id bigint primary key, payload text);
create table public.p101b (id bigint primary key, payload text);
insert into public.p101a select g, 'x' from generate_series(1, 400) g;
insert into public.p101b select g, 'x' from generate_series(1, 400) g;
call pgpm.transmute('public.p101a', 'id', 1000);
call pgpm.transmute('public.p101b', 'id', 1000);
select pgpm.obtain('public.p101a');
select pgpm.obtain('public.p101b');
insert into public.p101a values (5000, 'frontier');
insert into public.p101b values (5000, 'frontier');
alter table public.p101b add constraint p101b_no_bad check (payload <> 'bad') not valid;

select is((select convalidated from pg_constraint
            where conrelid = 'public.p101b'::regclass and conname = 'p101b_no_bad'),
  false, 'LIVENESS: the parent carries the CHECK NOT VALID');
select is((select array_agg(id) from public.p101b where payload = 'bad'), null::bigint[],
  'LIVENESS: and no row of the table violates it');
select throws_ok($$ insert into public.p101b values (450, 'bad') $$, '23514', NULL,
  'LIVENESS: the CHECK refuses a new violating write before the regrain');
select is(pgpm.regrain_history('public.p101a', '100'), 10,
  'LIVENESS: the same table without the NOT VALID CHECK regrains [0, 1000) into 10 children');

-- THE DEFECT: the parent that carries a NOT VALID CHECK no row violates cannot be regrained on this tree
select lives_ok($$ select pgpm.regrain_history('public.p101b', '100') $$,
  'regrain_history of a parent holding a NOT VALID CHECK that no row violates completes');
select is((select array_agg(action || ':' || coalesce(method, '') order by id) from pgpm.log
            where parent_table = 'public.p101b'::regclass and action in ('regrain', 'regrain_restart')),
  array['regrain:copy_swap_drop'],
  'the run swapped [0, 1000) once, without a restart (its copies are not drift for want of the NOT VALID CHECK)');
select is((select string_agg(p.lo || ':' || t.id, ',' order by t.id)
             from public.p101b t join pgpm.part p on p.child_oid = t.tableoid and p.parent_table = 'public.p101b'::regclass
            where t.id in (1, 7, 342, 400, 5000)),
  '0:1,0:7,300:342,400:400,5000:5000',
  'rows 1, 7, 342, 400 and the frontier row are served, each by the fine child (or frontier partition) that holds it');
select is((select string_agg(p.lo || ':' || coalesce(k.convalidated::text, '-'), ',' order by p.lo::bigint)
             from pgpm.part p left join pg_constraint k on k.conrelid = p.child_oid and k.conname = 'p101b_no_bad'
            where p.parent_table = 'public.p101b'::regclass and p.attached and p.hi::bigint <= 1000),
  '0:false,100:false,200:false,300:false,400:false,500:false,600:false,700:false,800:false,900:false',
  'every fine child of [0, 1000) carries the parent''s CHECK NOT VALID');
select * from finish();
