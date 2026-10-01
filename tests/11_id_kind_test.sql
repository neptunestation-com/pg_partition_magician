-- Verifies integer/id-range partitioning (events_id): structure, obtain ahead
-- of the id frontier, full drain, and row conservation. Robust to seed size.
create extension if not exists pgtap;

select plan(6);

select is(
  (select relkind::text from pg_class where relname = 'events_id' and relnamespace = 'public'::regnamespace),
  'p', 'events_id is a partitioned table'
);

select is(
  (select control_kind from pgpm.config where parent_table = 'public.events_id'::regclass),
  'id', 'config: control_kind = id'
);

select is(
  pg_get_partkeydef('public.events_id'::regclass),
  'RANGE (id)', 'events_id is RANGE-partitioned on id'
);

-- premade partitions sit ahead of the current id frontier
select cmp_ok(
  (select count(*) from pgpm.part
    where parent_table = 'public.events_id'::regclass
      and lo::numeric > (select max(id) from public.events_id))::int,
  '>=', 2, 'at least 2 id partitions premade ahead of the frontier'
);

-- Conservation is judged against the rows fixtures/demo.sql seeded BEFORE it ran the migration
-- (public.events_id_seeded). A count taken here, after the migration, is the migration's own output, and
-- comparing the table to it compares the count to itself. Identity, not only cardinality: a lost row
-- and a stray one cancel in a count, never in the bag of (id, payload).
select is(
  (select count(*) from public.events_id)::bigint,
  (select count(*) from public.events_id_seeded)::bigint,
  'row count conserved across the id migration (against the count seeded before it)'
);

select bag_eq(
  'select id, payload from public.events_id',
  'select id, payload from public.events_id_seeded',
  'every seeded events_id row survives the migration by identity: none lost, none added, none altered'
);

select * from finish();
