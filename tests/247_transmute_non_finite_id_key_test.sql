-- An id-kind transmute refuses a non-finite control value before anything is committed (issue #895).
--
-- A numeric control column can hold NaN, Infinity and -Infinity. The id branch of transmute's frontier
-- read took whatever ORDER BY ... DESC put first (NaN sorts above every number, then Infinity) as the
-- frontier, with no finiteness check where the time kind refuses infinity. Phase 1 committed a
-- pgpm_monolith_bound CHECK and a claim with hi = NaN, phase 2's VALIDATE failed raw, and after the
-- operator deleted the bad row the re-run resumed that recorded bound and completed a monolith [0, NaN)
-- named ..._to_0000000000000000NaN_N, which takes every future id, so obtain, retention and regrain never
-- acted on the table again. A -Infinity minimum is the same poison at the lower bound.
--
-- Fixtures, asymmetric on purpose, one per arm:
--   (A) NaN maximum: refused up front, nothing committed; the operator deletes the row and the re-run
--       converts with a finite monolith [0, 600) and forward partitions past it;
--   (B) Infinity maximum: refused the same way;
--   (C) -Infinity minimum under a finite maximum: refused by the minimum arm alone;
--   (D) control: a bigint column (which cannot hold a non-finite value) converts as before.
-- Each refusal is pinned by its message (throws_like): a committing procedure that does NOT refuse dies
-- at its first COMMIT inside pgTAP with 2D000, which an unpinned assertion would accept. Each is paired
-- with the state a refusal must leave (no bound, no claim, still a plain table, its rows intact) and with
-- a witness that the fixture really holds the non-finite value. Because pgTAP runs the refused call inside
-- a function, the pre-fix phase 1 rolls back here rather than committing; the operator's top-level
-- sequence that resumed the poisoned bound is the issue's reproduction, and the refusal pinned below is
-- what makes that state unreachable. bench/transmute_non_finite_id_key.sh runs this file against a
-- mutant that removes the refusal (transmute_id_frontier_non_finite), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(24);

-- (A) NaN maximum, then the operator's correction
create table public.t247_nan (id numeric primary key, v int);
insert into public.t247_nan select i, i from generate_series(1, 500) i;
insert into public.t247_nan values ('NaN', 0);
select oid as nan_oid from pg_class where oid = 'public.t247_nan'::regclass \gset
select is((select max(id)::text from public.t247_nan), 'NaN',
  'A LIVENESS: t247_nan''s greatest id is NaN');
select throws_like($$ call pgpm.transmute('public.t247_nan', 'id', 100::bigint, p_obtain => 2) $$,
  '%t247_nan cannot be partitioned on an id grid using id: it holds a non-finite value (its newest value is NaN, its oldest 1)%Delete or correct the rows whose id is NaN, Infinity or -Infinity and re-run.',
  'A: a NaN maximum is refused before anything is committed');
select is((select relkind::text from pg_class where oid = :nan_oid), 'r', 'A: t247_nan is still a plain table');
select ok(not exists (select 1 from pg_constraint where conrelid = :nan_oid and conname = 'pgpm_monolith_bound'),
  'A: no pgpm_monolith_bound was left on t247_nan');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table = :nan_oid::oid::regclass),
  'A: no claim was left for t247_nan');
select is((select array_agg(id::text order by id) from public.t247_nan where id > 498), array['499', '500', 'NaN'],
  'A: t247_nan still holds its top rows, the NaN one included');
delete from public.t247_nan where id = 'NaN';
call pgpm.transmute('public.t247_nan', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.t247_nan'::regclass), 'p',
  'A: the corrected re-run converted t247_nan');
select is((select lo || ',' || hi from pgpm.part where parent_table = 'public.t247_nan'::regclass and child_oid = :nan_oid),
  '0,600', 'A: the monolith (the original table) is [0, 600), the boundary above the data');
select is((select array_agg(lo || ',' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.t247_nan'::regclass and child_oid <> :nan_oid and attached),
  array['600,700', '700,800'],
  'A: and obtain built the forward partitions past it, which a NaN bound would have left nothing to build');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.t247_nan'::regclass
                       and (child_name like '%NaN%' or lo::numeric in ('NaN', 'Infinity', '-Infinity')
                            or hi::numeric in ('NaN', 'Infinity', '-Infinity'))),
  'A: no partition has a non-finite bound or is named for NaN');
select is((select array_agg(id order by id) from public.t247_nan where tableoid = :nan_oid and id in (1, 250, 500)),
  array[1, 250, 500]::numeric[], 'A: rows 1, 250 and 500 are in the monolith');
select lives_ok($$ insert into public.t247_nan values (650, 650) $$, 'A: a new id past the monolith is accepted');
select is((select c.relname::text from public.t247_nan t join pg_class c on c.oid = t.tableoid where t.id = 650),
  't247_nan_p0000000000000000600', 'A: and it lands in the forward partition [600, 700), not the monolith');

-- (B) Infinity maximum
create table public.t247_inf (id numeric primary key, v int);
insert into public.t247_inf values (3, 3), (40, 40), ('Infinity', 0);
select oid as inf_oid from pg_class where oid = 'public.t247_inf'::regclass \gset
select throws_like($$ call pgpm.transmute('public.t247_inf', 'id', 10::bigint, p_obtain => 2) $$,
  '%t247_inf cannot be partitioned on an id grid using id: it holds a non-finite value (its newest value is Infinity, its oldest 3)%',
  'B: an Infinity maximum is refused');
select ok(not exists (select 1 from pg_constraint where conrelid = :inf_oid and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = :inf_oid::oid::regclass),
  'B: no bound and no claim were left on t247_inf');
select is((select array_agg(id::text order by id) from public.t247_inf), array['3', '40', 'Infinity'],
  'B: t247_inf is still a plain table holding 3, 40 and Infinity');

-- (C) -Infinity minimum under a finite maximum
create table public.t247_neg (id numeric primary key, v int);
insert into public.t247_neg values ('-Infinity', 0), (7, 7), (21, 21), (35, 35);
select oid as neg_oid from pg_class where oid = 'public.t247_neg'::regclass \gset
select is((select max(id)::text from public.t247_neg), '35',
  'C LIVENESS: t247_neg''s greatest id is finite, so only the minimum is non-finite');
select throws_like($$ call pgpm.transmute('public.t247_neg', 'id', 10::bigint, p_obtain => 2) $$,
  '%t247_neg cannot be partitioned on an id grid using id: it holds a non-finite value (its newest value is 35, its oldest -Infinity)%',
  'C: a -Infinity minimum is refused');
select ok(not exists (select 1 from pg_constraint where conrelid = :neg_oid and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = :neg_oid::oid::regclass),
  'C: no bound and no claim were left on t247_neg');
select is((select array_agg(id::text order by id) from public.t247_neg), array['-Infinity', '7', '21', '35'],
  'C: t247_neg still holds its four rows');

-- (D) control: an integer column converts as before
create table public.t247_int (id bigint primary key, v int);
insert into public.t247_int values (12, 12), (130, 130);
select oid as int_oid from pg_class where oid = 'public.t247_int'::regclass \gset
call pgpm.transmute('public.t247_int', 'id', 50::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.t247_int'::regclass), 'p', 'D: t247_int converted');
select is((select lo || ',' || hi from pgpm.part where parent_table = 'public.t247_int'::regclass and child_oid = :int_oid),
  '0,150', 'D: its monolith is [0, 150), as before');

select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.config
            where parent_table::text like 't247\_%'),
  array['t247_int', 't247_nan'],
  'exactly the two converted tables are registered, and none of the refused ones');
select is((select count(*)::int from pgpm.log where parent_table in ('public.t247_nan'::regclass, 'public.t247_int'::regclass)
                                               and action = 'transmute'), 2,
  'A, D: each conversion logged its own transmute');

select * from finish();
