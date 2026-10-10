-- from_hypertable silently dropped an EXCLUDE constraint (issue #675). The copy builds the destination with
-- CREATE TABLE ... LIKE, which carries CHECK and NOT NULL only; the cutover's key loop takes contype p and
-- u only; and its index loop skips every constraint-backed index. So nothing carried an exclusion
-- constraint, preflight did not refuse one, and the migrated table accepted the double booking the
-- hypertable had rejected. Nor can one be carried in general: PostgreSQL 15 and 16 do not allow an
-- exclusion constraint on a partitioned table at all. So every entry point refuses it up front, naming it:
-- from_hypertable_preflight (and through it from_hypertable and from_hypertable_copy), and
-- from_hypertable_cutover in its own right, since a destination left by an older version's copy, or made
-- by hand, reaches the swap without preflight ever having run.
--
-- WHAT THE HARNESS ALLOWS. run_timescale fails the track on any `ERROR:` line, so every refused call is
-- wrapped by throws_like, and a procedure that reaches its own COMMIT inside that function context dies
-- with `invalid transaction termination` and rolls back into the state a refusal leaves. So the refusals'
-- own messages are the discriminating assertions (each pins the constraint names, which no 2D000 carries);
-- the state checks after them are invariants, marked so.
--
-- ASYMMETRIC FIXTURE. The table carries TWO exclusion constraints and ONE unique constraint, which
-- from_hypertable does carry: the refusal must name exactly the two, in order, and not the unique one.
-- WITNESSES: both constraints really reject their own violation before anything runs, and after the
-- operator's remedy (dropping the two) the same table migrates, so the refusal was the only obstacle.
select plan(16);

create extension if not exists btree_gist;
create table public.ex26 (
  ts timestamptz not null, room int not null, desk int not null, during tstzrange not null, tag text not null,
  constraint ex26_b_no_double_booking exclude using gist (room with =, during with &&, ts with =),
  constraint ex26_a_one_desk_per_instant exclude using gist (desk with =, ts with =),
  constraint ex26_tag_key unique (tag, ts));
select create_hypertable('public.ex26', 'ts', chunk_time_interval => interval '1 day');
insert into public.ex26
select timestamptz '2026-09-01 00:00+00' + g * interval '1 hour', g % 3, g % 5,
       tstzrange(timestamptz '2026-09-01 00:00+00' + g * interval '1 hour',
                 timestamptz '2026-09-01 00:00+00' + g * interval '1 hour' + interval '30 min'),
       't' || g
  from generate_series(0, 71) g;

-- ================= WITNESSES: the constraints are there and enforce =================
select is(
  (select string_agg(conname || ':' || contype::text, ',' order by conname) from pg_constraint
    where conrelid = 'public.ex26'::regclass and contype in ('x', 'u')),
  'ex26_a_one_desk_per_instant:x,ex26_b_no_double_booking:x,ex26_tag_key:u',
  'LIVENESS: the hypertable carries two exclusion constraints and one unique constraint');
select throws_like(
  $$ insert into public.ex26 values ('2026-09-01 00:00+00', 0, 4, tstzrange('2026-09-01 00:00+00', '2026-09-01 00:30+00'), 'fresh') $$,
  '%violates exclusion constraint "%ex26_b_no_double_booking"%',
  'LIVENESS: before migration the hypertable rejects a double booking of room 0 at 00:00');
select throws_like(
  $$ insert into public.ex26 values ('2026-09-01 00:00+00', 2, 0, tstzrange('2026-09-02 00:00+00', '2026-09-02 00:30+00'), 'fresh') $$,
  '%violates exclusion constraint "%ex26_a_one_desk_per_instant"%',
  'LIVENESS: and a second use of desk 0 at 00:00');

-- ================= the refusals, one per entry point =================
select throws_like(
  $$ select pgpm.from_hypertable_preflight('public.ex26', 'ts') $$,
  'pg_partition_magician: cannot migrate hypertable ex26 -- its exclusion constraint(s) (ex26_a_one_desk_per_instant, ex26_b_no_double_booking) cannot be carried%',
  'preflight refuses the exclusion constraints, naming exactly the two and not the unique key');
select throws_like(
  $$ call pgpm.from_hypertable('public.ex26', 'ts', interval '1 day') $$,
  '%its exclusion constraint(s) (ex26_a_one_desk_per_instant, ex26_b_no_double_booking) cannot be carried%',
  'from_hypertable refuses them before its first commit');
select throws_like(
  $$ call pgpm.from_hypertable_copy('public.ex26', 'ts') $$,
  '%its exclusion constraint(s) (ex26_a_one_desk_per_instant, ex26_b_no_double_booking) cannot be carried%',
  'from_hypertable_copy refuses them before creating anything');
select is(to_regclass('public.ex26_pgpm_dest'), null::regclass,
  'invariant: no destination was left behind by the refused copy');

-- The cutover is the irreversible step and does not run preflight, so it checks for itself: a destination
-- from an older version's copy (made by hand here, as tests/timescale/db/18 does) reaches it directly.
-- p_predrain => false so nothing commits ahead of the check for an unrelated reason.
create table public.ex26_pgpm_dest (like public.ex26);
insert into public.ex26_pgpm_dest select * from public.ex26;
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.ex26', 'ts', interval '1 day', p_predrain => false) $$,
  '%its exclusion constraint(s) (ex26_a_one_desk_per_instant, ex26_b_no_double_booking) cannot be carried%',
  'from_hypertable_cutover refuses them in its own right, with a destination in place');
drop table public.ex26_pgpm_dest;

-- Invariants (a wrongly proceeding mutant also rolls back at its first COMMIT and lands here).
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'ex26'),
  1, 'invariant: ex26 is still a hypertable');
select is((select count(*)::int from pgpm.config where parent_table::text = 'ex26'),
  0, 'invariant: and not registered with pgpm');

-- ================= LIVENESS: the remedy the message names works =================
-- Drop the two exclusion constraints and the same table migrates: the refusal was the only obstacle, and
-- the unique constraint beside them is carried as before.
alter table public.ex26 drop constraint ex26_a_one_desk_per_instant, drop constraint ex26_b_no_double_booking;
select lives_ok(
  $$ select pgpm.from_hypertable_preflight('public.ex26', 'ts') $$,
  'LIVENESS: with the exclusion constraints dropped, preflight accepts the table');
call pgpm.from_hypertable('public.ex26', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public.ex26'::regclass), 'p',
  'LIVENESS: from_hypertable then migrates it to a partitioned table');
select is((select count(*)::int from pgpm.config where parent_table = 'public.ex26'::regclass), 1,
  'LIVENESS: registered with pgpm');
select is(
  (select string_agg(tag, ',' order by ts) from public.ex26 where tag in ('t0', 't35', 't71')),
  't0,t35,t71', 'LIVENESS: the first, a middle and the last row came across');
select is((select count(*)::int from public.ex26), 72, 'LIVENESS: and all 72 of them');
select is(
  (select string_agg(pg_get_constraintdef(oid), ',') from pg_constraint
    where conrelid = 'public.ex26'::regclass and contype in ('u', 'x')),
  'UNIQUE (tag, ts)', 'LIVENESS: the unique constraint beside them was carried, and nothing else');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
