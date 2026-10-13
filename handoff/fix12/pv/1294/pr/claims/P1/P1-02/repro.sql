-- P1-02: the defect of #1261 itself is still present on this tree. _regrain_copy_make makes each copy LIKE the
-- parent INCLUDING CONSTRAINTS and nothing after the LIKE drops the parent's NOT VALID CHECK from the copy (the
-- hunk at 6554-6561 adds only the comment that says it does), so the copy holds the CHECK validated and refuses
-- the first row written before it that the parent still serves: the copy batch fails 23514, regrain_history
-- raises, and auto-regrain logs skip_regrain every tick with capture and the TRUNCATE refusal left on the source
-- until regrain_cancel. The swap's pre-ATTACH add and the drift check's parent-side exclusion are present but
-- never reached. Fixture: two identical tables; only p102b's parent gets the NOT VALID CHECK, which rows 7 and
-- 342 (two sub-ranges) violate. p102a is the liveness witness that the same shape regrains without it.
create extension if not exists pgtap;
select plan(8);

create table public.p102a (id bigint primary key, payload text);
create table public.p102b (id bigint primary key, payload text);
insert into public.p102a select g, case when g in (7, 342) then 'bad' else 'x' end from generate_series(1, 400) g;
insert into public.p102b select g, case when g in (7, 342) then 'bad' else 'x' end from generate_series(1, 400) g;
call pgpm.transmute('public.p102a', 'id', 1000);
call pgpm.transmute('public.p102b', 'id', 1000);
select pgpm.obtain('public.p102a');
select pgpm.obtain('public.p102b');
insert into public.p102a values (5000, 'frontier');
insert into public.p102b values (5000, 'frontier');
alter table public.p102b add constraint p102b_no_bad check (payload <> 'bad') not valid;

select is((select convalidated from pg_constraint
            where conrelid = 'public.p102b'::regclass and conname = 'p102b_no_bad'),
  false, 'LIVENESS: the parent carries the CHECK NOT VALID');
select is((select array_agg(id order by id) from public.p102b where payload = 'bad'), array[7, 342]::bigint[],
  'LIVENESS: rows 7 and 342, written before it, violate it and are served by the table');
select throws_ok($$ insert into public.p102b values (450, 'bad') $$, '23514', NULL,
  'LIVENESS: the CHECK refuses a new violating write before the regrain');
select is(pgpm.regrain_history('public.p102a', '100'), 10,
  'LIVENESS: the same table without the NOT VALID CHECK regrains [0, 1000) into 10 children');

-- THE DEFECT: the parent whose NOT VALID CHECK two old rows violate cannot be regrained
select lives_ok($$ select pgpm.regrain_history('public.p102b', '100') $$,
  'regrain_history of a parent holding a NOT VALID CHECK that old rows violate completes');
select is((select array_agg(action || ':' || coalesce(method, '') order by id) from pgpm.log
            where parent_table = 'public.p102b'::regclass and action in ('regrain', 'regrain_restart')),
  array['regrain:copy_swap_drop'],
  'the run swapped [0, 1000) once');
select is((select string_agg(p.lo || ':' || t.id, ',' order by t.id)
             from public.p102b t join pgpm.part p on p.child_oid = t.tableoid and p.parent_table = 'public.p102b'::regclass
            where t.payload = 'bad' or t.id in (6, 8, 5000)),
  '0:6,0:7,0:8,300:342,5000:5000',
  'rows 7 and 342 are still served, each by the fine child [0, 100) and [300, 400) that holds it, beside 6, 8 and the frontier row');
select is((select string_agg(p.lo || ':' || coalesce(k.convalidated::text, '-'), ',' order by p.lo::bigint)
             from pgpm.part p left join pg_constraint k on k.conrelid = p.child_oid and k.conname = 'p102b_no_bad'
            where p.parent_table = 'public.p102b'::regclass and p.attached and p.hi::bigint <= 1000),
  '0:false,100:false,200:false,300:false,400:false,500:false,600:false,700:false,800:false,900:false',
  'every fine child of [0, 1000) carries the parent''s CHECK NOT VALID');
select * from finish();
