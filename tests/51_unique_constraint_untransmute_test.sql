-- untransmute round-trips a table whose reused key is a UNIQUE constraint (no PK), exactly as it does
-- for a PK table: while the monolith still holds every row (before obtain/drain), untransmute restores
-- the plain table with its UNIQUE constraint intact and every row conserved. (Detaching the monolith
-- leaves its adopted unique constraint standing on the now-standalone table, so the reverse is clean.)
create extension if not exists pgtap;

select plan(5);

create table public.uq_rt (
  ts   timestamptz not null,
  id   bigint not null,
  body text,
  constraint uq_rt_key unique (ts, id)
);
-- each row its own body, and ts whole 24-hour steps apart (no calendar day, so no DST hour), so the
-- round trip is judged by which rows come back, not by how many (#1374)
insert into public.uq_rt (ts, id, body)
  select now() - g * interval '24 hours', g, 'b' || g from generate_series(1, 25) g;

call pgpm.transmute('public.uq_rt', 'ts', interval '1 month');
select pass('transmute a no-PK unique-constraint table (paused, monolith holds all)');
select lives_ok(
  $$ select pgpm.untransmute('public.uq_rt') $$,
  'untransmute reverses it while the monolith still holds every row');
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'uq_rt'),
  'r', 'the table is a plain table again');
-- by name and key: the monolith carries the constraint as pgpm_key_<oid> while partitioned, and untransmute
-- renames it back, so a count of one UNIQUE would also accept a missed rename or another key (#1374)
select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.uq_rt'::regclass and contype in ('p', 'u')),
  array['uq_rt_key UNIQUE (ts, id)'], 'the UNIQUE constraint survived the round trip');
select is(
  (select array_agg(id || ':' || body || ':' || extract(epoch from newest - ts)::bigint order by id)
     from public.uq_rt, (select max(ts) as newest from public.uq_rt) n),
  (select array_agg(g || ':b' || g || ':' || (g - 1) * 86400 order by g) from generate_series(1, 25) g),
  'all rows conserved through the round trip');

select * from finish();
