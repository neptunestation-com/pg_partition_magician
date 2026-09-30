-- The cutover's conservation check compares WHICH rows, not how many (issue #653).
--
-- #460 added a check under the lock that refuses the swap unless the source and the destination agree, so
-- a row the append-only catch-up cannot see (one that landed behind the copy watermark) is refused rather
-- than dropped. It compared count(*) only, and a count is invariant under compensating changes: one copied
-- row deleted plus one row appended behind the watermark during the online window left 72 = 72, the swap
-- went ahead, the late row was lost and the deleted row came back. An UPDATE of a copied row changes no
-- count at all. The check now compares a content fingerprint of every row as well (a sum of 64-bit hashes
-- of each row's text over the columns the copy moves), carried through the catch-up by RETURNING.
--
-- Four parts. A, B and C are compensating shapes a count cannot see, one per catch-up path; D is the
-- positive half, the shapes the fingerprint must NOT refuse (a keyless table's legitimate duplicate rows,
-- NULLs, a jsonb and a numeric column, and a late append past the watermark).
--   A: keyless, append-only: a copied row deleted, a row appended behind the watermark. 72 = 72.
--   B: keyed, append-only: a copied row UPDATED, and one row appended past the watermark that the keyed
--      catch-up does take, so the destination's side is 60 + 1 and the refusal names 61, which shows the
--      catch-up's RETURNING was carried into the fingerprint and not only its row count.
--   C: change-tracking: one update captured by the trigger (reconciled), one made with the trigger
--      bypassed (session_replication_role = replica), which the delta never saw. 50 = 50.
--   D: keyless, append-only, nothing behind the watermark: the cutover SUCCEEDS with the same bag of rows.
--
-- WHAT THE HARNESS ALLOWS, the constraint tests/timescale/db/17 and 20 explain: a refusing cutover must be
-- wrapped by throws_like, and a cutover that WRONGLY proceeds dies at its own COMMIT inside the wrapper and
-- rolls back into the same end state a refusal leaves. The discriminator in A, B and C is therefore the
-- refusal's message, pinned down to the equal counts and "not the same rows"; the state assertions after
-- each are invariants and are marked so. p_predrain => false so no per-batch COMMIT is reached inside
-- throws_like. bench/hypertable_cutover_conservation.sh runs this file against the count-only mutant
-- (bench/mutations/mutate.py: hypertable_cutover_conservation_by_count).
--
-- LIVENESS: every refusing part asserts, BEFORE the cutover, that the counts are equal (so a count check
-- could not refuse), that the changed row is behind the watermark, and what the destination holds of it
-- (so the shape is one the catch-up cannot repair). Part D asserts the duplicates and the late row are
-- really there, so its pass cannot come from a table with nothing for a fingerprint to get wrong.
select plan(32);

-- a copy watermark per table, recorded before the online-window writes (the anchor every part relies on)
create table t22_w (tbl text primary key, w timestamptz not null);

-- ================= PART A: keyless, a delete and a late append behind the watermark cancel =================

create table ci_a (ts timestamptz not null, dev int, v text);
select create_hypertable('ci_a', 'ts', chunk_time_interval => interval '1 day');
insert into ci_a select date_trunc('hour', now()) - interval '5 days' + g * interval '1 hour', g, 'r' || g
  from generate_series(0, 71) g;
call pgpm.from_hypertable_copy('ci_a', 'ts');
insert into t22_w select 'ci_a', max(ts) from ci_a_pgpm_dest;

delete from ci_a where dev = 5;
insert into ci_a select w - interval '30 hours' + interval '30 minutes', 999, 'late' from t22_w where tbl = 'ci_a';

select is((select count(*)::int from ci_a), 72, 'A witness: the source holds 72 rows');
select is((select count(*)::int from ci_a_pgpm_dest), 72, 'A witness: the destination holds 72 rows, the same count');
select cmp_ok((select ts from ci_a where dev = 999), '<', (select w from t22_w where tbl = 'ci_a'),
  'A witness: the late row 999 sits behind the copy watermark, where the catch-up cannot see it');
select is((select array_agg(dev order by dev) from ci_a_pgpm_dest where dev in (5, 999)), array[5],
  'A witness: the destination holds the deleted row 5 and not the late row 999');
select is((select array_agg(dev order by dev) from ci_a where dev in (5, 999)), array[999],
  'A witness: the source holds the late row 999 and not the deleted row 5');

select throws_like(
  $$ call pgpm.from_hypertable_cutover('ci_a', 'ts', interval '1 month', p_predrain => false) $$,
  '%refusing to swap: the source and the destination would both hold 72 rows after the append-only catch-up, but not the same rows%p_track_changes => true%',
  'A: the cutover refuses on equal counts, because the destination does not hold the same rows');

-- invariants, not discriminators (a mutant that wrongly proceeds dies at its own COMMIT and rolls back too)
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'ci_a'), 1,
  'A: the source is still a hypertable');
select is((select array_agg(dev order by dev) from ci_a where dev in (5, 999)), array[999],
  'A: the source still holds the late row 999 and not row 5');

-- ================= PART B: keyed, an UPDATE of a copied row, plus one append the catch-up takes =================

create table ci_b (ts timestamptz not null, device_id bigint not null, temp double precision,
                   constraint ci_b_key unique (device_id, ts));
select create_hypertable('ci_b', 'ts', chunk_time_interval => interval '1 day');
insert into ci_b select date_trunc('hour', now()) - interval '4 days' + g * interval '1 hour', g, g * 1.5
  from generate_series(1, 60) g;
call pgpm.from_hypertable_copy('ci_b', 'ts');
insert into t22_w select 'ci_b', max(ts) from ci_b_pgpm_dest;

update ci_b set temp = -1 where device_id = 7;
insert into ci_b select w + interval '1 minute', 9001, 2 from t22_w where tbl = 'ci_b';

select cmp_ok((select ts from ci_b where device_id = 7), '<', (select w from t22_w where tbl = 'ci_b'),
  'B witness: the updated row sits behind the copy watermark');
select is((select temp from ci_b_pgpm_dest where device_id = 7), 10.5::double precision,
  'B witness: the destination holds the copied version of row 7 (temp 10.5), not the update');
select is((select temp from ci_b where device_id = 7), -1::double precision,
  'B witness: the source holds the updated version (temp -1)');
select cmp_ok((select ts from ci_b where device_id = 9001), '>', (select w from t22_w where tbl = 'ci_b'),
  'B witness: the appended row 9001 sits past the watermark, where the keyed catch-up takes it');
select is((select count(*)::int from ci_b), 61, 'B witness: the source holds 60 copied + 1 appended');
select is((select count(*)::int from ci_b_pgpm_dest), 60, 'B witness: the destination holds the 60 copied');

select throws_like(
  $$ call pgpm.from_hypertable_cutover('ci_b', 'ts', interval '1 month', p_predrain => false) $$,
  '%refusing to swap: the source and the destination would both hold 61 rows after the append-only catch-up, but not the same rows%p_track_changes => true%',
  'B: the cutover refuses an update of a copied row, naming 61, so the catch-up''s append was counted into both sides');

select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'ci_b'), 1,
  'B: the source is still a hypertable');
select is((select count(*)::int from ci_b_pgpm_dest), 60,
  'B: the destination is back to its 60 copied rows (the catch-up rolled back with the refusal)');

-- ================= PART C: change-tracking, a write that bypassed the capture trigger =================

create table ci_c (ts timestamptz not null, device_id bigint not null, temp double precision,
                   constraint ci_c_key unique (device_id, ts));
select create_hypertable('ci_c', 'ts', chunk_time_interval => interval '1 day');
insert into ci_c select date_trunc('hour', now()) - interval '3 days' + g * interval '1 hour', g, g
  from generate_series(1, 50) g;
call pgpm.from_hypertable_copy('ci_c', 'ts', p_track_changes => true);

update ci_c set temp = -3 where device_id = 3;          -- captured: the trigger fires
set session_replication_role = replica;
update ci_c set temp = -9 where device_id = 9;          -- NOT captured: no trigger fires under replica
reset session_replication_role;

select is((select array_agg(distinct device_id order by device_id) from ci_c_pgpm_delta), array[3]::bigint[],
  'C witness: the delta saw the captured update (3) and not the bypassed one (9)');
select is((select temp from ci_c_pgpm_dest where device_id = 9), 9::double precision,
  'C witness: the destination holds the copied version of row 9');
select is((select temp from ci_c where device_id = 9), -9::double precision,
  'C witness: the source holds the bypassed update of row 9');
select is((select count(*)::int from ci_c), (select count(*)::int from ci_c_pgpm_dest),
  'C witness: the two sides hold the same count (50), so a count check could not refuse');

select throws_like(
  $$ call pgpm.from_hypertable_cutover('ci_c', 'ts', interval '1 month', p_predrain => false) $$,
  '%refusing to swap: 1 source row%changed during the online window without firing the change-capture trigger%first key (9,%',
  'C: the tracking cutover refuses a write the delta never saw, on equal counts (the #654 untracked-write refusal names the row; the fingerprint comparison behind it is what parts A and B pin)');

select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'ci_c'), 1,
  'C: the source is still a hypertable');
select is((select temp from ci_c where device_id = 9), -9::double precision,
  'C: the source still holds the bypassed update');

-- ================= PART D: keyless, duplicates and NULLs, nothing behind the watermark; the cutover succeeds =================
--
-- The shapes a fingerprint must not trip on: two identical rows (legitimate in a keyless table, and an XOR
-- of hashes would cancel them), NULLs, a jsonb and a numeric column whose text rendering is the whole
-- comparison, and a late pair of IDENTICAL rows past the watermark that the catch-up must take both of.
create table ci_d (ts timestamptz not null, dev int, v text, j jsonb, n numeric);
select create_hypertable('ci_d', 'ts', chunk_time_interval => interval '1 day');
insert into ci_d select date_trunc('hour', now()) - interval '4 days' + g * interval '1 hour', g,
                        case when g % 7 = 0 then null else 'r' || g end,
                        case when g % 5 = 0 then null else jsonb_build_object('g', g, 'a', array[g, g + 1]) end,
                        g / 3.0
  from generate_series(1, 40) g;
insert into ci_d select ts, dev, v, j, n from ci_d where dev = 12;    -- an exact duplicate of a copied row
call pgpm.from_hypertable_copy('ci_d', 'ts');
insert into t22_w select 'ci_d', max(ts) from ci_d_pgpm_dest;
insert into ci_d select w + interval '10 minutes', 777, null, '{"late": true}', 1.50 from t22_w where tbl = 'ci_d';
insert into ci_d select w + interval '10 minutes', 777, null, '{"late": true}', 1.50 from t22_w where tbl = 'ci_d';
create table ci_d_snap as select * from ci_d;

select is((select count(*)::int from ci_d where dev = 12), 2, 'D witness: the source holds two identical copies of row 12');
select is((select count(*)::int from ci_d_pgpm_dest where dev = 12), 2, 'D witness: and the copy took both');
select is((select count(*)::int from ci_d where dev = 777), 2,
  'D witness: two identical late rows 777 sit past the watermark');
select is((select count(*)::int from ci_d_pgpm_dest where dev = 777), 0, 'D witness: neither late row is in the destination yet');

call pgpm.from_hypertable_cutover('ci_d', 'ts', interval '1 month', p_paused => false);

select is((select relkind::text from pg_class where oid = 'ci_d'::regclass), 'p',
  'D: the table migrated to a native partitioned table');
select bag_eq('select ts, dev, v, j, n from ci_d', 'select ts, dev, v, j, n from ci_d_snap',
  'D: the migrated table holds the same bag of rows, both duplicates and both late rows included');
select is((select count(*)::int from ci_d where dev = 777), 2, 'D: both identical late rows survived');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'ci_d'), 0,
  'D: the hypertable was torn down');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
