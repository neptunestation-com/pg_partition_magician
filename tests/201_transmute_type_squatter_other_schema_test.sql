-- transmute's type-squatter guard (#671) looks only in the TABLE'S OWN schema (review pass 5 seed S1).
--
-- A table's row type lives in the table's schema, so only a type in that schema can collide with a name the
-- cutover gives a table. pgpm._type_squatter filters on n.nspname = p_nsp for exactly that reason. Lose the
-- filter and a same-named type ANYWHERE in the database makes transmute refuse a conversion that would have
-- gone through: a false refusal that leaves the table unconvertible for as long as some unrelated schema
-- keeps its type. tests/181 has no other-schema case, so it passed against that mutant; this file is it.
--
-- Fixtures, asymmetric on purpose (two schemas, a squatter in each role):
--   (W) the WITNESS: an enum on tyw's staging name in tyw's own schema (public). It must be refused and
--       named, which proves the guard is live here and that this file derives the names transmute derives.
--       Without it, (O) would also pass against a guard that never fires at all;
--   (O) the case: an enum on tyo's staging name AND a domain on tyo's monolith name, both in another schema
--       (s201, not on the search path). Neither is in tyo's way: the call is made bare (a committing
--       procedure cannot run inside lives_ok's function), tyo converts, both types are untouched, and the
--       original table takes the monolith name the s201 domain also carries.
-- The refusal is pinned by its message (throws_like): a committing procedure that does NOT refuse dies at
-- its first COMMIT inside pgTAP with 2D000, which an unpinned assertion would accept.
-- bench/transmute_type_squatter_other_schema.sh runs this file against a mutant whose _type_squatter has
-- lost its schema filter (type_squatter_any_schema), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(11);

set timezone = 'UTC';
create schema s201;

-- (W) the same-schema squatter is still refused, and named
create table public.tyw (id bigint primary key, body text);
insert into public.tyw select g, 'w' || g from generate_series(1, 5) g;
create type public.tyw_pgpm_new as enum ('w');
select throws_like($$ call pgpm.transmute('public.tyw', 'id', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: public.tyw_pgpm_new already exists as an enum type, and transmute needs that name as a staging name%',
  'W LIVENESS: an enum on tyw''s staging name in tyw''s own schema is refused, and named as an enum');
select is((select relkind::text from pg_class where oid = 'public.tyw'::regclass), 'r',
  'W LIVENESS: and tyw is still a plain table');

-- (O) squatters in ANOTHER schema are not in the way
create table public.tyo (id bigint primary key, body text);
insert into public.tyo select g, 'o' || g from generate_series(1, 250) g;   -- step 100: monolith [0, 300)
select pgpm._part_name('tyo', 'id', '100', '0', '300', 'UTC') as tyo_mon \gset
select oid as tyo_oid from pg_class where oid = 'public.tyo'::regclass \gset
create type s201.tyo_pgpm_new as enum ('o');
create domain s201.:"tyo_mon" as int;
select ok(to_regtype('s201.tyo_pgpm_new') is not null and to_regtype(format('s201.%I', :'tyo_mon')) is not null
          and to_regtype('public.tyo_pgpm_new') is null and to_regtype(format('public.%I', :'tyo_mon')) is null,
  'O LIVENESS: tyo''s staging and monolith names are taken as types in s201 and free in public');
select is(pgpm._type_squatter('s201', 'tyo_pgpm_new'), 'an enum type',
  'O LIVENESS: _type_squatter sees the enum in its own schema');
select is(pgpm._type_squatter('public', 'tyo_pgpm_new'), null,
  'O: _type_squatter does not count the s201 enum against public');
select is(pgpm._type_squatter('public', :'tyo_mon'), null,
  'O: nor the s201 domain');
call pgpm.transmute('public.tyo', 'id', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.tyo'::regclass), 'p',
  'O: transmute does not refuse tyo for types that live in another schema, and tyo converts');
select is((select relname::text from pg_class where oid = :tyo_oid), :'tyo_mon',
  'O: and the original table took the monolith name the s201 domain also carries');
select is((select array_agg(id order by id) from public.tyo where id in (1, 250)), array[1, 250]::bigint[],
  'O: tyo holds its first and last rows');
select is((select enum_range(null::s201.tyo_pgpm_new)::text), '{o}', 'O: the s201 enum is untouched');
select is((select typtype::text from pg_type where typnamespace = 's201'::regnamespace and typname = :'tyo_mon'), 'd',
  'O: and so is the s201 domain');

select * from finish();
