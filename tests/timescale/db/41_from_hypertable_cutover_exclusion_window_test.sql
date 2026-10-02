-- from_hypertable_cutover refuses an EXCLUDE constraint added to the hypertable after the copy, and refuses it
-- before anything commits (issues #675 and #841).
--
-- THE BUG (#841). The cutover asked _from_hypertable_check_exclusion only up front, not again under its
-- ACCESS EXCLUSIVE, unlike the shape (#738) and the key and frontier (#792). The source is unlocked from the
-- up-front checks to the lock (the pre-drain's commits, the index pre-builds), so a constraint added in that
-- window was dropped by the swap with the hypertable and the migrated table accepted the rows it had
-- rejected. The check is now asked in both places.
--
-- WHAT THIS FILE PINS: the UP-FRONT half, which one session can reach. An EXCLUDE added after the copy,
-- with rows past the copy's watermark, is refused before the pre-drain commits a batch of them. That is what
-- separates the up-front check from the one under the lock: without it, the pre-drain (one row per batch
-- here) reaches its first COMMIT inside throws_like and dies with 2D000, before the lock is ever reached.
-- The window itself (a constraint added while the cutover is queued, after the up-front check) needs a
-- second session; bench/hypertable_cutover_exclusion_window.sh drives it, runs this file too, and is what
-- both mutations are proven against.
--
-- ASYMMETRIC FIXTURE. The copy holds ids 1 to 20, the source 1 to 24: four rows past the watermark, more
-- than the one-row batch, so a pre-drain that ran would commit. WITNESSES: the constraint enforces before
-- the cutover; after the operator's remedy (dropping it) the same copy cuts over with every row.
--
-- Autocommit, disposable-db. from_hypertable_copy and _cutover are called as bare statements.
select plan(8);

create table public.x41 (id bigint not null, ts timestamptz not null, dev int not null, primary key (id, ts));
select create_hypertable('public.x41', 'ts', chunk_time_interval => interval '1 day');
insert into public.x41 select g, timestamptz '2026-09-01 00:00+00' + g * interval '3 hours', g from generate_series(1, 20) g;
call pgpm.from_hypertable_copy('public.x41', 'ts');

-- The online window: appends past the watermark, and the constraint.
insert into public.x41 select g, timestamptz '2026-09-01 00:00+00' + g * interval '3 hours', g from generate_series(21, 24) g;
alter table public.x41 add constraint x41_dev_excl exclude using btree (dev with =, ts with =);

-- ================= WITNESSES =================
select is(
  (select string_agg(id::text, ',' order by id) from public.x41_pgpm_dest) || ' '
    || (select count(*) from public.x41 where ts > (select max(ts) from public.x41_pgpm_dest)),
  (select string_agg(g::text, ',' order by g) from generate_series(1, 20) g) || ' 4',
  'WITNESS: the copy holds ids 1 to 20 and four rows are past its watermark, more than a one-row batch');
select is(
  (select string_agg(conname || ':' || contype::text, ',') from pg_constraint
    where conrelid = 'public.x41'::regclass and contype = 'x'),
  'x41_dev_excl:x', 'WITNESS: the hypertable carries the exclusion constraint added after the copy');
select throws_ok(
  $$ insert into public.x41 values (500, timestamptz '2026-09-01 15:00+00', 5) $$,
  '23P01', NULL, 'WITNESS: and it rejects a second row with dev 5 at id 5''s instant');

-- ================= THE CONTRACT =================
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.x41', 'ts', interval '1 day', p_drain_batch => 1) $$,
  'pg_partition_magician: cannot migrate hypertable x41 -- its exclusion constraint(s) (x41_dev_excl) cannot be carried%',
  'the cutover refuses the exclusion constraint before its pre-drain commits anything');

-- Invariants (a wrongly proceeding cutover also rolls back at its first COMMIT and lands here).
select is(
  (select count(*)::int from timescaledb_information.hypertables where hypertable_schema = 'public' and hypertable_name = 'x41')
    || ' ' || (select count(*) from pg_constraint where conrelid = 'public.x41'::regclass and conname = 'x41_dev_excl')
    || ' ' || (select count(*) from public.x41_pgpm_dest),
  '1 1 20', 'invariant: x41 is still the hypertable with its constraint, and the copy is as it was');

-- ================= LIVENESS: the remedy the message names converts the table =================
alter table public.x41 drop constraint x41_dev_excl;
call pgpm.from_hypertable_cutover('public.x41', 'ts', interval '1 day', p_drain_batch => 1, p_paused => false);
select is((select relkind::text from pg_class where oid = 'public.x41'::regclass), 'p',
  'LIVENESS: with the constraint dropped, the same copy cuts over');
select is(
  (select string_agg(id || ':' || dev, ',' order by id) from public.x41),
  (select string_agg(g || ':' || g, ',' order by g) from generate_series(1, 24) g),
  'LIVENESS: with every row, the four past the watermark included');
select is((select count(*)::int from pg_constraint where conrelid = 'public.x41'::regclass and contype = 'x'), 0,
  'LIVENESS: and no exclusion constraint, as the operator chose');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
