-- Verifies uuidv7 (time-grid, uuid-encoded boundaries) partitioning on
-- events_uuid: codec roundtrip, structure, obtain, full drain, conservation.
-- Robust to seed size.
create extension if not exists pgtap;

select plan(7);

select is(
  pgpm._uuid_to_ts(pgpm._ts_to_uuid('2026-07-15 12:00:00+00'::timestamptz)),
  '2026-07-15 12:00:00+00'::timestamptz,
  'uuid<->timestamp codec roundtrips at ms resolution'
);

select is(
  (select relkind::text from pg_class where relname = 'events_uuid' and relnamespace = 'public'::regnamespace),
  'p', 'events_uuid is a partitioned table'
);

select is(
  (select control_kind from pgpm.config where parent_table = 'public.events_uuid'::regclass),
  'uuidv7', 'config: control_kind = uuidv7'
);

select is(
  pg_get_partkeydef('public.events_uuid'::regclass),
  'RANGE (id)', 'events_uuid is RANGE-partitioned on the uuid id'
);

select cmp_ok(
  (select count(*) from pgpm.part
    where parent_table = 'public.events_uuid'::regclass
      and lo::timestamptz > date_trunc('month', now()))::int,
  '>=', 2, 'at least 2 uuid partitions premade ahead of the frontier'
);

-- Conservation is judged against the rows fixtures/demo.sql seeded BEFORE it ran the migration
-- (public.events_uuid_seeded). A count taken here, after the migration, is the migration's own output, and
-- comparing the table to it compares the count to itself. Identity, not only cardinality: a lost row
-- and a stray one cancel in a count, never in the bag of (id, payload).
select is(
  (select count(*) from public.events_uuid)::bigint,
  (select count(*) from public.events_uuid_seeded)::bigint,
  'row count conserved across the uuid migration (against the count seeded before it)'
);

select bag_eq(
  'select id, payload from public.events_uuid',
  'select id, payload from public.events_uuid_seeded',
  'every seeded events_uuid row survives the migration by identity: none lost, none added, none altered'
);

select * from finish();
