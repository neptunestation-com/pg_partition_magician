-- An append-only migration of a hypertable that was EMPTY when from_hypertable_copy ran (issue #736).
--
-- The copy watermark is max(control) in the destination, and an empty copy leaves it NULL. Both catch-ups
-- read that as "nothing to catch up": the pre-drain (from_hypertable_drain_appends) returned at once, and
-- the cutover skipped its catch-up under `if v_watermark is not null`. So every row appended in order
-- after the copy, the append-only contract's own workload, stayed out of the destination, and the
-- conservation check refused the swap, blaming rows "at or below the copy watermark" when there is none.
-- Nothing was copied, so every source row is past the watermark: a NULL watermark now means "take
-- everything", in the pre-drain, in its step function, and in the cutover's own catch-up, keyed and
-- keyless alike.
--
-- The cutover's catch-up is reached on its own with p_predrain => false (otherwise the pre-drain has
-- already moved the watermark off NULL). ASYMMETRIC FIXTURES: 5 + 2 rows, 4 rows, and a keyless 3 whose
-- two identical rows are legitimate duplicates, each asserted by identity, so neither a lost row nor a
-- doubled one can pass. Every successful copy and cutover is a top-level CALL: run_timescale fails the
-- track on any `ERROR:` line, which is how the old refusal shows up here.
-- bench/hypertable_empty_copy_watermark.sh runs this file against the mutations that put the NULL-means-
-- nothing reading back, one per catch-up. Autocommit, disposable-db.
select plan(11);

-- ==================== (A) keyed, the default pre-drain ====================
create table public.c5b_ea (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.c5b_ea', 'ts', chunk_time_interval => interval '1 day');
call pgpm.from_hypertable_copy('public.c5b_ea', 'ts');
select is(
  (select (to_regclass('public.c5b_ea_pgpm_dest') is not null)::text || '|'
          || coalesce((select max(ts)::text from public.c5b_ea_pgpm_dest), 'NULL')),
  'true|NULL', 'LIVENESS: the copy of an empty hypertable built an empty destination, so its watermark is NULL');
insert into public.c5b_ea
select g, date_trunc('hour', now()) - interval '2 days' + g * interval '1 hour', 'a' || g from generate_series(1, 5) g;
call pgpm.from_hypertable_drain_appends('public.c5b_ea', 'ts');
select is((select array_agg(id || ':' || v order by id) from public.c5b_ea_pgpm_dest),
  array['1:a1', '2:a2', '3:a3', '4:a4', '5:a5'],
  'the pre-drain takes every row appended past a NULL watermark into the destination');
insert into public.c5b_ea
select g, date_trunc('hour', now()) - interval '2 days' + g * interval '1 hour', 'a' || g from generate_series(6, 7) g;
call pgpm.from_hypertable_cutover('public.c5b_ea', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public.c5b_ea'::regclass), 'p',
  'the cutover then converts the table');
select is((select array_agg(id || ':' || v order by id) from public.c5b_ea),
  (select array_agg(g || ':a' || g order by g) from generate_series(1, 7) g),
  'with the 5 pre-drained rows and the 2 appended after the pre-drain');

-- ==================== (B) keyed, the cutover's own catch-up ====================
create table public.c5b_eb (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.c5b_eb', 'ts', chunk_time_interval => interval '1 day');
call pgpm.from_hypertable_copy('public.c5b_eb', 'ts');
insert into public.c5b_eb
select g, date_trunc('hour', now()) - interval '2 days' + g * interval '1 hour', 'b' || g from generate_series(1, 4) g;
select is(
  (select count(*)::text from public.c5b_eb_pgpm_dest) || '|' || (select count(*)::text from public.c5b_eb),
  '0|4', 'LIVENESS: the destination is still empty and the source holds the 4 appended rows');
call pgpm.from_hypertable_cutover('public.c5b_eb', 'ts', interval '1 day', p_predrain => false);
select is((select relkind::text from pg_class where oid = 'public.c5b_eb'::regclass), 'p',
  'without a pre-drain, the cutover''s catch-up takes every row past a NULL watermark and converts the table');
select is((select array_agg(id || ':' || v order by id) from public.c5b_eb),
  array['1:b1', '2:b2', '3:b3', '4:b4'], 'with exactly the 4 appended rows');

-- ==================== (C) keyless, the cutover's own catch-up, with a legitimate duplicate ====================
create table public.c5b_ec (ts timestamptz not null, device_id bigint, v text);
select create_hypertable('public.c5b_ec', 'ts', chunk_time_interval => interval '1 day');
call pgpm.from_hypertable_copy('public.c5b_ec', 'ts');
insert into public.c5b_ec values
  (date_trunc('hour', now()) - interval '5 hours', 1, 'c'),
  (date_trunc('hour', now()) - interval '5 hours', 1, 'c'),
  (date_trunc('hour', now()) - interval '4 hours', 2, 'd');
call pgpm.from_hypertable_cutover('public.c5b_ec', 'ts', interval '1 day', p_predrain => false);
select is((select relkind::text from pg_class where oid = 'public.c5b_ec'::regclass), 'p',
  'a keyless table converts the same way');
select is((select array_agg(device_id || ':' || v order by device_id, v) from public.c5b_ec),
  array['1:c', '1:c', '2:d'], 'with both duplicate rows and the third');

-- ==================== (D) the step function, called with the NULL watermark ====================
create table public.c5b_ed (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.c5b_ed', 'ts', chunk_time_interval => interval '1 day');
call pgpm.from_hypertable_copy('public.c5b_ed', 'ts');
insert into public.c5b_ed
select g, date_trunc('hour', now()) - interval '2 days' + g * interval '1 hour', 'e' || g from generate_series(1, 3) g;
select is(pgpm.from_hypertable_drain_appends_step('public.c5b_ed', 'ts', 2, null)::timestamptz,
  date_trunc('hour', now()) - interval '2 days' + interval '2 hours',
  'from_hypertable_drain_appends_step reads a NULL watermark as before every row: its first batch ends at the 2nd');
select is((select array_agg(id order by id) from public.c5b_ed_pgpm_dest), array[1, 2]::bigint[],
  'and that batch is exactly the first 2 rows');

select * from finish();
