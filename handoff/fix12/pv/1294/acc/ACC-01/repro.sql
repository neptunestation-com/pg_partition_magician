-- F3-03: a regrain copy is made `LIKE <parent> INCLUDING CONSTRAINTS` (_regrain_copy_make), and LIKE gives the
-- copy every CHECK of the parent as a VALIDATED constraint, a NOT VALID one included. A NOT VALID CHECK is how
-- a check is added to a large table without a scan, and it leaves the rows written before it in place, so
-- the copy refuses the first such row and every copy batch of the sub-range holding it fails: regrain() and
-- regrain_history() raise, and auto-regrain logs skip_regrain on every tick with capture and the TRUNCATE
-- refusal left on the monolith, until regrain_cancel. The parent's NOT VALID foreign keys are left off the
-- copy for exactly this reason (#633, "it enforces every row copied in and the copy would refuse that
-- orphan"); its NOT VALID CHECK constraints are not.
-- Fixture: two identical tables; only nv303b's parent gets a NOT VALID CHECK, which its row 7 violates.
create extension if not exists pgtap;
select plan(6);

create table public.nv303a (id bigint primary key, payload text);
create table public.nv303b (id bigint primary key, payload text);
insert into public.nv303a select g, case when g = 7 then 'bad' else 'x' end from generate_series(1, 100) g;
insert into public.nv303b select g, case when g = 7 then 'bad' else 'x' end from generate_series(1, 100) g;
call pgpm.transmute('public.nv303a', 'id', 1000);
call pgpm.transmute('public.nv303b', 'id', 1000);
select pgpm.obtain('public.nv303a');
select pgpm.obtain('public.nv303b');
insert into public.nv303a values (5000, 'frontier');
insert into public.nv303b values (5000, 'frontier');
alter table public.nv303b add constraint nv303b_no_bad check (payload <> 'bad') not valid;

select is((select convalidated from pg_constraint where conrelid = 'public.nv303b'::regclass and conname = 'nv303b_no_bad'),
  false, 'LIVENESS: (A) the parent carries the CHECK NOT VALID');
select is((select array_agg(id) from public.nv303b where payload = 'bad'), array[7]::bigint[],
  'LIVENESS: (A) and row 7, written before it, violates it and is served by the table');
select is(pgpm.regrain_history('public.nv303a', '100'), 10,
  'LIVENESS: (B) the same table without the NOT VALID CHECK regrains [0, 1000) into 10 children');

-- THE DEFECT: the table that carries the NOT VALID CHECK cannot be regrained at all
select lives_ok($$ select pgpm.regrain_history('public.nv303b', '100') $$,
  'regrain of a table whose parent has a NOT VALID CHECK that an old row violates completes');
select is((select array_agg(id order by id) from public.nv303b where id < 1000 and id in (6, 7, 8)), array[6, 7, 8]::bigint[],
  'every row is still served, row 7 among them');
select is((select count(*)::int from pgpm.log where parent_table = 'public.nv303b'::regclass
            and action = 'regrain' and method = 'copy_swap_drop'), 1,
  'the regrain swapped');
select * from finish();
