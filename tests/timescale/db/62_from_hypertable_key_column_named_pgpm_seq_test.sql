-- A hypertable whose key has a column named pgpm_seq migrates with change tracking (issue #1074): the hypertable
-- twin of tests/295.
--
-- THE DEFECT. from_hypertable_copy(..., p_track_changes => true) minted its delta as `create table <delta> as
-- select <key columns> from <hypertable>` and then added the ordering identity column under the fixed name
-- pgpm_seq, so a key with a column of that name failed the copy 42701 (column already exists) and such a
-- hypertable could not be tracked at all. The drain step, the drain loop and the cutover also told the key
-- from the ordering column by that name, so they would have dropped the key's own pgpm_seq from the key.
--
-- THE CONTRACT. pgpm._delta_seq_add mints the ordering column under the first of pgpm_seq, pgpm_seq_1, ... no
-- column of the delta holds, and every reader finds it as the delta's identity column (pgpm._delta_seq). So
-- the copy lives, the capture records every change by the whole key, a bounded drain step batches by the
-- ordering column, the drain and the cutover apply every change, and the migrated table holds exactly the
-- rows the source held.
--
-- ASYMMETRIC FIXTURE. Two hypertables with a tracking copy each.
--   hs62, key (pgpm_seq, ts), 200 rows: UPDATE of pgpm_seq 1..3, DELETE of 198..200, a key change 7 -> 5000,
--         and after the drain one more UPDATE (pgpm_seq 10) the cutover alone carries.
--   hq62, key (pgpm_seq, pgpm_seq_1, ts), 100 rows: one DELETE (pgpm_seq 1) and one UPDATE (pgpm_seq 2), so the
--         ordering column's name must step past a second taken name.
-- Autocommit, disposable-db.
select plan(16);

create table hs62 (ts timestamptz not null, pgpm_seq bigint not null, temp double precision,
                   constraint hs62_key unique (pgpm_seq, ts));
select create_hypertable('hs62', 'ts', chunk_time_interval => interval '1 day') \g /dev/null
insert into hs62 select now() - interval '10 days' + g * interval '1 hour', g, g from generate_series(1, 200) g;

create table hq62 (ts timestamptz not null, pgpm_seq bigint not null, pgpm_seq_1 bigint not null, temp double precision,
                   constraint hq62_key unique (pgpm_seq, pgpm_seq_1, ts));
select create_hypertable('hq62', 'ts', chunk_time_interval => interval '1 day') \g /dev/null
insert into hq62 select now() - interval '10 days' + g * interval '1 hour', g, -g, g from generate_series(1, 100) g;

-- ======================= hs62: key (pgpm_seq, ts) =======================
call pgpm.from_hypertable_copy('hs62', 'ts', p_track_changes => true);

select is(
  (select string_agg(a.attname || ':' || case a.attidentity when 'a' then 'identity' else 'plain' end, ', ' order by a.attnum)
     from pg_attribute a where a.attrelid = to_regclass('public.hs62_pgpm_delta') and a.attnum > 0 and not a.attisdropped),
  'pgpm_seq:plain, ts:plain, pgpm_seq_1:identity',
  'LIVENESS: the tracking copy minted hs62''s delta, the key''s pgpm_seq a plain column and the ordering column under the next free name');

update hs62 set temp = -1 where pgpm_seq <= 3;
delete from hs62 where pgpm_seq > 197;
update hs62 set pgpm_seq = 5000 where pgpm_seq = 7;

select is(
  (select string_agg(d.pgpm_seq::text, ',' order by d.pgpm_seq, d.pgpm_seq_1) from hs62_pgpm_delta d),
  '1,1,2,2,3,3,7,198,199,200,5000',
  'the capture recorded every change by the whole key, the key''s own pgpm_seq included');

-- A bounded step of 3 rows: the first three captures in the ordering column are one updated row's old and new
-- image and the next updated row's old one, so two keys. A watermark read off the key's own pgpm_seq instead
-- (its third value is 2, one key's pair and nothing after) would reconcile one.
select is(pgpm.from_hypertable_drain_delta_step('hs62', 'ts', 3), 2::bigint,
  'a three-row drain step batches by the ordering column and reconciles exactly two keys');
select is((select count(*)::int from hs62_pgpm_dest where temp = -1 and pgpm_seq <= 3), 2,
  'and exactly two of the three updated rows have reached the copy');

call pgpm.from_hypertable_drain_delta('hs62', 'ts');
select is((select count(*)::int from hs62_pgpm_delta), 0, 'the drain emptied hs62''s delta');
select set_eq(
  $$ select pgpm_seq, temp from hs62_pgpm_dest where pgpm_seq <= 8 or pgpm_seq >= 196 $$,
  $$ values (1::bigint, -1::float8), (2, -1), (3, -1), (4, 4), (5, 5), (6, 6), (8, 8), (196, 196), (197, 197), (5000, 7) $$,
  'the online drain applied every change to the copy before the cutover');

update hs62 set temp = -2 where pgpm_seq = 10;
call pgpm.from_hypertable_cutover('hs62', 'ts', interval '1 month', p_paused => false);

select is((select relkind::text from pg_class where oid = 'hs62'::regclass), 'p', 'hs62 migrated to a partitioned table');
select ok(to_regclass('public.hs62_pgpm_delta') is null, 'and its delta is gone with the cutover');
select set_eq(
  $$ select pgpm_seq, temp from hs62 where pgpm_seq <= 12 or pgpm_seq >= 195 $$,
  $$ values (1::bigint, -1::float8), (2, -1), (3, -1), (4, 4), (5, 5), (6, 6), (8, 8), (9, 9), (10, -2), (11, 11), (12, 12),
            (195, 195), (196, 196), (197, 197), (5000, 7) $$,
  'after the cutover hs62 holds every change: the updates, the key change, the post-drain update, and not the deleted rows');
select is((select count(*)::int from hs62 where pgpm_seq between 13 and 194), 182,
  'and the rest of hs62 is intact');

-- ======================= hq62: key (pgpm_seq, pgpm_seq_1, ts) =======================
call pgpm.from_hypertable_copy('hq62', 'ts', p_track_changes => true);

select is(
  (select string_agg(a.attname || ':' || case a.attidentity when 'a' then 'identity' else 'plain' end, ', ' order by a.attnum)
     from pg_attribute a where a.attrelid = to_regclass('public.hq62_pgpm_delta') and a.attnum > 0 and not a.attisdropped),
  'pgpm_seq:plain, pgpm_seq_1:plain, ts:plain, pgpm_seq_2:identity',
  'LIVENESS: hq62''s delta carries both key columns plain and the ordering column past both taken names');

delete from hq62 where pgpm_seq = 1;
update hq62 set temp = -1 where pgpm_seq = 2;
select is(
  (select string_agg(format('%s:%s', d.pgpm_seq, d.pgpm_seq_1), ',' order by d.pgpm_seq, d.pgpm_seq_2) from hq62_pgpm_delta d),
  '1:-1,2:-2,2:-2',
  'the capture recorded both changes by the whole three-column key');

call pgpm.from_hypertable_cutover('hq62', 'ts', interval '1 month', p_paused => false);
select is((select relkind::text from pg_class where oid = 'hq62'::regclass), 'p', 'hq62 migrated to a partitioned table');
select set_eq(
  $$ select pgpm_seq, pgpm_seq_1, temp from hq62 where pgpm_seq <= 4 $$,
  $$ values (2::bigint, -2::bigint, -1::float8), (3, -3, 3), (4, -4, 4) $$,
  'after the cutover hq62 holds the update and not the deleted row');
select is((select count(*)::int from hq62 where pgpm_seq between 5 and 100), 96, 'and the rest of hq62 is intact');
select ok(not exists (select 1 from pg_attribute where attrelid = 'hq62'::regclass and attname = 'pgpm_seq_2'),
  'and the migrated table carries no ordering column of its own');

select * from finish();
