-- Append-only catch-up (the online guarantee). The migration copies existing chunks to a watermark while
-- the source stays live, then catches up rows that arrived after the watermark during the brief cutover.
-- This drives the two phases separately (from_hypertable_copy, then from_hypertable_cutover) and injects
-- late appends between them, asserting they land in the migrated table. The rows are judged by identity
-- against a snapshot of the source taken right before the cutover (a bag: a keyless table can hold a row
-- twice), never by count: a catch-up that lost one copied row and held another twice keeps the count.
-- Autocommit, disposable-db.
select plan(5);

select mk_plain_hypertable('hp_d1', 240, '1 day', '10 days');   -- 240 rows up to ~now

-- PHASE 1: bulk-copy the existing chunks. The source stays live (no cutover yet).
call pgpm.from_hypertable_copy('hp_d1', 'ts');

-- writes that arrive DURING the migration: 5 appends after the copy watermark (future ts, tagged device_id)
insert into hp_d1 (ts, device_id, temp)
  select now() + (g || ' hours')::interval, 1000 + g, random() * 100 from generate_series(1, 5) g;

-- the source as it stands before the cutover, the 240 copied rows and the 5 late appends: what the migrated
-- table must hold, row for row
create temp table hp_d1_before as select * from hp_d1;
select is((select count(*) || '/' || string_agg(device_id::text, ',' order by device_id) filter (where device_id >= 1000)
             from hp_d1_before),
  '245/1001,1002,1003,1004,1005',
  'LIVENESS: the snapshot holds the 240 copied rows and the 5 late appends, 1001 to 1005');

-- PHASE 2: catch up the late appends, cut over, hand off
call pgpm.from_hypertable_cutover('hp_d1', 'ts', interval '1 month', p_paused => false);

select is(
  (select relkind::text from pg_class where oid = 'hp_d1'::regclass),
  'p', 'the table migrated to a native partitioned table');
select bag_eq('select * from hp_d1', 'select * from hp_d1_before',
  'every row of the source, the 240 copied and the 5 late appends, is in the migrated table exactly as often as it was in the source: none lost, none held twice, none altered');
select is(
  (select count(*)::int from hp_d1 where device_id >= 1000),
  5, 'the late appends (written between copy and cutover) were caught up');
select is(
  (select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hp_d1'),
  0, 'the hypertable was torn down');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
