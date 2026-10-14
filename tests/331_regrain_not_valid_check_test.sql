-- Issue #1261 (review pass 12, F3-03): a regrain copies every row the parent serves, a row written before a
-- NOT VALID CHECK included, and the fine children carry that CHECK as the parent holds it, NOT VALID.
--
-- THE DEFECT. _regrain_copy_make made each copy `LIKE <parent> INCLUDING CONSTRAINTS`, and LIKE gives the copy
-- every CHECK of the parent as a VALIDATED one, a NOT VALID one included. A NOT VALID CHECK is how a check is
-- added to a large table without a scan, and it leaves the rows written before it in place, so the copy
-- refused the first such row: every copy batch of its sub-range failed 23514, regrain() and regrain_history()
-- raised, and auto-regrain logged skip_regrain on every tick with capture and the TRUNCATE refusal left on the
-- source, until regrain_cancel. #633 leaves the parent's NOT VALID foreign keys off the copy for exactly this
-- reason; its NOT VALID CHECKs were not. On PostgreSQL 18 a NOT VALID NOT NULL is the same case.
--
-- THE CONTRACT. The copy is made without the parent's enforced NOT VALID CHECK (and NOT NULL) constraints, the
-- swap adds each to the copy NOT VALID just before its ATTACH (the residual reconcile has written the copy's
-- last rows, so it checks none) and the ATTACH adopts it, and the drift check leaves them out on the parent's
-- side. A copy holding one VALIDATED (made while the parent's was) is drift, and restarts the run: it would
-- refuse a row the parent now accepts.
--
-- (A) the single-call path, regrain_history: two old violating rows in two sub-ranges are served by the fine
--     children that hold them, every fine child carries the CHECK NOT VALID, and it still refuses a new write.
-- (B) the cross-tick path, regrain_step, with the CHECK added mid-run: a copy made before it, a row made
--     violating through the reconcile before it, and one copied after it, all swapped without a restart.
-- (C) a copy made while the parent's CHECK was validated, which the parent then holds NOT VALID with a row
--     violating it: the run restarts, never reconciles that row into a copy that refuses it, and swaps.
-- (D) PostgreSQL 18: a NOT VALID NOT NULL, as (A).
-- bench/regrain_not_valid_check.sh runs this file against the mutants regrain_copy_validates_not_valid_check
-- and regrain_drift_excuses_validated_copy_check.
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(28);

-- the fine children of [0, 1000) of a parent, by pgpm.part, filtered by parent first (#973); the 100-wide ones
-- only, so that the source [0, 1000) never counts as one
create function pg_temp.fine(p_parent regclass) returns table (lo bigint, child_oid oid) language sql as $f$
  with mine as materialized (
    select p.lo, p.hi, p.child_oid from pgpm.part p where p.parent_table = p_parent and p.attached)
  select m.lo::bigint, m.child_oid from mine m
   where m.hi::bigint <= 1000 and m.hi::bigint - m.lo::bigint = 100 order by m.lo::bigint
$f$;
-- each fine child of [0, 1000) as lo:convalidated:conislocal of the named constraint on it ('-' when absent)
create function pg_temp.carried(p_parent regclass, p_con name) returns text language sql as $f$
  select string_agg(f.lo::text || ':' || coalesce((select k.convalidated::text || ':' || k.conislocal::text
                                                    from pg_constraint k
                                                   where k.conrelid = f.child_oid and k.conname = p_con), '-'),
                    ',' order by f.lo)
    from pg_temp.fine(p_parent) f
$f$;
-- which fine child serves each row a predicate selects, as lo:id
create function pg_temp.served(p_parent regclass, p_where text) returns text language plpgsql as $f$
declare v text;
begin
  execute format('select string_agg(f.lo::text || '':'' || t.id::text, '','' order by t.id)
                    from %s t join pg_temp.fine(%L) f on f.child_oid = t.tableoid where %s',
                 p_parent::text, p_parent::text, p_where) into v;
  return v;
end $f$;
create function pg_temp.mono(p_parent regclass) returns name language sql as $f$
  select child_name from pgpm.part where parent_table = p_parent and attached and lo = '0'
$f$;
-- one regrain_step tick of [0, 1000) toward 100, its result, or the SQLSTATE it died with (rolled back whole,
-- as a failed tick is), so that a tick that fails is recorded rather than ending the file
create function pg_temp.tick(p_parent regclass) returns text language plpgsql as $f$
begin
  return pgpm.regrain_step(p_parent, pg_temp.mono(p_parent), '100', 1000);
exception when others then
  return 'died:' || sqlstate;
end $f$;

-- ===================================== (A) regrain_history over a NOT VALID CHECK two old rows violate
create table public.nva331 (id bigint primary key, payload text);
insert into public.nva331 select g, case when g in (7, 342) then 'bad' else 'x' end from generate_series(1, 400) g;
call pgpm.transmute('public.nva331', 'id', 1000);
select pgpm.obtain('public.nva331');
insert into public.nva331 values (5000, 'frontier');
alter table public.nva331 add constraint nva331_no_bad check (payload <> 'bad') not valid;

select is((select convalidated from pg_constraint
            where conrelid = 'public.nva331'::regclass and conname = 'nva331_no_bad'),
  false, 'LIVENESS: (A) the parent carries the CHECK NOT VALID');
select is((select array_agg(id order by id) from public.nva331 where payload = 'bad'), array[7, 342]::bigint[],
  'LIVENESS: (A) rows 7 and 342, written before it, violate it and are served by the table');
select throws_ok($$ insert into public.nva331 values (450, 'bad') $$, '23514', NULL,
  'LIVENESS: (A) the CHECK refuses a new violating write before the regrain');

select lives_ok($$ select pgpm.regrain_history('public.nva331', '100') $$,
  '(A) regrain_history completes over the NOT VALID CHECK');
select is((select array_agg(method) from pgpm.log
            where parent_table = 'public.nva331'::regclass and action = 'regrain'),
  array['copy_swap_drop'], '(A) the regrain swapped [0, 1000) once');
select is(pg_temp.served('public.nva331', $$t.payload = 'bad'$$), '0:7,300:342',
  '(A) rows 7 and 342 are served, each by the fine child [0, 100) and [300, 400) that holds it');
select is((select array_agg(id order by id) from public.nva331),
  (select array_agg(g order by g) from (select generate_series(1, 400)::bigint as g union all select 5000) s),
  '(A) every row is served: 1 to 400 and the frontier row, no more and no fewer');
select is(pg_temp.carried('public.nva331', 'nva331_no_bad'),
  '0:false:false,100:false:false,200:false:false,300:false:false,400:false:false,'
  '500:false:false,600:false:false,700:false:false,800:false:false,900:false:false',
  '(A) every fine child carries the parent''s CHECK NOT VALID, inherited from it');
select throws_ok($$ insert into public.nva331 values (450, 'bad') $$, '23514', NULL,
  '(A) the fine child still refuses a new violating write');
select lives_ok($$ insert into public.nva331 values (451, 'fine') $$,
  '(A) and takes a new conforming one');
select is((select tableoid from public.nva331 where id = 451),
  (select child_oid from pg_temp.fine('public.nva331') where lo = 400),
  '(A) into the fine child [400, 500)');

-- ===================================== (B) regrain_step, the CHECK added mid-run
-- S0 [0, 100) is copied before the CHECK exists, row 150 is made violating after S1 [100, 200) was copied (so
-- only the reconcile carries it), row 650 is written violating in a sub-range not yet copied, and then the
-- CHECK is added NOT VALID. Rows 7 and 342 violate it from the start.
create table public.nvb331 (id bigint primary key, payload text);
insert into public.nvb331 select g, case when g in (7, 342) then 'bad' else 'x' end from generate_series(1, 400) g;
call pgpm.transmute('public.nvb331', 'id', 1000);
select pgpm.obtain('public.nvb331');
insert into public.nvb331 values (5000, 'frontier');
create temp table ticks (n serial, r text);
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
update public.nvb331 set payload = 'bad' where id = 150;
insert into public.nvb331 values (650, 'bad');
alter table public.nvb331 add constraint nvb331_no_bad check (payload <> 'bad') not valid;
select is((select string_agg(r, ',' order by n) from ticks), 'prepared,copied:99,copied:100',
  'LIVENESS: (B) S0 and S1 were copied before the CHECK was added');
select throws_ok($$ update public.nvb331 set payload = 'bad' where id = 151 $$, '23514', NULL,
  'LIVENESS: (B) the CHECK is enforced on the source mid-run');
truncate ticks;
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
insert into ticks (r) select pg_temp.tick('public.nvb331');
select is((select string_agg(r, ',' order by n) from ticks),
  'reconciled:2,copied:100,copied:100,copied:1,copied:0,copied:1,reconciled:1,copied:0,copied:0,copied:0,swapped:10',
  '(B) the run reconciles row 150, copies S2 to S9 (row 342''s and row 650''s sub-ranges among them) and swaps');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.nvb331'::regclass and action = 'regrain_restart'), 0,
  '(B) without a restart: the copies are not drift for want of the parent''s NOT VALID CHECK');
select is(pg_temp.served('public.nvb331', $$t.payload = 'bad'$$), '0:7,100:150,300:342,600:650',
  '(B) rows 7, 150 (by the reconcile), 342 and 650 are served, each by its own fine child');
select is(pg_temp.carried('public.nvb331', 'nvb331_no_bad'),
  '0:false:false,100:false:false,200:false:false,300:false:false,400:false:false,'
  '500:false:false,600:false:false,700:false:false,800:false:false,900:false:false',
  '(B) every fine child carries the CHECK NOT VALID, those copied before it was added included');
select throws_ok($$ insert into public.nvb331 values (450, 'bad') $$, '23514', NULL,
  '(B) the fine child refuses a new violating write');

-- ===================================== (C) a copy holding the CHECK validated, the parent's now NOT VALID
-- S0 is copied while the parent holds the CHECK validated, so its copy carries it validated. The CHECK is
-- dropped, row 55 is made violating (captured, for the reconcile to apply to S0's copy), and the CHECK comes
-- back NOT VALID. Reconciled into S0's copy, row 55 would fail it on every tick.
create table public.nvc331 (id bigint primary key, payload text);
insert into public.nvc331 select g, 'x' from generate_series(1, 400) g;
call pgpm.transmute('public.nvc331', 'id', 1000);
select pgpm.obtain('public.nvc331');
insert into public.nvc331 values (5000, 'frontier');
alter table public.nvc331 add constraint nvc331_no_bad check (payload <> 'bad');
truncate ticks;
insert into ticks (r) select pg_temp.tick('public.nvc331');
insert into ticks (r) select pg_temp.tick('public.nvc331');
select is(
  (select string_agg(t.r, ',' order by t.n) || ' ' || k.convalidated::text
     from ticks t, pg_constraint k
     join pgpm.part p on p.child_oid = k.conrelid and p.parent_table = 'public.nvc331'::regclass and not p.attached
    where k.conname = 'nvc331_no_bad'
    group by k.convalidated),
  'prepared,copied:99 true', 'LIVENESS: (C) S0''s copy was made carrying the CHECK validated');
alter table public.nvc331 drop constraint nvc331_no_bad;
update public.nvc331 set payload = 'bad' where id = 55;
alter table public.nvc331 add constraint nvc331_no_bad check (payload <> 'bad') not valid;
select lives_ok($$ select pgpm.regrain_history('public.nvc331', '100') $$,
  '(C) the run completes');
select is((select array_agg(action || ':' || coalesce(rows::text, '') order by id) from pgpm.log
            where parent_table = 'public.nvc331'::regclass and action in ('regrain_restart', 'regrain')),
  array['regrain_restart:1', 'regrain:10'],
  '(C) by restarting once, discarding S0''s copy, and then swapping');
select is(pg_temp.served('public.nvc331', $$t.payload = 'bad'$$), '0:55',
  '(C) row 55 is served by the fine child [0, 100), as the parent now accepts it');
select is(pg_temp.carried('public.nvc331', 'nvc331_no_bad'),
  '0:false:false,100:false:false,200:false:false,300:false:false,400:false:false,'
  '500:false:false,600:false:false,700:false:false,800:false:false,900:false:false',
  '(C) every fine child carries the CHECK NOT VALID');

-- ===================================== (D) PostgreSQL 18: a NOT VALID NOT NULL two old rows violate
create table public.nvd331 (id bigint primary key, payload text);
insert into public.nvd331 select g, case when g in (7, 342) then null else 'x' end from generate_series(1, 400) g;
call pgpm.transmute('public.nvd331', 'id', 1000);
select pgpm.obtain('public.nvd331');
insert into public.nvd331 values (5000, 'frontier');
create temp table v18 as select current_setting('server_version_num')::int >= 180000 as on18;
do $$
begin
  if (select on18 from v18) then
    execute 'alter table public.nvd331 add constraint nvd331_nn not null payload not valid';
  end if;
end $$;
select case when (select on18 from v18)
            then is((select contype::text || ':' || convalidated::text from pg_constraint
                      where conrelid = 'public.nvd331'::regclass and conname = 'nvd331_nn'),
                    'n:false', 'LIVENESS: (D) the parent carries the NOT NULL NOT VALID')
            else skip('(D) NOT NULL NOT VALID needs PostgreSQL 18', 1) end;
select lives_ok($$ select pgpm.regrain_history('public.nvd331', '100') $$,
  '(D) regrain_history completes over the NOT NULL NOT VALID');
select is(pg_temp.served('public.nvd331', 't.payload is null'), '0:7,300:342',
  '(D) rows 7 and 342 are served, each by the fine child that holds it');
select case when (select on18 from v18)
            then is(pg_temp.carried('public.nvd331', 'nvd331_nn'),
                    '0:false:false,100:false:false,200:false:false,300:false:false,400:false:false,'
                    '500:false:false,600:false:false,700:false:false,800:false:false,900:false:false',
                    '(D) every fine child carries the NOT NULL NOT VALID, inherited')
            else skip('(D) NOT NULL NOT VALID needs PostgreSQL 18', 1) end;
select case when (select on18 from v18)
            then throws_ok($$ insert into public.nvd331 values (450, null) $$, '23502', NULL,
                           '(D) the fine child refuses a new null')
            else skip('(D) NOT NULL NOT VALID needs PostgreSQL 18', 1) end;

select * from finish();
