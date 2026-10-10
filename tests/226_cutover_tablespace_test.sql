-- transmute's parent takes the table's tablespace, so every partition minted from it lands there too
-- (issue #829).
--
-- The cutover's CREATE TABLE ... (LIKE ...) PARTITION BY named no TABLESPACE, and LIKE does not carry one,
-- so the parent was created in the database default. A partition created with no TABLESPACE clause takes
-- its parent's, so every partition obtain, extend_to and a regrain mint (all through _create_partition,
-- which names none) landed on pg_default too: a table the operator placed on its own volume had every row
-- written after the conversion fill the default one instead. The fix gives the staging parent the table's
-- tablespace, read in the cutover under the staging LIKE's ACCESS SHARE (which excludes SET TABLESPACE),
-- and refuses up front a caller that could not create a relation there.
--
-- Fixtures, asymmetric so that a mutant that puts every parent in one tablespace fails as surely as one
-- that puts none in any:
--   (A) ts226 in tablespace pgpm_t226_<database>, 10 rows: the parent and every forward partition are in it, the
--       monolith is the original relation still in it, and a row past the monolith lands there;
--   (B) df226 in the database default, 7 rows: its parent and partitions stay in the default (a carried
--       tablespace is the table's own, not a fixed one);
--   (C) a caller with no CREATE on the tablespace is refused before anything is committed, naming it.
-- In-place tablespaces (allow_in_place_tablespaces, PostgreSQL 15 and later) need no directory on the
-- server, so the file runs on the plain image. bench/cutover_tablespace.sh runs it against a mutant whose
-- cutover names no tablespace again (cutover_tablespace_dropped), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(15);

-- A tablespace is cluster-wide and a database still holding objects in it pins it, so it is named for this
-- database: a re-run in a fresh database (each run of this file gets one) never meets another's.
select 'pgpm_t226_' || current_database() as ts \gset
set allow_in_place_tablespaces = on;
drop tablespace if exists :"ts";
create tablespace :"ts" location '';
select oid as ts_oid from pg_tablespace where spcname = :'ts' \gset

-- ==================== (A) a table in its own tablespace ====================
create table public.ts226 (k int8 primary key, v text) tablespace :"ts";
insert into public.ts226 select g, 'v' || g from generate_series(1, 10) g;
select 'public.ts226'::regclass::oid as ts_rel \gset
select is((select reltablespace from pg_class where oid = 'public.ts226'::regclass), :'ts_oid'::oid,
  'LIVENESS: (A) ts226 lives in pgpm_t226_<database> before the conversion');
call pgpm.transmute('public.ts226', 'k', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.ts226'::regclass), 'p', 'LIVENESS: (A) ts226 is converted');
select is((select reltablespace from pg_class where oid = 'public.ts226'::regclass), :'ts_oid'::oid,
  'A: the partitioned parent is in pgpm_t226_<database>, as the table was');
select is((select monolith_oid::oid || ' ' || (select reltablespace from pg_class where oid = monolith_oid)::text
             from pgpm.config where parent_table = 'public.ts226'::regclass),
  :'ts_rel' || ' ' || :'ts_oid',
  'A: the monolith is the original relation, still in pgpm_t226_<database>');
select is((select array_agg(c.relname::text || ' ' || (c.reltablespace = :'ts_oid'::oid)::text order by p.lo::bigint)
             from pgpm.part p join pg_class c on c.oid = p.child_oid
            where p.parent_table = 'public.ts226'::regclass
              and p.child_oid <> (select monolith_oid from pgpm.config where parent_table = 'public.ts226'::regclass)),
  array['ts226_p0000000000000000100 true', 'ts226_p0000000000000000200 true'],
  'A: both forward partitions obtain minted are in pgpm_t226_<database>');
insert into public.ts226 values (150, 'fwd');
select is((select tableoid::regclass::text from public.ts226 where k = 150), 'ts226_p0000000000000000100',
  'LIVENESS: (A) row 150 landed in the first forward partition, not the monolith');
select is((select reltablespace from pg_class where oid = (select tableoid from public.ts226 where k = 150)), :'ts_oid'::oid,
  'A: so the row written past the monolith is stored in pgpm_t226_<database>');
select pgpm.extend_to('public.ts226', '450');
select is((select c.reltablespace from pgpm.part p join pg_class c on c.oid = p.child_oid
            where p.parent_table = 'public.ts226'::regclass and p.child_name = 'ts226_p0000000000000000400'),
  :'ts_oid'::oid, 'A: a partition extend_to mints later is in pgpm_t226_<database> as well');

-- ==================== (B) a table in the database default ====================
create table public.df226 (k int8 primary key, v text);
insert into public.df226 select g, 'd' || g from generate_series(1, 7) g;
select is((select reltablespace from pg_class where oid = 'public.df226'::regclass), 0::oid,
  'LIVENESS: (B) df226 lives in the database default before the conversion');
call pgpm.transmute('public.df226', 'k', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.df226'::regclass), 'p', 'LIVENESS: (B) df226 is converted');
select is((select array_agg(c.relname::text || ' ' || c.reltablespace::text order by c.relname)
             from pg_class c
            where c.oid = 'public.df226'::regclass
               or c.oid in (select child_oid from pgpm.part where parent_table = 'public.df226'::regclass)),
  array['df226 0', 'df226_p0000000000000000000 0', 'df226_p0000000000000000100 0', 'df226_p0000000000000000200 0'],
  'B: its parent, monolith and forward partitions are all in the database default, not in pgpm_t226_<database>');

-- ==================== (C) a caller that cannot create in the tablespace ====================
-- a role is cluster-wide too, and one that owns an object in another database cannot be dropped: reuse it
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't226_converter') then create role t226_converter; end if;
end $$;
grant usage, create on schema public to t226_converter;
grant usage on schema pgpm to t226_converter;
grant all on all tables in schema pgpm to t226_converter;
grant all on all sequences in schema pgpm to t226_converter;
grant create on tablespace :"ts" to t226_converter;
set role t226_converter;
create table public.np226 (k int8 primary key, v text) tablespace :"ts";
insert into public.np226 select g, 'n' || g from generate_series(1, 3) g;
reset role;
revoke create on tablespace :"ts" from t226_converter;
select ok(not has_tablespace_privilege('t226_converter', :'ts', 'CREATE')
          and (select pg_get_userbyid(relowner) = 't226_converter' and reltablespace = :'ts_oid'::oid
                 from pg_class where oid = 'public.np226'::regclass),
  'LIVENESS: (C) t226_converter owns np226, which is in pgpm_t226_<database>, and can no longer create there');
set role t226_converter;
select throws_like(
  $$ call pgpm.transmute('public.np226', 'k', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: cannot transmute np226 as t226_converter -- it is in the tablespace ' || :'ts' || ',%',
  'C: transmute refuses up front, naming the tablespace the caller cannot create the parent in');
reset role;
select is((select relkind::text || ' ' || (select string_agg(k::text, ',' order by k) from public.np226)
                  || ' ' || exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.np226'::regclass)::text
                  || ' ' || exists (select 1 from pg_constraint where conrelid = 'public.np226'::regclass and conname = 'pgpm_monolith_bound')::text
             from pg_class where oid = 'public.np226'::regclass),
  'r 1,2,3 false false',
  'C: and the table is left as it was, a plain table holding rows 1, 2 and 3, with no claim and no bound');
grant create on tablespace :"ts" to t226_converter;
set role t226_converter;
call pgpm.transmute('public.np226', 'k', 100::bigint, p_obtain => 2);
reset role;
select is((select relkind::text || ' ' || reltablespace::text from pg_class where oid = 'public.np226'::regclass),
  'p ' || :'ts_oid', 'LIVENESS: (C) with CREATE granted back the same transmute converts np226, into pgpm_t226_<database>');

select * from finish();
