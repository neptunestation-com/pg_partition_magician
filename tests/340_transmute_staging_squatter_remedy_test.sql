-- transmute's staging-name refusal names a remedy that works on what holds the name (issue #1273).
--
-- _transmute_refuse_staging_squatter refused any relation holding <table>_pgpm_new with the same remedy,
-- `drop table <schema>.<table>_pgpm_new`, whatever kind of relation it found. Against a sequence, a view, a
-- materialized view, a composite type or an index that statement fails 42809 ("is not a table"), so the
-- refusal told the operator to type a command that does not repair the state it describes. It now names
-- what it found (pgpm._relkind_noun, as the monolith and orphan-child refusals beside it do, #509) and the
-- DROP for that kind; a relation that is part of another object (a constraint's index, an identity column's
-- sequence) cannot be dropped on its own, so for one of those it names the owner and no DROP.
--
-- Each part TYPES the remedy the refusal names, verbatim, and shows it repairs the state: the name is free
-- afterwards and the same transmute call then converts the table. Fixtures, asymmetric on purpose (a
-- different holder kind per table, and different row counts):
--   (A) a sequence holds sa340's staging name             -> drop sequence
--   (B) a view holds "Sb340"'s (a name that needs quoting) -> drop view, with the name quoted
--   (C) a materialized view holds sc340's                 -> drop materialized view
--   (D) a composite type holds sd340's                    -> drop type
--   (E) a free-standing index (on another table) holds se340's -> drop index
--   (F) the index of a primary key constraint holds sf340's: no DROP named (drop index fails 2BP01 on it);
--       the refusal names the constraint, and renaming the index (which renames the constraint) frees it
--   (G) control: a partitioned table holds sg340's, the shape an interrupted run leaves; the refusal keeps
--       its leftover diagnosis and `drop table`, which still works.
--   (H) a table that is a member of an extension holds sh340's: DROP TABLE fails 2BP01 on it, so it gets
--       no DROP either; the refusal names the extension, and renaming the table frees the name.
-- bench/transmute_staging_squatter_remedy.sh runs this file against a mutant that routes every holder with
-- no owner to the table remedy again (staging_squatter_remedy_drop_table), so it is also required to FAIL
-- there.
create extension if not exists pgtap;
select plan(53);

set timezone = 'UTC';

-- The refusal transmute raises for a table, or null. Only the preflight runs before transmute's first
-- COMMIT, so a call that is not refused dies here with 2D000 and returns that message instead; every part
-- pins the refusal by its text, never by "something was raised".
create function pg_temp.refusal340(p_table regclass) returns text language plpgsql as $f$
begin
  call pgpm.transmute(p_table, 'id', 100::bigint, p_obtain => 2);
  return null;
exception when others then
  return sqlerrm;
end $f$;
-- The statement a refusal names in parentheses, if it names one.
create function pg_temp.remedy340(p_msg text) returns text language sql as $f$
  select (regexp_match(p_msg, '\((drop [^)]+)\)'))[1];
$f$;

-- (A) a sequence
create table public.sa340 (id bigint primary key, body text);
insert into public.sa340 select g, 'a' || g from generate_series(1, 3) g;
create sequence public.sa340_pgpm_new;
select is((select relkind::text from pg_class where oid = 'public.sa340_pgpm_new'::regclass), 'S',
  'LIVENESS: (A) a sequence holds sa340''s staging name');
select pg_temp.refusal340('public.sa340') as msg_a \gset
select ok(:'msg_a' like 'pg_partition_magician: public.sa340_pgpm_new already exists as a sequence, and transmute needs that name as a staging name for the new parent.%',
  'A: refused on the staging name, naming the sequence: ' || coalesce(:'msg_a', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_a'), 'drop sequence public.sa340_pgpm_new', 'A: the remedy named is the sequence''s DROP');
select lives_ok(pg_temp.remedy340(:'msg_a'), 'A: the remedy, typed as named, runs');
select is(to_regclass('public.sa340_pgpm_new'), null, 'A: and the staging name is free afterwards');
-- converted only once the name is free, so a remedy that failed reads as a failed part, not a dead file
select to_regclass('public.sa340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sa340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sa340'::regclass), 'p', 'A: the same call then converts sa340');

-- (B) a view, on a name that needs quoting
create table public."Sb340" (id bigint primary key, body text);
insert into public."Sb340" select g, 'b' || g from generate_series(1, 5) g;
create view public."Sb340_pgpm_new" as select 1 as one;
select is((select relkind::text from pg_class where oid = 'public."Sb340_pgpm_new"'::regclass), 'v',
  'LIVENESS: (B) a view holds "Sb340"''s staging name');
select pg_temp.refusal340('public."Sb340"') as msg_b \gset
select ok(:'msg_b' like 'pg_partition_magician: public.Sb340_pgpm_new already exists as a view, and transmute needs that name as a staging name for the new parent.%',
  'B: refused on the staging name, naming the view: ' || coalesce(:'msg_b', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_b'), 'drop view public."Sb340_pgpm_new"', 'B: the remedy named is the view''s DROP, the name quoted');
select lives_ok(pg_temp.remedy340(:'msg_b'), 'B: the remedy, typed as named, runs');
select is(to_regclass('public."Sb340_pgpm_new"'), null, 'B: and the staging name is free afterwards');
select to_regclass('public."Sb340_pgpm_new"') is null as free \gset
\if :free
call pgpm.transmute('public."Sb340"', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public."Sb340"'::regclass), 'p', 'B: the same call then converts "Sb340"');

-- (C) a materialized view
create table public.sc340 (id bigint primary key, body text);
insert into public.sc340 select g, 'c' || g from generate_series(1, 7) g;
create materialized view public.sc340_pgpm_new as select 1 as one;
select is((select relkind::text from pg_class where oid = 'public.sc340_pgpm_new'::regclass), 'm',
  'LIVENESS: (C) a materialized view holds sc340''s staging name');
select pg_temp.refusal340('public.sc340') as msg_c \gset
select ok(:'msg_c' like 'pg_partition_magician: public.sc340_pgpm_new already exists as a materialized view, and transmute needs that name as a staging name for the new parent.%',
  'C: refused on the staging name, naming the materialized view: ' || coalesce(:'msg_c', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_c'), 'drop materialized view public.sc340_pgpm_new', 'C: the remedy named is the materialized view''s DROP');
select lives_ok(pg_temp.remedy340(:'msg_c'), 'C: the remedy, typed as named, runs');
select is(to_regclass('public.sc340_pgpm_new'), null, 'C: and the staging name is free afterwards');
select to_regclass('public.sc340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sc340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sc340'::regclass), 'p', 'C: the same call then converts sc340');

-- (D) a composite type: a relation of kind c, so the relation check sees it (_type_squatter leaves a
-- relation's own row type to it)
create table public.sd340 (id bigint primary key, body text);
insert into public.sd340 select g, 'd' || g from generate_series(1, 2) g;
create type public.sd340_pgpm_new as (a int);
select is((select relkind::text from pg_class where oid = 'public.sd340_pgpm_new'::regclass), 'c',
  'LIVENESS: (D) a composite type holds sd340''s staging name');
select pg_temp.refusal340('public.sd340') as msg_d \gset
select ok(:'msg_d' like 'pg_partition_magician: public.sd340_pgpm_new already exists as a composite type, and transmute needs that name as a staging name for the new parent.%',
  'D: refused on the staging name, naming the composite type: ' || coalesce(:'msg_d', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_d'), 'drop type public.sd340_pgpm_new', 'D: the remedy named is the composite type''s DROP');
select lives_ok(pg_temp.remedy340(:'msg_d'), 'D: the remedy, typed as named, runs');
select ok(to_regclass('public.sd340_pgpm_new') is null and to_regtype('public.sd340_pgpm_new') is null,
  'D: and the staging name is free afterwards, as a relation and as a type');
select to_regclass('public.sd340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sd340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sd340'::regclass), 'p', 'D: the same call then converts sd340');

-- (E) a free-standing index, on another table
create table public.se340 (id bigint primary key, body text);
insert into public.se340 select g, 'e' || g from generate_series(1, 4) g;
create table public.se340_other (v int);
create index se340_pgpm_new on public.se340_other (v);
select is((select relkind::text from pg_class where oid = 'public.se340_pgpm_new'::regclass), 'i',
  'LIVENESS: (E) an index holds se340''s staging name');
select pg_temp.refusal340('public.se340') as msg_e \gset
select ok(:'msg_e' like 'pg_partition_magician: public.se340_pgpm_new already exists as an index, and transmute needs that name as a staging name for the new parent.%',
  'E: refused on the staging name, naming the index: ' || coalesce(:'msg_e', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_e'), 'drop index public.se340_pgpm_new', 'E: the remedy named is the index''s DROP');
select lives_ok(pg_temp.remedy340(:'msg_e'), 'E: the remedy, typed as named, runs');
select is(to_regclass('public.se340_pgpm_new'), null, 'E: and the staging name is free afterwards');
select to_regclass('public.se340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.se340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.se340'::regclass), 'p', 'E: the same call then converts se340');
select ok(to_regclass('public.se340_other') is not null, 'E: the table the index was on is untouched');

-- (F) a primary key constraint's index: DROP INDEX cannot drop it, so no DROP is named
create table public.sf340 (id bigint primary key, body text);
insert into public.sf340 select g, 'f' || g from generate_series(1, 6) g;
create table public.sf340_other (k int, constraint sf340_pgpm_new primary key (k));
select is((select relkind::text from pg_class where oid = 'public.sf340_pgpm_new'::regclass), 'i',
  'LIVENESS: (F) a primary key constraint''s index holds sf340''s staging name');
select throws_ok($$ drop index public.sf340_pgpm_new $$, '2BP01', NULL,
  'LIVENESS: (F) and DROP INDEX cannot drop it on its own');
select pg_temp.refusal340('public.sf340') as msg_f \gset
select ok(:'msg_f' like 'pg_partition_magician: public.sf340_pgpm_new already exists as an index, part of constraint sf340_pgpm_new on table sf340_other, and transmute needs that name as a staging name for the new parent.%',
  'F: refused on the staging name, naming the index and the constraint it is part of: ' || coalesce(:'msg_f', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_f'), null, 'F: no DROP statement is named for it');
select lives_ok($$ alter index public.sf340_pgpm_new rename to sf340_other_pkey $$, 'F: renaming it, as the refusal says, runs');
select is(to_regclass('public.sf340_pgpm_new'), null, 'F: and the staging name is free afterwards');
select to_regclass('public.sf340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sf340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sf340'::regclass), 'p', 'F: the same call then converts sf340');
select is((select conname::text from pg_constraint where conrelid = 'public.sf340_other'::regclass and contype = 'p'),
  'sf340_other_pkey', 'F: the other table keeps its primary key, under the new name');

-- (G) control: a partitioned table, the shape an interrupted run leaves at the staging name
create table public.sg340 (id bigint primary key, body text);
insert into public.sg340 select g, 'g' || g from generate_series(1, 8) g;
create table public.sg340_pgpm_new (id bigint primary key, body text) partition by range (id);
select is((select relkind::text from pg_class where oid = 'public.sg340_pgpm_new'::regclass), 'p',
  'LIVENESS: (G) a partitioned table holds sg340''s staging name');
select pg_temp.refusal340('public.sg340') as msg_g \gset
select ok(:'msg_g' like 'pg_partition_magician: public.sg340_pgpm_new already exists, and transmute needs it as a staging name for the new parent. Most likely a leftover from an interrupted run.%',
  'G: refused on the staging name, with the leftover diagnosis: ' || coalesce(:'msg_g', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_g'), 'drop table public.sg340_pgpm_new', 'G: the remedy named is still drop table');
select lives_ok(pg_temp.remedy340(:'msg_g'), 'G: the remedy, typed as named, runs');
select is(to_regclass('public.sg340_pgpm_new'), null, 'G: and the staging name is free afterwards');
select to_regclass('public.sg340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sg340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sg340'::regclass), 'p', 'G: the same call then converts sg340');

-- (H) a table that is a member of an extension: DROP TABLE cannot drop it on its own either
create table public.sh340 (id bigint primary key, body text);
insert into public.sh340 select g, 'h' || g from generate_series(1, 9) g;
create table public.sh340_pgpm_new (note text);
alter extension pgtap add table public.sh340_pgpm_new;
select ok((select c.relkind = 'r' from pg_class c where c.oid = 'public.sh340_pgpm_new'::regclass)
          and exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass
                         and d.objid = 'public.sh340_pgpm_new'::regclass and d.deptype = 'e'),
  'LIVENESS: (H) a table that is a member of an extension holds sh340''s staging name');
select throws_ok($$ drop table public.sh340_pgpm_new $$, '2BP01', NULL,
  'LIVENESS: (H) and DROP TABLE cannot drop it on its own');
select pg_temp.refusal340('public.sh340') as msg_h \gset
select ok(:'msg_h' like 'pg_partition_magician: public.sh340_pgpm_new already exists as a table, part of extension pgtap, and transmute needs that name as a staging name for the new parent.%',
  'H: refused on the staging name, naming the table and the extension it is part of: ' || coalesce(:'msg_h', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_h'), null, 'H: no DROP statement is named for it');
select lives_ok($$ alter table public.sh340_pgpm_new rename to sh340_kept $$, 'H: renaming it, as the refusal says, runs');
select is(to_regclass('public.sh340_pgpm_new'), null, 'H: and the staging name is free afterwards');
select to_regclass('public.sh340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sh340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sh340'::regclass), 'p', 'H: the same call then converts sh340');
alter extension pgtap drop table public.sh340_kept;

-- no conversion left a staging name behind
select is((select array_agg(c.relname::text order by c.relname) from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relname like '%340%pgpm_new'), null,
  'no staging name is left behind by any conversion');

select * from finish();
