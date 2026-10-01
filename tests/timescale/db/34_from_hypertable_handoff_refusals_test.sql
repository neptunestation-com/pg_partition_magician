-- from_hypertable dropped the hypertable for a table transmute was always going to refuse (issue #792). The
-- cutover hands the plain table to transmute only after its swap has committed, and its pre-swap checks
-- (the preflight, _from_hypertable_check_handoff) did not ask two of transmute's refusals, both visible on
-- the source before anything changes:
--   A. a key that is a bare UNIQUE INDEX (TimescaleDB's documented way to add one), which transmute will
--      not adopt as a key (pgpm.transmute's "is a bare index, not a constraint");
--   B. a newest row further ahead of now() than one step plus an hour (#457), which transmute refuses
--      unless p_force_frontier, a parameter from_hypertable did not have to pass through.
-- Either way the hypertable was dropped, transmute refused, and the table was left plain and unmanaged. Both
-- are now asked before the swap, sharing transmute's own rule (pgpm._transmute_bare_unique,
-- pgpm._frontier_skew_limit): the key by the preflight (so by from_hypertable and from_hypertable_copy before
-- the copy), the frontier by from_hypertable before the copy, and both by the cutover under its lock. And
-- from_hypertable and from_hypertable_cutover take p_force_frontier and pass it to transmute.
--
-- WHAT THE HARNESS ALLOWS. Every refused call is a committing procedure wrapped by throws_like, and one that
-- wrongly does NOT refuse dies at its first COMMIT inside that function context with 2D000 and rolls back
-- into the state a refusal leaves. So the pinned messages are the discriminating assertions; the state
-- checks after them are invariants, marked so.
--
-- ASYMMETRIC FIXTURES. A: the bare unique index sits beside a NON-unique index on the same columns'
-- prefix, which is carried as before and must not be named; the remedy makes the key a constraint and the
-- table migrates. B: three rows, one of them 30 days ahead, and a second hypertable with a far-future row
-- migrated through the one-shot driver with p_force_frontier, so both entry points' pass-through are seen.
-- WITNESSES: transmute itself refuses each shape on a plain table, so the up-front refusals are transmute's
-- questions and not new ones; and each remedy (or the override) migrates the same table.
select plan(26);

-- ================================ A: a bare unique index as the key ================================
create table public.hbu34 (device_id int not null, ts timestamptz not null, v int);
select create_hypertable('public.hbu34', 'ts', chunk_time_interval => interval '1 day');
create unique index hbu34_dev_ts on public.hbu34 (device_id, ts);
create index hbu34_dev on public.hbu34 (device_id);
insert into public.hbu34 values
  (1, now() - interval '2 days', 10), (2, now() - interval '1 day', 20), (3, now() - interval '1 hour', 30);
create table public.pbu34 (device_id int not null, ts timestamptz not null, v int);
create unique index pbu34_dev_ts on public.pbu34 (device_id, ts);
insert into public.pbu34 values (1, now() - interval '1 hour', 10);

select is(
  (select string_agg(c.relname || ':' || i.indisunique::text || ':'
                     || exists (select 1 from pg_constraint k where k.conindid = i.indexrelid)::text, ',' order by c.relname)
     from pg_index i join pg_class c on c.oid = i.indexrelid where i.indrelid = 'public.hbu34'::regclass),
  'hbu34_dev:false:false,hbu34_dev_ts:true:false,hbu34_ts_idx:false:false',
  'WITNESS: hbu34 is keyed only by a bare unique index (no primary key, no unique constraint)');
select throws_like(
  $$ call pgpm.transmute('public.pbu34', 'ts', interval '1 day') $$,
  '%the unique index pbu34_dev_ts includes the control column but is a bare index, not a constraint%',
  'WITNESS: transmute refuses the same shape on a plain table');

select throws_like(
  $$ select pgpm.from_hypertable_preflight('public.hbu34', 'ts') $$,
  'pg_partition_magician: cannot migrate hypertable hbu34 -- refused before anything is changed, because transmute, which takes the table over once the cutover''s swap has committed, would refuse it: the unique index hbu34_dev_ts includes the control column % but is a bare index, not a constraint%ALTER TABLE hbu34 ADD CONSTRAINT hbu34_dev_ts_key UNIQUE (device_id, ts)%DROP INDEX hbu34_dev_ts%',
  'preflight refuses the bare unique index by name, with the hypertable''s remedy');
select throws_like(
  $$ call pgpm.from_hypertable('public.hbu34', 'ts', interval '1 day') $$,
  'pg_partition_magician: cannot migrate hypertable hbu34 -- refused before anything is changed%the unique index hbu34_dev_ts %bare index%',
  'from_hypertable refuses it before its copy');
select throws_like(
  $$ call pgpm.from_hypertable_copy('public.hbu34', 'ts') $$,
  'pg_partition_magician: cannot migrate hypertable hbu34 -- refused before anything is changed%the unique index hbu34_dev_ts %bare index%',
  'from_hypertable_copy refuses it before creating anything');
select is(to_regclass('public.hbu34_pgpm_dest'), null::regclass,
  'invariant: no destination was left behind by the refused calls');
-- The cutover is the irreversible step and does not run the preflight, so it asks for itself: a destination
-- from an older version's copy (made by hand here, as tests/timescale/db/26 does) reaches it directly.
-- p_predrain => false, so nothing commits ahead of the check for an unrelated reason.
create table public.hbu34_pgpm_dest (like public.hbu34 including defaults including constraints including generated including comments);
insert into public.hbu34_pgpm_dest select * from public.hbu34;
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.hbu34', 'ts', interval '1 day', p_predrain => false) $$,
  'pg_partition_magician: cannot migrate hypertable hbu34 -- refused before anything is changed%the unique index hbu34_dev_ts %bare index%',
  'from_hypertable_cutover refuses it in its own right, under its lock, with a destination in place');
drop table public.hbu34_pgpm_dest;
select is(
  (select count(*) from timescaledb_information.hypertables where hypertable_name = 'hbu34')
  || '/' || (select count(*) from pgpm.config where parent_table::text = 'hbu34')
  || '/' || (select string_agg(v::text, ',' order by v) from public.hbu34),
  '1/0/10,20,30', 'invariant: hbu34 is still a hypertable, unregistered, holding 10,20,30');

-- LIVENESS: the remedy the message names migrates the same table, so the bare index was the only obstacle.
alter table public.hbu34 add constraint hbu34_dev_ts_key unique (device_id, ts);
drop index public.hbu34_dev_ts;
select lives_ok($$ select pgpm.from_hypertable_preflight('public.hbu34', 'ts') $$,
  'LIVENESS: with the key a constraint, preflight accepts the table');
call pgpm.from_hypertable('public.hbu34', 'ts', interval '1 day', p_paused => false);
select is(
  (select relkind::text from pg_class where oid = 'public.hbu34'::regclass)
  || '/' || (select count(*) from pgpm.config where parent_table = 'public.hbu34'::regclass)
  || '/' || (select string_agg(device_id || ':' || v, ',' order by v) from public.hbu34),
  'p/1/1:10,2:20,3:30', 'LIVENESS: then from_hypertable migrates it, every row by value');
select is(
  (select string_agg(pg_get_constraintdef(oid), ',') from pg_constraint
    where conrelid = 'public.hbu34'::regclass and contype in ('p', 'u')),
  'UNIQUE (device_id, ts)', 'LIVENESS: with the unique constraint as its key');

-- ================================ B: a newest row far ahead of the clock ================================
create table public.hfu34 (ts timestamptz not null, v int);
select create_hypertable('public.hfu34', 'ts', chunk_time_interval => interval '1 day');
insert into public.hfu34 values
  (now() - interval '2 days', 10), (now() - interval '1 hour', 20), (now() + interval '30 days', 30);
create table public.pfu34 (ts timestamptz not null, v int);
insert into public.pfu34 values (now() - interval '1 hour', 20), (now() + interval '30 days', 30);

select is(
  (select string_agg(v::text, ',' order by v) from public.hfu34)
  || '/' || (select max(ts) > now() + interval '29 days' from public.hfu34)::text,
  '10,20,30/true', 'WITNESS: hfu34 holds 10,20,30, the newest 30 days ahead of now()');
select throws_like(
  $$ call pgpm.transmute('public.pfu34', 'ts', interval '1 day') $$,
  '%its newest value is %, which is % ahead of now()%p_force_frontier => true%',
  'WITNESS: transmute refuses the same frontier on a plain table');

select throws_like(
  $$ call pgpm.from_hypertable('public.hfu34', 'ts', interval '1 day') $$,
  'pg_partition_magician: cannot migrate hypertable hfu34 with p_interval 1 day -- refused before anything is changed, because transmute, which takes the table over once the cutover''s swap has committed, would refuse it: its newest ts is %, which is % ahead of now() (%), more than one step plus one hour (the most the newest row may lead the clock by, so after %)%p_force_frontier => true%',
  'from_hypertable refuses the frontier before its copy, naming the override');
select is(to_regclass('public.hfu34_pgpm_dest'), null::regclass,
  'invariant: and left no destination behind (the refusal came before the copy)');

-- The two-phase flow: the copy does not know p_interval, so it cannot ask; the cutover does, up front.
call pgpm.from_hypertable_copy('public.hfu34', 'ts');
select is((select string_agg(v::text, ',' order by v) from public.hfu34_pgpm_dest), '10,20,30',
  'LIVENESS: the copy ran and holds the three rows');
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.hfu34', 'ts', interval '1 day', p_predrain => false) $$,
  'pg_partition_magician: cannot migrate hypertable hfu34 with p_interval 1 day -- refused before anything is changed%its newest ts is %ahead of now()%p_force_frontier => true%',
  'from_hypertable_cutover refuses the frontier before the swap (under its lock)');
select is(
  (select count(*) from timescaledb_information.hypertables where hypertable_name = 'hfu34')
  || '/' || (select count(*) from pgpm.config where parent_table::text = 'hfu34')
  || '/' || (select string_agg(v::text, ',' order by v) from public.hfu34)
  || '/' || (to_regclass('public.hfu34_pgpm_dest') is not null)::text,
  '1/0/10,20,30/true', 'invariant: hfu34 is still a hypertable, unregistered, whole, its copy in place');

-- The override, through the cutover: accepted up front and passed to transmute, which takes the bound.
call pgpm.from_hypertable_cutover('public.hfu34', 'ts', interval '1 day', p_paused => false, p_force_frontier => true);
select is(
  (select relkind::text from pg_class where oid = 'public.hfu34'::regclass)
  || '/' || (select count(*) from pgpm.config where parent_table = 'public.hfu34'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.hfu34),
  'p/1/10,20,30', 'with p_force_frontier the cutover migrates hfu34, every row by value');
select is(
  (select string_agg(x, ';') from (select string_agg(v::text, ',' order by v) as x from public.hfu34 group by tableoid) g),
  '10,20,30', 'and all three rows sit in the monolith, whose upper bound p_force_frontier let lie past the far-future row');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hfu34'), 0,
  'LIVENESS: hfu34 is no longer a hypertable');

-- The override, through the one-shot driver, on a second table.
create table public.hff34 (ts timestamptz not null, v int);
select create_hypertable('public.hff34', 'ts', chunk_time_interval => interval '1 day');
insert into public.hff34 values (now() - interval '3 hours', 7), (now() + interval '10 days', 8);
select throws_like(
  $$ call pgpm.from_hypertable('public.hff34', 'ts', interval '1 day') $$,
  '%cannot migrate hypertable hff34 with p_interval 1 day -- refused before anything is changed%ahead of now()%',
  'WITNESS: without the override from_hypertable refuses hff34 too');
call pgpm.from_hypertable('public.hff34', 'ts', interval '1 day', p_paused => false, p_force_frontier => true);
select is(
  (select relkind::text from pg_class where oid = 'public.hff34'::regclass)
  || '/' || (select count(*) from pgpm.config where parent_table = 'public.hff34'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.hff34),
  'p/1/7,8', 'with p_force_frontier from_hypertable migrates hff34, both rows by value');

-- A newest row INSIDE the allowance is not refused: the check is transmute's bound, not a stricter one.
create table public.hok34 (ts timestamptz not null, v int);
select create_hypertable('public.hok34', 'ts', chunk_time_interval => interval '1 day');
insert into public.hok34 values (now() - interval '1 day', 1), (now() + interval '20 hours', 2);
select lives_ok($$ select pgpm._from_hypertable_check_frontier('public.hok34', 'ts', interval '1 day', false) $$,
  'a newest row 20 hours ahead on a daily grid (inside one step plus an hour) passes the up-front check');
select throws_like(
  $$ select pgpm._from_hypertable_check_frontier('public.hok34', 'ts', interval '1 hour', false) $$,
  '%cannot migrate hypertable hok34 with p_interval 01:00:00 -- refused before anything is changed%ahead of now()%',
  'the same row on an hourly grid (20 hours past one step plus an hour) is refused: the bound scales with the step');

call pgpm.from_hypertable('public.hok34', 'ts', interval '1 day', p_paused => false);
select is(
  (select relkind::text from pg_class where oid = 'public.hok34'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.hok34),
  'p/1,2', 'LIVENESS: and from_hypertable migrates it without the override');
select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
