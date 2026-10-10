-- transmute refuses, up front, a TYPE holding a name its cutover gives a table (issue #671).
--
-- The derived-name guards (the staging <rel>_pgpm_new, #344; the monolith <rel>_p<lo>_to_<hi>, #509) asked
-- to_regclass, which sees relations only. CREATE TABLE and ALTER TABLE ... RENAME also need the name free
-- in pg_type, because every table has a row type of its own name, so an enum, domain or range type holding
-- either name passed the guard and the cutover died with a raw 42710, after phases 1 and 2 had committed the
-- write-rejecting bound and the claim. Every re-run failed the same way. Both guards now also ask
-- _type_squatter, one mechanism for both sites.
--
-- Fixtures, asymmetric on purpose:
--   (A) an enum holding tya's STAGING name: refused, naming the enum; nothing committed; converts once
--       the enum is dropped;
--   (B) a domain holding tyb's MONOLITH name (computed with _part_name, as transmute computes it):
--       refused, naming the domain; nothing committed; converts once the domain is renamed away;
--   (C) no false refusal: an enum named cf_pgpm_new has the IMPLICIT ARRAY type _cf_pgpm_new, which is
--       exactly the staging name of table _cf. PostgreSQL moves an implicit array type aside itself, so
--       that one must not be refused, and _cf converts with the enum untouched.
-- Each refusal is pinned by its message (throws_like): a committing procedure that does NOT refuse dies at
-- its first COMMIT inside pgTAP with 2D000, which an unpinned assertion would accept.
-- bench/transmute_type_squatter.sh runs this file against a mutant whose _type_squatter never finds a type
-- (transmute_name_guard_relations_only), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(19);

set timezone = 'UTC';

-- (A) the staging name
create table public.tya (id bigint primary key, body text);
insert into public.tya select g, 'b' || g from generate_series(1, 5) g;
create type public.tya_pgpm_new as enum ('x');
select ok(to_regclass('public.tya_pgpm_new') is null and to_regtype('public.tya_pgpm_new') is not null,
  'LIVENESS: (A) tya''s staging name is free as a relation and taken as a type');
select throws_like($$ call pgpm.transmute('public.tya', 'id', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: public.tya_pgpm_new already exists as an enum type, and transmute needs that name as a staging name%',
  'A: the enum on the staging name is refused, and named as an enum');
select is((select relkind::text from pg_class where oid = 'public.tya'::regclass), 'r', 'A: tya is still a plain table');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.tya'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.tya'::regclass),
  'A: no bound and no claim were committed');
select lives_ok($$ insert into public.tya values (500, 'past any bound') $$, 'A: tya still takes a write past any bound');
drop type public.tya_pgpm_new;
call pgpm.transmute('public.tya', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.tya'::regclass), 'p',
  'LIVENESS: (A) with the enum gone the same call converts tya');

-- (B) the monolith name
create table public.tyb (id bigint primary key, body text);
insert into public.tyb select g, 'b' || g from generate_series(1, 250) g;   -- step 100: monolith [0, 300)
select pgpm._part_name('tyb', 'id', '100', '0', '300', 'UTC') as tyb_mon \gset
select oid as tyb_oid from pg_class where oid = 'public.tyb'::regclass \gset
create domain public.:"tyb_mon" as int;
select ok(to_regclass(format('public.%I', :'tyb_mon')) is null and to_regtype(format('public.%I', :'tyb_mon')) is not null,
  'LIVENESS: (B) tyb''s monolith name is free as a relation and taken as a type');
select throws_like($$ call pgpm.transmute('public.tyb', 'id', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: public.' || :'tyb_mon' || ' already exists as a domain, and transmute needs that name for the monolith%',
  'B: the domain on the monolith name is refused, and named as a domain');
select is((select relkind::text from pg_class where oid = 'public.tyb'::regclass), 'r', 'B: tyb is still a plain table');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.tyb'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.tyb'::regclass),
  'B: no bound and no claim were committed (the claim taken before this check was rolled back with it)');
select is((select array_agg(id order by id) from public.tyb where id in (1, 250)), array[1, 250]::bigint[],
  'B: tyb still holds its first and last rows');
alter domain public.:"tyb_mon" rename to tyb_elsewhere;
call pgpm.transmute('public.tyb', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.tyb'::regclass), 'p',
  'LIVENESS: (B) with the domain renamed away the same call converts tyb');
select is((select relname::text from pg_class where oid = :tyb_oid), :'tyb_mon',
  'LIVENESS: (B) and the original table took exactly the name the domain had held');

-- (C) an implicit array type on the staging name is not in the way
create table public._cf (id bigint primary key, body text);
insert into public._cf select g, 'b' || g from generate_series(1, 5) g;
create type public.cf_pgpm_new as enum ('y');
select is((select t.typcategory::text from pg_type t where t.typname = '_cf_pgpm_new'
             and t.typnamespace = 'public'::regnamespace
             and t.typelem = 'public.cf_pgpm_new'::regtype), 'A',
  'LIVENESS: (C) _cf_pgpm_new, _cf''s staging name, is taken by the implicit array type of the enum cf_pgpm_new');
select is(pgpm._type_squatter('public', '_cf_pgpm_new'), null, 'C: _type_squatter does not count an implicit array type');
select is(pgpm._type_squatter('public', 'cf_pgpm_new'), 'an enum type', 'LIVENESS: (C) but it does see the enum itself');
call pgpm.transmute('public._cf', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public._cf'::regclass), 'p', 'C: _cf converts');
select is((select enum_range(null::public.cf_pgpm_new)::text), '{y}', 'C: the enum is untouched');
select is((select array_agg(id order by id) from public._cf), array[1, 2, 3, 4, 5]::bigint[], 'C: _cf holds rows 1 to 5');

select * from finish();
