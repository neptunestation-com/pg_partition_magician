-- from_hypertable and from_hypertable_cutover ask transmute's argument rules before anything is changed
-- (issues #1085 and #966 W2). The cutover hands the plain table to transmute only after its swap has
-- committed, and nothing in the module asked the three rules transmute applies to its arguments alone, so
-- each was refused only at the handoff, with the hypertable already dropped and a plain, unmanaged table left
-- under its name:
--   p_retain  negative                     "p_retain cannot be negative" (#451)
--   p_obtain  negative                     "p_obtain must be a non-negative integer" (#581)
--   p_interval zero or negative            "the partition step must be positive" (#581)
-- A negative p_interval was worse: the first thing to notice it was the frontier check (#792), whose limit
-- now() + step + 1 hour then lies in the past, so it refused with a remedy that said to delete the newest
-- day of rows, or to pass p_force_frontier, which committed the swap and met the step refusal after it.
-- Now one rule, pgpm._refuse_bad_transmute_arguments, which transmute itself asks, is asked by from_hypertable
-- before its copy and by from_hypertable_cutover before its pre-drain, each through
-- pgpm._from_hypertable_check_arguments, ahead of every check that reads the table.
--
-- WHAT THE HARNESS ALLOWS. Every refused call is a committing procedure wrapped by throws_like, and one that
-- wrongly does NOT refuse dies at its first COMMIT inside that function context with 2D000 (the copy's, or
-- with p_predrain => false the swap's) and rolls back into the state a refusal leaves. So the pinned
-- messages, anchored at the start so the frontier refusal's text cannot match them, are the discriminating
-- assertions; the state checks after them are invariants, marked so.
--
-- ASYMMETRIC FIXTURES. a58 (three rows, 10, 20 and 30, the newest an hour old) goes through the one-shot
-- driver; b58 (two rows, 7 and 8) through the two phases, so a refusal that left one table's state in the
-- other's place would show. WITNESSES: transmute refuses each argument on a plain table with the same
-- message, so the module asks transmute's rules and not new ones; the frontier check, asked first, would
-- refuse a58 with the delete-the-rows remedy; and the same calls with good arguments migrate both tables.
select plan(22);

create table public.a58 (ts timestamptz not null, v int);
select create_hypertable('public.a58', 'ts', chunk_time_interval => interval '1 day');
insert into public.a58 values
  (now() - interval '2 days', 10), (now() - interval '20 hours', 20), (now() - interval '1 hour', 30);
create table public.b58 (ts timestamptz not null, v int);
select create_hypertable('public.b58', 'ts', chunk_time_interval => interval '1 day');
insert into public.b58 values (now() - interval '3 days', 7), (now() - interval '2 hours', 8);
create table public.p58 (ts timestamptz not null, v int);
insert into public.p58 values (now() - interval '1 hour', 1);

-- ================================ the rules are transmute's ================================
select throws_like(
  $$ call pgpm.transmute('public.p58', 'ts', interval '1 day', p_retain => interval '-1 day') $$,
  'pg_partition_magician: p_retain cannot be negative (got -1 days)%',
  'WITNESS: transmute refuses a negative p_retain on a plain table');
select throws_like(
  $$ call pgpm.transmute('public.p58', 'ts', interval '1 day', p_obtain => -1) $$,
  'pg_partition_magician: p_obtain must be a non-negative integer (got -1)',
  'WITNESS: transmute refuses a negative p_obtain on a plain table');
select throws_like(
  $$ call pgpm.transmute('public.p58', 'ts', interval '0') $$,
  'pg_partition_magician: the partition step must be positive (got 00:00:00)%',
  'WITNESS: transmute refuses a zero step on a plain table');
select throws_like(
  $$ select pgpm._from_hypertable_check_frontier('public.a58', 'ts', interval '-1 day', false) $$,
  'pg_partition_magician: cannot migrate hypertable a58 with p_interval -1 days -- %Delete or correct the rows whose ts is after %',
  'WITNESS: asked of a negative step, the frontier check would refuse a58 telling the operator to delete rows');

-- ================================ A: the one-shot driver, before its copy ================================
select throws_like(
  $$ call pgpm.from_hypertable('public.a58', 'ts', interval '1 day', p_retain => interval '-1 day') $$,
  'pg_partition_magician: p_retain cannot be negative (got -1 days)%',
  'from_hypertable refuses a negative p_retain before its copy');
select throws_like(
  $$ call pgpm.from_hypertable('public.a58', 'ts', interval '1 day', p_obtain => -1) $$,
  'pg_partition_magician: p_obtain must be a non-negative integer (got -1)',
  'from_hypertable refuses a negative p_obtain before its copy');
select throws_like(
  $$ call pgpm.from_hypertable('public.a58', 'ts', interval '0') $$,
  'pg_partition_magician: the partition step must be positive (got 00:00:00)%',
  'from_hypertable refuses a zero p_interval before its copy');
select throws_like(
  $$ call pgpm.from_hypertable('public.a58', 'ts', interval '-1 day') $$,
  'pg_partition_magician: the partition step must be positive (got -1 days)%',
  'from_hypertable refuses a negative p_interval as a step, not as a frontier with rows to delete');
select throws_like(
  $$ call pgpm.from_hypertable('public.a58', 'ts', interval '-1 day', p_force_frontier => true) $$,
  'pg_partition_magician: the partition step must be positive (got -1 days)%',
  'from_hypertable refuses a negative p_interval with p_force_frontier too');
select throws_like(
  $$ call pgpm.from_hypertable('public.a58', 'ts', interval '1 mon -40 days') $$,
  'pg_partition_magician: cannot migrate hypertable a58 with p_interval 1 mon -40 days -- %',
  'a step transmute reads as positive (a whole month first) is not refused as a step: the rule is transmute''s');
select is(
  (select count(*) from timescaledb_information.hypertables where hypertable_name = 'a58')
  || '/' || (select count(*) from pgpm.config where parent_table::text = 'a58')
  || '/' || (select count(*) from pgpm.scratch where parent_oid = 'public.a58'::regclass::oid)
  || '/' || (select string_agg(v::text, ',' order by v) from public.a58),
  '1/0/0/10,20,30', 'invariant: a58 is still a hypertable, unregistered, with no copy recorded, holding 10,20,30');

-- ================================ B: the cutover, before its pre-drain ================================
call pgpm.from_hypertable_copy('public.b58', 'ts');
select is(
  (select string_agg(v::text, ',' order by v) from public.b58_pgpm_dest)
  || '/' || (pgpm._from_hypertable_scratch('public.b58', 'hypertable_dest') is not null)::text,
  '7,8/true', 'LIVENESS: the copy ran, holds 7,8 and is recorded');
-- p_predrain => false, so nothing commits ahead of the swap for an unrelated reason: a cutover that does not
-- refuse dies on the swap's COMMIT inside throws_like, which its pinned message tells apart.
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.b58', 'ts', interval '1 day', p_retain => interval '-1 day', p_predrain => false) $$,
  'pg_partition_magician: p_retain cannot be negative (got -1 days)%',
  'from_hypertable_cutover refuses a negative p_retain before the swap');
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.b58', 'ts', interval '1 day', p_obtain => -1, p_predrain => false) $$,
  'pg_partition_magician: p_obtain must be a non-negative integer (got -1)',
  'from_hypertable_cutover refuses a negative p_obtain before the swap');
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.b58', 'ts', interval '0', p_predrain => false) $$,
  'pg_partition_magician: the partition step must be positive (got 00:00:00)%',
  'from_hypertable_cutover refuses a zero p_interval before the swap');
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.b58', 'ts', interval '-1 day', p_predrain => false, p_force_frontier => true) $$,
  'pg_partition_magician: the partition step must be positive (got -1 days)%',
  'from_hypertable_cutover refuses a negative p_interval before the swap, p_force_frontier or not');
-- the pre-drain is the cutover's first COMMIT: the refusal comes before it too
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.b58', 'ts', interval '1 day', p_obtain => -1) $$,
  'pg_partition_magician: p_obtain must be a non-negative integer (got -1)',
  'from_hypertable_cutover refuses a negative p_obtain before its pre-drain');
select is(
  (select count(*) from timescaledb_information.hypertables where hypertable_name = 'b58')
  || '/' || (select count(*) from pgpm.config where parent_table::text = 'b58')
  || '/' || (select string_agg(v::text, ',' order by v) from public.b58)
  || '/' || (select string_agg(v::text, ',' order by v) from public.b58_pgpm_dest),
  '1/0/7,8/7,8', 'invariant: b58 is still a hypertable, unregistered, holding 7,8, its copy in place');

-- ================================ LIVENESS: good arguments migrate both ================================
call pgpm.from_hypertable_cutover('public.b58', 'ts', interval '1 day', p_obtain => 2,
                                  p_retain => interval '30 days', p_paused => false);
select is(
  (select relkind::text from pg_class where oid = 'public.b58'::regclass)
  || '/' || (select obtain || ':' || retain from pgpm.config where parent_table = 'public.b58'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.b58),
  'p/2:30 days/7,8', 'LIVENESS: the cutover with good arguments migrates b58, its knobs and rows by value');
call pgpm.from_hypertable('public.a58', 'ts', interval '1 day', p_obtain => 0, p_retain => interval '0',
                          p_paused => false);
select is(
  (select relkind::text from pg_class where oid = 'public.a58'::regclass)
  || '/' || (select obtain || ':' || retain from pgpm.config where parent_table = 'public.a58'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.a58),
  'p/0:00:00:00/10,20,30', 'LIVENESS: from_hypertable with the boundary values (obtain 0, retain 0) migrates a58');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name in ('a58', 'b58')), 0,
  'LIVENESS: neither table is a hypertable any more');
select is((select count(*)::int from pgpm.scratch where parent_oid in ('public.a58'::regclass::oid, 'public.b58'::regclass::oid)), 0,
  'LIVENESS: and no scratch record is left for either');

select * from finish();
