-- from_hypertable and from_hypertable_cutover ask transmute's column-type rules for the grid arguments before
-- anything is changed (issues #1118 and #1138 bullet 2). #1085 had them ask the rules a value alone breaks
-- (a step that is not positive, a negative obtain or retain), with kind 'time' and nothing about the column,
-- so the rules that depend on the dimension's type were first asked by transmute at the handoff, after the
-- cutover's swap had committed and dropped the hypertable, leaving a plain table pgpm does not manage:
--   a date key, a step that is not whole days or months   "the date column ... holds whole days" (#581)
--   a date key, an anchor not at 00:00 UTC                 "the column is a date ... at 00:00 UTC" (#769)
--   a timestamp(p) key, a step or an anchor finer than p   "the column is timestamp(0) ... keeps" (#1039)
-- Now pgpm._time_unit_contract holds all three (the #581 date-step rule moved into it from transmute's
-- preflight), and pgpm._from_hypertable_check_arguments asks it of the hypertable's own column, so
-- from_hypertable refuses before its copy and the cutover before its pre-drain and its swap.
--
-- WHAT THE HARNESS ALLOWS. Every refused call is a committing procedure wrapped by throws_like, and one that
-- wrongly does NOT refuse dies at its first COMMIT inside that function context with 2D000 (the copy's, or
-- with p_predrain => false the swap's) and rolls back into the state a refusal leaves. So the pinned
-- messages, anchored at the start, are the discriminating assertions; the state checks after them are
-- invariants, marked so.
--
-- ASYMMETRIC FIXTURES. d66 (a date key, three rows, 1, 2 and 3) and t66 (a timestamptz(0) key, two rows, 10
-- and 20) go through the one-shot driver; e66 (a date key, four rows, 7 to 10) through the two phases, so a
-- refusal that left one table's state in another's place would show. WITNESSES: transmute refuses each
-- argument on a plain table of the same column type with the same message, so the module asks transmute's
-- rules and not new ones; and the boundary values each rule allows (a whole-month step on a date, a
-- whole-second anchor off midnight on a timestamptz(0)) migrate the three tables afterwards.
select plan(20);

create table public.d66 (d date not null, v int);
select create_hypertable('public.d66', 'd', chunk_time_interval => interval '7 days');
insert into public.d66 values (current_date - 9, 1), (current_date - 5, 2), (current_date - 1, 3);
create table public.t66 (ts timestamptz(0) not null, v int);
select create_hypertable('public.t66', 'ts', chunk_time_interval => interval '1 day');
insert into public.t66 values (now() - interval '30 hours', 10), (now() - interval '2 hours', 20);
create table public.e66 (d date not null, v int);
select create_hypertable('public.e66', 'd', chunk_time_interval => interval '7 days');
insert into public.e66 values (current_date - 40, 7), (current_date - 20, 8), (current_date - 10, 9),
                              (current_date - 2, 10);
create table public.p66d (d date not null, v int);
insert into public.p66d values (current_date - 1, 1);
create table public.p66t (ts timestamptz(0) not null, v int);
insert into public.p66t values (now() - interval '1 hour', 1);

-- ================================ the rules are transmute's ================================
select throws_like(
  $$ call pgpm.transmute('public.p66d', 'd', interval '36 hours') $$,
  'pg_partition_magician: the date column d holds whole days, so its partition step must be a whole number of days or months (got 36:00:00)%',
  'WITNESS: transmute refuses a sub-day step on a plain table''s date key');
select throws_like(
  $$ call pgpm.transmute('public.p66d', 'd', interval '1 day', p_anchor => '2000-01-01 12:00:00+00') $$,
  'pg_partition_magician: cannot partition p66d on d with step 1 day and anchor % -- the column is a date, %this anchor falls at 12:00:00 UTC%',
  'WITNESS: transmute refuses an anchor off 00:00 UTC on a plain table''s date key');
select throws_like(
  $$ call pgpm.transmute('public.p66t', 'ts', interval '1500 milliseconds') $$,
  'pg_partition_magician: cannot partition p66t on ts with step 00:00:01.5 and anchor % -- the column is timestamp(0) with time zone, which keeps whole seconds only%',
  'WITNESS: transmute refuses a step finer than a timestamptz(0) key keeps on a plain table');

-- ================================ A: the one-shot driver, before its copy ================================
select throws_like(
  $$ call pgpm.from_hypertable('public.d66', 'd', interval '36 hours') $$,
  'pg_partition_magician: the date column d holds whole days, so its partition step must be a whole number of days or months (got 36:00:00)%',
  'from_hypertable refuses a sub-day step on a date dimension before its copy (#1118)');
select throws_like(
  $$ call pgpm.from_hypertable('public.d66', 'd', interval '1 day', p_anchor => '2000-01-01 12:00:00+00') $$,
  'pg_partition_magician: cannot partition d66 on d with step 1 day and anchor % -- the column is a date, %this anchor falls at 12:00:00 UTC%',
  'from_hypertable refuses an anchor off 00:00 UTC on a date dimension before its copy (#1138 bullet 2)');
select throws_like(
  $$ call pgpm.from_hypertable('public.t66', 'ts', interval '1500 milliseconds') $$,
  'pg_partition_magician: cannot partition t66 on ts with step 00:00:01.5 and anchor % -- the column is timestamp(0) with time zone, which keeps whole seconds only%',
  'from_hypertable refuses a step finer than a timestamptz(0) dimension keeps before its copy (#1039)');
select throws_like(
  $$ call pgpm.from_hypertable('public.t66', 'ts', interval '1 day', p_anchor => '2000-01-01 00:00:00.5+00') $$,
  'pg_partition_magician: cannot partition t66 on ts with step 1 day and anchor % -- the column is timestamp(0) with time zone, which keeps whole seconds only%',
  'from_hypertable refuses an anchor finer than a timestamptz(0) dimension keeps before its copy');
select is(
  (select count(*) from timescaledb_information.hypertables where hypertable_name in ('d66', 't66'))
  || '/' || (select count(*) from pgpm.config where parent_table::text in ('d66', 't66'))
  || '/' || (select count(*) from pgpm.scratch where parent_oid in ('public.d66'::regclass::oid, 'public.t66'::regclass::oid))
  || '/' || (select string_agg(v::text, ',' order by v) from public.d66)
  || '/' || (select string_agg(v::text, ',' order by v) from public.t66),
  '2/0/0/1,2,3/10,20', 'invariant: d66 and t66 are still hypertables, unregistered, with no copy recorded, holding 1,2,3 and 10,20');

-- ================================ B: the cutover, before its pre-drain and its swap ================================
call pgpm.from_hypertable_copy('public.e66', 'd');
select is(
  (select string_agg(v::text, ',' order by v) from public.e66_pgpm_dest)
  || '/' || (pgpm._from_hypertable_scratch('public.e66', 'hypertable_dest') is not null)::text,
  '7,8,9,10/true', 'LIVENESS: the copy of e66 ran, holds 7,8,9,10 and is recorded');
-- p_predrain => false, so nothing commits ahead of the swap for an unrelated reason: a cutover that does not
-- refuse dies on the swap's COMMIT inside throws_like, which its pinned message tells apart.
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.e66', 'd', interval '1 hour', p_predrain => false) $$,
  'pg_partition_magician: the date column d holds whole days, so its partition step must be a whole number of days or months (got 01:00:00)%',
  'from_hypertable_cutover refuses a sub-day step on a date dimension before the swap (#1118)');
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.e66', 'd', interval '1 day', p_anchor => '2000-01-01 05:00:00+00', p_predrain => false) $$,
  'pg_partition_magician: cannot partition e66 on d with step 1 day and anchor % -- the column is a date, %this anchor falls at 05:00:00 UTC%',
  'from_hypertable_cutover refuses an anchor off 00:00 UTC on a date dimension before the swap (#1138 bullet 2)');
-- the pre-drain is the cutover's first COMMIT: the refusal comes before it too
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.e66', 'd', interval '1 hour') $$,
  'pg_partition_magician: the date column d holds whole days, so its partition step must be a whole number of days or months (got 01:00:00)%',
  'from_hypertable_cutover refuses a sub-day step before its pre-drain');
select is(
  (select count(*) from timescaledb_information.hypertables where hypertable_name = 'e66')
  || '/' || (select count(*) from pgpm.config where parent_table::text = 'e66')
  || '/' || (select string_agg(v::text, ',' order by v) from public.e66)
  || '/' || (select string_agg(v::text, ',' order by v) from public.e66_pgpm_dest),
  '1/0/7,8,9,10/7,8,9,10', 'invariant: e66 is still a hypertable, unregistered, holding 7,8,9,10, its copy in place');

-- ================================ LIVENESS: what each rule allows migrates ================================
call pgpm.from_hypertable_cutover('public.e66', 'd', interval '1 month', p_obtain => 2, p_paused => false);
select is(
  (select relkind::text from pg_class where oid = 'public.e66'::regclass)
  || '/' || (select partition_step::text from pgpm.config where parent_table = 'public.e66'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.e66),
  'p/1 mon/7,8,9,10', 'LIVENESS: the cutover migrates e66 on a whole-month step, its rows by value');
call pgpm.from_hypertable('public.d66', 'd', interval '2 days', p_obtain => 2,
                          p_anchor => '2000-01-02 00:00:00+00', p_paused => false);
select is(
  (select relkind::text from pg_class where oid = 'public.d66'::regclass)
  || '/' || (select partition_step::text from pgpm.config where parent_table = 'public.d66'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.d66),
  'p/2 days/1,2,3', 'LIVENESS: from_hypertable migrates d66 on a two-day step anchored at another midnight UTC');
call pgpm.from_hypertable('public.t66', 'ts', interval '1 day', p_obtain => 2,
                          p_anchor => '2000-01-01 00:00:01+00', p_paused => false);
select is(
  (select relkind::text from pg_class where oid = 'public.t66'::regclass)
  || '/' || (select partition_step::text from pgpm.config where parent_table = 'public.t66'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.t66),
  'p/1 day/10,20', 'LIVENESS: from_hypertable migrates t66 with a whole-second anchor off midnight');
select is(
  (select extract(epoch from partition_anchor::timestamptz)::bigint::text from pgpm.config where parent_table = 'public.t66'::regclass)
  || '/' || (select extract(epoch from partition_anchor::timestamptz)::bigint::text from pgpm.config where parent_table = 'public.d66'::regclass),
  '946684801/946771200', 'LIVENESS: t66''s grid keeps its 00:00:01 anchor and d66''s its 2000-01-02 one, as given');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name in ('d66', 't66', 'e66')), 0,
  'LIVENESS: none of the three is a hypertable any more');
select is((select count(*)::int from pgpm.scratch where parent_oid in ('public.d66'::regclass::oid, 'public.t66'::regclass::oid, 'public.e66'::regclass::oid)), 0,
  'LIVENESS: and no scratch record is left for any');
select is((select count(*)::int from pgpm.handoff), 0,
  'LIVENESS: and no handoff was left behind by a refused one');

select * from finish();
