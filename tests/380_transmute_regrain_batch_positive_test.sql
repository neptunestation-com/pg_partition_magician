-- transmute refuses a p_regrain_batch that is not positive, before anything is read or committed (issue #1243).
--
-- transmute asked its grid arguments' rules (_refuse_bad_transmute_arguments: p_obtain, the step, p_retain) and
-- not p_regrain_batch's, so 0 or a negative value was accepted and recorded in pgpm.config.regrain_batch, which no
-- setter changes afterwards, and regrain_step clamped it to greatest(1, batch): every auto-regrain tick then copied
-- one row, for good. It is refused now with the rest of the argument rules, whose helper the hypertable path asks
-- too (tests/timescale/db/58 holds from_hypertable's p_drain_batch, which it hands transmute, to the same rule).
--
-- WHAT THE HARNESS ALLOWS. transmute is a committing procedure wrapped by throws_like, and one that wrongly does
-- NOT refuse dies at its first COMMIT inside that function context with 2D000 and rolls back into the state a
-- refusal leaves, so the pinned message is what discriminates; the state check after it is an invariant.
-- ASYMMETRIC FIXTURES: the refused tables hold 250 and 120 rows, the converted one 170 and a batch of 7, so a
-- refusal that registered the wrong table, or a recording that clamped, shows.
-- bench/transmute_regrain_batch_positive.sh runs this file against the mutant that asks nothing of the batch again.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(6);

create table public.z380 (id bigint primary key, v int);
insert into public.z380 select g, g from generate_series(1, 250) g;
create table public.m380 (id bigint primary key, v int);
insert into public.m380 select g, g from generate_series(1, 120) g;
create table public.k380 (id bigint primary key, v int);
insert into public.k380 select g, g from generate_series(1, 170) g;

select throws_like(
  $$ call pgpm.transmute('public.z380', 'id', 100::bigint, p_obtain => 3, p_paused => false, p_regrain_batch => 0) $$,
  'pg_partition_magician: p_regrain_batch must be a positive integer (got 0)%',
  'transmute refuses p_regrain_batch => 0 up front, not by running into its first COMMIT');
select throws_like(
  $$ call pgpm.transmute('public.m380', 'id', 100::bigint, p_obtain => 3, p_paused => false, p_regrain_batch => -5) $$,
  'pg_partition_magician: p_regrain_batch must be a positive integer (got -5)%',
  'transmute refuses p_regrain_batch => -5 up front');
select throws_like(
  $$ call pgpm.transmute('public.k380', 'id', 100::bigint, p_obtain => -1) $$,
  'pg_partition_magician: p_obtain must be a non-negative integer (got -1)',
  'LIVENESS: the argument rules are asked where this call shape reaches them (p_obtain => -1 is refused)');
select is(
  (select string_agg(c.relname || ':' || c.relkind::text || ':'
                     || (select count(*) from pgpm.config f where f.parent_table = c.oid)
                     || (select count(*) from pgpm.transmute_inflight t where t.parent_table = c.oid)
                     || (select count(*) from pg_constraint k where k.conrelid = c.oid and k.conname = 'pgpm_monolith_bound'),
                     ',' order by c.relname)
     from pg_class c where c.oid in ('public.z380'::regclass, 'public.m380'::regclass)),
  'm380:r:000,z380:r:000',
  'invariant: neither refused table is registered, claimed or bounded');

call pgpm.transmute('public.k380', 'id', 100::bigint, p_obtain => 3, p_paused => false, p_regrain_batch => 7);
select is((select regrain_batch from pgpm.config where parent_table = 'public.k380'::regclass), 7,
  'LIVENESS: the same call with a positive batch converts and records it as given');
select is((select count(*)::int || ':' || min(id) || ':' || max(id) from public.k380), '170:1:170',
  'LIVENESS: the converted table holds its rows');

select * from finish();
