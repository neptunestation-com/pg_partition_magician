-- a regrain's fine children are created in the parent's tablespace, so every partition pgpm mints lands there (#1075)
--
-- docs/reference.md (transmute) and docs/guide.md promise that the parent is created in the table's tablespace
-- "so every partition pgpm mints from it lands there as well". obtain and extend_to mint through
-- _create_partition, a CREATE TABLE ... PARTITION OF, which takes the parent's tablespace. regrain_step mints
-- each fine child as a STANDALONE CREATE TABLE (LIKE ...), which carries no tablespace, and named none, so the
-- fine children landed in the database default and the swap attached them there: after a regrain of a table
-- transmute placed in its own tablespace, the monolith's rows were on the default volume (F11-01). tests/226
-- never regrains, so it stayed green.
--
-- Fixtures, asymmetric so that each wrong rule fails at least one part:
--   (A) ta296 in the tablespace, 150 rows: its four fine children are in the tablespace (no clause at all fails).
--   (B) tb296 in the database default, converted, THEN its parent moved to the tablespace (which moves nothing;
--       it sets where partitions are minted from then on): its monolith stays in the default, a partition
--       extend_to mints afterwards goes to the tablespace, and so do its two fine children. A rule that copies
--       the SOURCE child's tablespace instead of the parent's fails here.
--   (C) tc296 in the database default throughout: its four fine children stay in the default. A rule that puts
--       every fine child in some fixed tablespace fails here.
-- In-place tablespaces (allow_in_place_tablespaces, PostgreSQL 15 and later) need no directory on the server,
-- so the file runs on the plain image. bench/regrain_children_tablespace.sh runs it against a mutant whose
-- fine-child CREATE names no tablespace again (regrain_children_tablespace_dropped), so it is also required to
-- FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(15);

-- A tablespace is cluster-wide and a database still holding objects in it pins it, so it is named for this
-- database: a re-run in a fresh database (each run of this file gets one) never meets another's.
select 'pgpm_t296_' || current_database() as ts \gset
set allow_in_place_tablespaces = on;
drop tablespace if exists :"ts";
create tablespace :"ts" location '';
select oid as ts_oid from pg_tablespace where spcname = :'ts' \gset

-- ==================== (A) a table in its own tablespace ====================
create table public.ta296 (id bigint primary key, v text) tablespace :"ts";
insert into public.ta296 select g, 'a' || g from generate_series(1, 150) g;
call pgpm.transmute('public.ta296', 'id', 100::bigint, p_obtain => 2);   -- monolith [0, 200)
insert into public.ta296 values (350, 'frontier');                        -- the monolith is frozen
select pgpm.obtain('public.ta296');
select child_name as a_mono, child_oid as a_mono_oid from pgpm.part
 where parent_table = 'public.ta296'::regclass and attached and lo = '0' \gset
select is((select reltablespace::text || ' ' || (select reltablespace from pg_class where oid = :'a_mono_oid'::oid)::text
             from pg_class where oid = 'public.ta296'::regclass),
  :'ts_oid' || ' ' || :'ts_oid',
  'A LIVENESS: the parent and the monolith holding ids 1..150 are both in pgpm_t296_<database>');
select is(pgpm.regrain('public.ta296', :'a_mono', '50'), 4, 'A LIVENESS: the regrain swapped in four fine children');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.ta296'::regclass and attached and lo::numeric < 200),
  array['0-50', '50-100', '100-150', '150-200'],
  'A LIVENESS: and they replaced the monolith over [0, 200)');
select is((select array_agg(c.relname::text || ':' || coalesce(t.spcname::text, 'database default') order by p.lo::numeric)
             from pgpm.part p join pg_class c on c.oid = p.child_oid
             left join pg_tablespace t on t.oid = c.reltablespace
            where p.parent_table = 'public.ta296'::regclass and p.attached and p.lo::numeric < 200),
  array['ta296_p0000000000000000000:' || :'ts', 'ta296_p0000000000000000050:' || :'ts',
        'ta296_p0000000000000000100:' || :'ts', 'ta296_p0000000000000000150:' || :'ts'],
  'A: every fine child the regrain minted is in pgpm_t296_<database>, the parent''s tablespace');
select is((select array_agg(id order by id) from public.ta296 r join pg_class c on c.oid = r.tableoid
            where r.id < 200 and c.reltablespace = :'ts_oid'::oid),
  (select array_agg(g::bigint order by g) from generate_series(1, 150) g),
  'A: so ids 1..150, the rows the regrain moved, are all still stored in pgpm_t296_<database>');

-- ==================== (B) the parent moved to the tablespace after the conversion ====================
create table public.tb296 (id bigint primary key, v text);
insert into public.tb296 select g, 'b' || g from generate_series(1, 60) g;
call pgpm.transmute('public.tb296', 'id', 100::bigint, p_obtain => 2);   -- monolith [0, 100)
alter table public.tb296 set tablespace :"ts";   -- a partitioned table: moves nothing, sets where partitions go
insert into public.tb296 values (250, 'frontier');                       -- the monolith is frozen
select pgpm.extend_to('public.tb296', '450');
select child_name as b_mono, child_oid as b_mono_oid from pgpm.part
 where parent_table = 'public.tb296'::regclass and attached and lo = '0' \gset
select is((select reltablespace::text || ' ' || (select reltablespace from pg_class where oid = :'b_mono_oid'::oid)::text
             from pg_class where oid = 'public.tb296'::regclass),
  :'ts_oid' || ' 0',
  'B LIVENESS: the parent is in pgpm_t296_<database> now, while the monolith holding ids 1..60 is still in the database default');
select is((select c.reltablespace from pgpm.part p join pg_class c on c.oid = p.child_oid
            where p.parent_table = 'public.tb296'::regclass and p.child_name = 'tb296_p0000000000000000400'),
  :'ts_oid'::oid, 'B LIVENESS: a partition extend_to mints after the move is in pgpm_t296_<database>, the parent''s');
select is(pgpm.regrain('public.tb296', :'b_mono', '50'), 2, 'B LIVENESS: the regrain swapped in two fine children');
select is((select array_agg(c.relname::text || ':' || coalesce(t.spcname::text, 'database default') order by p.lo::numeric)
             from pgpm.part p join pg_class c on c.oid = p.child_oid
             left join pg_tablespace t on t.oid = c.reltablespace
            where p.parent_table = 'public.tb296'::regclass and p.attached and p.lo::numeric < 100),
  array['tb296_p0000000000000000000:' || :'ts', 'tb296_p0000000000000000050:' || :'ts'],
  'B: both fine children are in the parent''s tablespace, not the database default the monolith was in');
select is((select array_agg(id order by id) from public.tb296 r join pg_class c on c.oid = r.tableoid
            where r.id < 100 and c.reltablespace = :'ts_oid'::oid),
  (select array_agg(g::bigint order by g) from generate_series(1, 60) g),
  'B: so ids 1..60 are stored in pgpm_t296_<database> after the regrain');

-- ==================== (C) a table in the database default throughout ====================
create table public.tc296 (id bigint primary key, v text);
insert into public.tc296 select g, 'c' || g from generate_series(1, 30) g;
call pgpm.transmute('public.tc296', 'id', 100::bigint, p_obtain => 2);   -- monolith [0, 100)
insert into public.tc296 values (250, 'frontier');
select pgpm.obtain('public.tc296');
select child_name as c_mono from pgpm.part
 where parent_table = 'public.tc296'::regclass and attached and lo = '0' \gset
select is((select reltablespace from pg_class where oid = 'public.tc296'::regclass), 0::oid,
  'C LIVENESS: tc296''s parent is in the database default');
select is(pgpm.regrain('public.tc296', :'c_mono', '25'), 4, 'C LIVENESS: the regrain swapped in four fine children');
select is((select array_agg(c.relname::text || ':' || c.reltablespace::text order by p.lo::numeric)
             from pgpm.part p join pg_class c on c.oid = p.child_oid
            where p.parent_table = 'public.tc296'::regclass and p.attached and p.lo::numeric < 100),
  array['tc296_p0000000000000000000:0', 'tc296_p0000000000000000025:0',
        'tc296_p0000000000000000050:0', 'tc296_p0000000000000000075:0'],
  'C: and every one of them is in the database default (reltablespace 0), not in pgpm_t296_<database>');
select is((select array_agg(id order by id) from public.tc296 where id < 100),
  (select array_agg(g::bigint order by g) from generate_series(1, 30) g),
  'C LIVENESS: the fine children hold exactly ids 1..30');

-- ==================== the tablespace holds exactly what it should ====================
select is((select array_agg(c.relname::text order by c.relname::text) from pg_class c
            where c.reltablespace = :'ts_oid'::oid and c.relkind in ('r', 'p')
              and c.relnamespace = 'public'::regnamespace and c.relname::text ~ '^t[abc]296'),
  array['ta296', 'ta296_p0000000000000000000', 'ta296_p0000000000000000050', 'ta296_p0000000000000000100',
        'ta296_p0000000000000000150', 'ta296_p0000000000000000200', 'ta296_p0000000000000000300',
        'ta296_p0000000000000000400', 'ta296_p0000000000000000500', 'tb296', 'tb296_p0000000000000000000', 'tb296_p0000000000000000050',
        'tb296_p0000000000000000300', 'tb296_p0000000000000000400'],
  'the tables in pgpm_t296_<database> are A''s whole set and B''s parent, fine children and post-move partitions, none of C''s');

select * from finish();
drop table public.ta296, public.tb296, public.tc296;
drop tablespace if exists :"ts";
