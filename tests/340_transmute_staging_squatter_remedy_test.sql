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
--   (I) a foreign table holds si340's                     -> drop foreign table
--   (J) a free-standing partitioned index holds sj340's   -> drop index
--   (K) an identity column's sequence holds sk340's: no DROP named (drop sequence fails 2BP01 on it); the
--       refusal names the column, and renaming the sequence frees the name
--   (L) an index attached to a partitioned index holds sl340's: no DROP named (2BP01 again); the refusal
--       names the partitioned index, and renaming the attached one frees the name
--   (M) a composite type that is a member of an extension holds sm340's: its membership is recorded on the
--       type, not on its relation; no DROP named (drop type fails 2BP01), and renaming the type frees it
-- Holders something else depends on: PostgreSQL refuses the DROP for the holder's kind while the dependent
-- exists (2BP01, "other objects depend on it"), so no DROP is named for one, a table included; the refusal
-- names the dependent, and the rename frees the name:
--   (N) a serial column's sequence holds sn340's (the column's default reads it)
--   (O) control: a sequence a column owns, with no default reading it, holds so340's: nothing depends on
--       it, so it keeps its `drop sequence`, which works
--   (P) a view another view reads holds sp340's
--   (Q) a materialized view a view reads holds sq340's
--   (R) a composite type a table's column uses holds sr340's
--   (S) a table a foreign key references holds ss340's
--   (T) a partitioned table a foreign key references holds st340's
--   (U) a free-standing unique index a foreign key uses holds su340's
--   (V) a table holds sv340's whose own owned sequence is a member of an extension: nothing depends on the
--       table itself, yet DROP TABLE is refused for the extension; the refusal names the extension
-- bench/transmute_staging_squatter_remedy.sh runs this file against two mutants, so it is also required to
-- FAIL on each: one that routes every holder with no owner to the table remedy again
-- (staging_squatter_remedy_drop_table), and one that asks for a dependent of every kind but a table or a
-- partitioned table (staging_squatter_dependents_not_for_tables).
create extension if not exists pgtap;
select plan(159);

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

-- (I) a foreign table
create table public.si340 (id bigint primary key, body text);
insert into public.si340 select g, 'i' || g from generate_series(1, 10) g;
create foreign data wrapper fdw340;
create server srv340 foreign data wrapper fdw340;
create foreign table public.si340_pgpm_new (a int) server srv340;
select is((select relkind::text from pg_class where oid = 'public.si340_pgpm_new'::regclass), 'f',
  'LIVENESS: (I) a foreign table holds si340''s staging name');
select pg_temp.refusal340('public.si340') as msg_i \gset
select ok(:'msg_i' like 'pg_partition_magician: public.si340_pgpm_new already exists as a foreign table, and transmute needs that name as a staging name for the new parent.%',
  'I: refused on the staging name, naming the foreign table: ' || coalesce(:'msg_i', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_i'), 'drop foreign table public.si340_pgpm_new', 'I: the remedy named is the foreign table''s DROP');
select lives_ok(pg_temp.remedy340(:'msg_i'), 'I: the remedy, typed as named, runs');
select is(to_regclass('public.si340_pgpm_new'), null, 'I: and the staging name is free afterwards');
select to_regclass('public.si340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.si340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.si340'::regclass), 'p', 'I: the same call then converts si340');

-- (J) a free-standing partitioned index, on another (partitioned) table
create table public.sj340 (id bigint primary key, body text);
insert into public.sj340 select g, 'j' || g from generate_series(1, 11) g;
create table public.sj340_other (v int) partition by range (v);
create index sj340_pgpm_new on public.sj340_other (v);
select is((select relkind::text from pg_class where oid = 'public.sj340_pgpm_new'::regclass), 'I',
  'LIVENESS: (J) a partitioned index holds sj340''s staging name');
select pg_temp.refusal340('public.sj340') as msg_j \gset
select ok(:'msg_j' like 'pg_partition_magician: public.sj340_pgpm_new already exists as a partitioned index, and transmute needs that name as a staging name for the new parent.%',
  'J: refused on the staging name, naming the partitioned index: ' || coalesce(:'msg_j', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_j'), 'drop index public.sj340_pgpm_new', 'J: the remedy named is the index''s DROP');
select lives_ok(pg_temp.remedy340(:'msg_j'), 'J: the remedy, typed as named, runs');
select is(to_regclass('public.sj340_pgpm_new'), null, 'J: and the staging name is free afterwards');
select to_regclass('public.sj340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sj340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sj340'::regclass), 'p', 'J: the same call then converts sj340');
select ok(to_regclass('public.sj340_other') is not null, 'J: the table the index was on is untouched');

-- (K) an identity column's sequence: DROP SEQUENCE cannot drop it, so no DROP is named
create table public.sk340 (id bigint primary key, body text);
insert into public.sk340 select g, 'k' || g from generate_series(1, 12) g;
create table public.sk340_other (n bigint generated always as identity, note text);
alter sequence public.sk340_other_n_seq rename to sk340_pgpm_new;
select is((select relkind::text from pg_class where oid = 'public.sk340_pgpm_new'::regclass), 'S',
  'LIVENESS: (K) an identity column''s sequence holds sk340''s staging name');
select throws_ok($$ drop sequence public.sk340_pgpm_new $$, '2BP01', NULL,
  'LIVENESS: (K) and DROP SEQUENCE cannot drop it on its own');
select pg_temp.refusal340('public.sk340') as msg_k \gset
select ok(:'msg_k' like 'pg_partition_magician: public.sk340_pgpm_new already exists as a sequence, part of column n of table sk340_other, and transmute needs that name as a staging name for the new parent.%',
  'K: refused on the staging name, naming the sequence and the column it is part of: ' || coalesce(:'msg_k', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_k'), null, 'K: no DROP statement is named for it');
select lives_ok($$ alter sequence public.sk340_pgpm_new rename to sk340_other_n_seq $$, 'K: renaming it, as the refusal says, runs');
select is(to_regclass('public.sk340_pgpm_new'), null, 'K: and the staging name is free afterwards');
select to_regclass('public.sk340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sk340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sk340'::regclass), 'p', 'K: the same call then converts sk340');
insert into public.sk340_other (note) values ('first'), ('second');
select is((select array_agg(n order by n) from public.sk340_other), array[1, 2]::bigint[],
  'K: the other table''s identity column still draws from its sequence, under the new name');

-- (L) an index attached to a partitioned index: DROP INDEX cannot drop it either
create table public.sl340 (id bigint primary key, body text);
insert into public.sl340 select g, 'l' || g from generate_series(1, 13) g;
create table public.sl340_other (v int) partition by range (v);
create table public.sl340_other_1 partition of public.sl340_other for values from (0) to (10);
create index sl340_other_v on public.sl340_other (v);
alter index public.sl340_other_1_v_idx rename to sl340_pgpm_new;
select is((select relkind::text from pg_class where oid = 'public.sl340_pgpm_new'::regclass), 'i',
  'LIVENESS: (L) a partition''s attached index holds sl340''s staging name');
select throws_ok($$ drop index public.sl340_pgpm_new $$, '2BP01', NULL,
  'LIVENESS: (L) and DROP INDEX cannot drop it on its own');
select pg_temp.refusal340('public.sl340') as msg_l \gset
select ok(:'msg_l' like 'pg_partition_magician: public.sl340_pgpm_new already exists as an index, part of index sl340_other_v, and transmute needs that name as a staging name for the new parent.%',
  'L: refused on the staging name, naming the index and the partitioned index it is part of: ' || coalesce(:'msg_l', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_l'), null, 'L: no DROP statement is named for it');
select lives_ok($$ alter index public.sl340_pgpm_new rename to sl340_other_1_v_idx $$, 'L: renaming it, as the refusal says, runs');
select is(to_regclass('public.sl340_pgpm_new'), null, 'L: and the staging name is free afterwards');
select to_regclass('public.sl340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sl340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sl340'::regclass), 'p', 'L: the same call then converts sl340');
select is((select inhparent::regclass::text from pg_inherits where inhrelid = 'public.sl340_other_1_v_idx'::regclass),
  'sl340_other_v', 'L: the index is still attached to its partitioned index, under the new name');

-- (M) a composite type that is a member of an extension: PostgreSQL records the membership on the type, not
-- on its relation, and DROP TYPE cannot drop it on its own
create table public.sm340 (id bigint primary key, body text);
insert into public.sm340 select g, 'm' || g from generate_series(1, 14) g;
create type public.sm340_pgpm_new as (a int, b text);
alter extension pgtap add type public.sm340_pgpm_new;
select ok((select c.relkind = 'c' from pg_class c where c.oid = 'public.sm340_pgpm_new'::regclass)
          and exists (select 1 from pg_depend d where d.classid = 'pg_type'::regclass
                         and d.objid = 'public.sm340_pgpm_new'::regtype and d.deptype = 'e'),
  'LIVENESS: (M) a composite type that is a member of an extension holds sm340''s staging name');
select throws_ok($$ drop type public.sm340_pgpm_new $$, '2BP01', NULL,
  'LIVENESS: (M) and DROP TYPE cannot drop it on its own');
select pg_temp.refusal340('public.sm340') as msg_m \gset
select ok(:'msg_m' like 'pg_partition_magician: public.sm340_pgpm_new already exists as a composite type, part of extension pgtap, and transmute needs that name as a staging name for the new parent.%',
  'M: refused on the staging name, naming the composite type and the extension it is part of: ' || coalesce(:'msg_m', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_m'), null, 'M: no DROP statement is named for it');
select lives_ok($$ alter type public.sm340_pgpm_new rename to sm340_kept $$, 'M: renaming it, as the refusal says, runs');
select ok(to_regclass('public.sm340_pgpm_new') is null and to_regtype('public.sm340_pgpm_new') is null,
  'M: and the staging name is free afterwards, as a relation and as a type');
select to_regclass('public.sm340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sm340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sm340'::regclass), 'p', 'M: the same call then converts sm340');
alter extension pgtap drop type public.sm340_kept;

-- ====================================================================================================
-- Holders something else DEPENDS on. The DROP for the holder's kind is refused by PostgreSQL while the
-- dependent exists (2BP01, "other objects depend on it"), so the refusal names no DROP for one: it names
-- the dependent, and the rename, which works. Each part's LIVENESS types the DROP and shows the 2BP01 is
-- the dependents' one (the owner parts above get PostgreSQL's other 2BP01, "requires it").
-- ====================================================================================================

-- (N) a serial column's sequence: the column's default reads it
create table public.sn340 (id bigint primary key, body text);
insert into public.sn340 select g, 'n' || g from generate_series(1, 15) g;
create table public.sn340_other (n serial, note text);
alter sequence public.sn340_other_n_seq rename to sn340_pgpm_new;
select is((select relkind::text from pg_class where oid = 'public.sn340_pgpm_new'::regclass), 'S',
  'LIVENESS: (N) a serial column''s sequence holds sn340''s staging name');
select throws_like($$ drop sequence public.sn340_pgpm_new $$, '%because other objects depend on it%',
  'LIVENESS: (N) and DROP SEQUENCE is refused while the column''s default depends on it');
select pg_temp.refusal340('public.sn340') as msg_n \gset
select ok(:'msg_n' like 'pg_partition_magician: public.sn340_pgpm_new already exists as a sequence, and transmute needs that name as a staging name for the new parent. PostgreSQL refuses to drop it while default value for column n of table sn340_other depends on it,%',
  'N: refused on the staging name, naming the sequence and the default that depends on it: ' || coalesce(:'msg_n', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_n'), null, 'N: no DROP statement is named for it');
select lives_ok($$ alter sequence public.sn340_pgpm_new rename to sn340_other_n_seq $$, 'N: renaming it, as the refusal says, runs');
select is(to_regclass('public.sn340_pgpm_new'), null, 'N: and the staging name is free afterwards');
select to_regclass('public.sn340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sn340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sn340'::regclass), 'p', 'N: the same call then converts sn340');
insert into public.sn340_other (note) values ('first'), ('second'), ('third');
select is((select array_agg(n order by n) from public.sn340_other), array[1, 2, 3],
  'N: the other table''s serial column still draws from its sequence, under the new name');

-- (O) control: a sequence a column OWNS, with no default reading it. Nothing depends on it (it depends on
-- the column), so its DROP works and is still named.
create table public.so340 (id bigint primary key, body text);
insert into public.so340 select g, 'o' || g from generate_series(1, 16) g;
create table public.so340_other (n bigint, note text);
create sequence public.so340_pgpm_new owned by public.so340_other.n;
select ok(exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass
                     and d.objid = 'public.so340_pgpm_new'::regclass and d.deptype = 'a'
                     and d.refobjid = 'public.so340_other'::regclass)
          and not exists (select 1 from pg_depend d where d.refclassid = 'pg_class'::regclass
                             and d.refobjid = 'public.so340_pgpm_new'::regclass),
  'LIVENESS: (O) a sequence so340_other.n owns, and nothing depends on, holds so340''s staging name');
select pg_temp.refusal340('public.so340') as msg_o \gset
select ok(:'msg_o' like 'pg_partition_magician: public.so340_pgpm_new already exists as a sequence, and transmute needs that name as a staging name for the new parent. Drop it (%',
  'O: refused on the staging name, with a DROP: ' || coalesce(:'msg_o', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_o'), 'drop sequence public.so340_pgpm_new', 'O: the remedy named is the sequence''s DROP');
select lives_ok(pg_temp.remedy340(:'msg_o'), 'O: the remedy, typed as named, runs');
select is(to_regclass('public.so340_pgpm_new'), null, 'O: and the staging name is free afterwards');
select to_regclass('public.so340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.so340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.so340'::regclass), 'p', 'O: the same call then converts so340');
select ok(to_regclass('public.so340_other') is not null, 'O: the table whose column owned the sequence is untouched');

-- (P) a view another view reads
create table public.sp340 (id bigint primary key, body text);
insert into public.sp340 select g, 'p' || g from generate_series(1, 17) g;
create view public.sp340_pgpm_new as select 41 as one;
create view public.sp340_reader as select one + 1 as two from public.sp340_pgpm_new;
select is((select relkind::text from pg_class where oid = 'public.sp340_pgpm_new'::regclass), 'v',
  'LIVENESS: (P) a view holds sp340''s staging name');
select throws_like($$ drop view public.sp340_pgpm_new $$, '%because other objects depend on it%',
  'LIVENESS: (P) and DROP VIEW is refused while another view reads it');
select pg_temp.refusal340('public.sp340') as msg_p \gset
select ok(:'msg_p' like 'pg_partition_magician: public.sp340_pgpm_new already exists as a view, and transmute needs that name as a staging name for the new parent. PostgreSQL refuses to drop it while view sp340_reader depends on it,%',
  'P: refused on the staging name, naming the view and the view that reads it: ' || coalesce(:'msg_p', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_p'), null, 'P: no DROP statement is named for it');
select lives_ok($$ alter view public.sp340_pgpm_new rename to sp340_kept $$, 'P: renaming it, as the refusal says, runs');
select is(to_regclass('public.sp340_pgpm_new'), null, 'P: and the staging name is free afterwards');
select to_regclass('public.sp340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sp340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sp340'::regclass), 'p', 'P: the same call then converts sp340');
select is((select two from public.sp340_reader), 42, 'P: the reading view still reads the renamed view');

-- (Q) a materialized view another view reads
create table public.sq340 (id bigint primary key, body text);
insert into public.sq340 select g, 'q' || g from generate_series(1, 18) g;
create materialized view public.sq340_pgpm_new as select 6 as six;
create view public.sq340_reader as select six * 7 as answer from public.sq340_pgpm_new;
select is((select relkind::text from pg_class where oid = 'public.sq340_pgpm_new'::regclass), 'm',
  'LIVENESS: (Q) a materialized view holds sq340''s staging name');
select throws_like($$ drop materialized view public.sq340_pgpm_new $$, '%because other objects depend on it%',
  'LIVENESS: (Q) and DROP MATERIALIZED VIEW is refused while a view reads it');
select pg_temp.refusal340('public.sq340') as msg_q \gset
select ok(:'msg_q' like 'pg_partition_magician: public.sq340_pgpm_new already exists as a materialized view, and transmute needs that name as a staging name for the new parent. PostgreSQL refuses to drop it while view sq340_reader depends on it,%',
  'Q: refused on the staging name, naming the materialized view and the view that reads it: ' || coalesce(:'msg_q', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_q'), null, 'Q: no DROP statement is named for it');
select lives_ok($$ alter materialized view public.sq340_pgpm_new rename to sq340_kept $$, 'Q: renaming it, as the refusal says, runs');
select is(to_regclass('public.sq340_pgpm_new'), null, 'Q: and the staging name is free afterwards');
select to_regclass('public.sq340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sq340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sq340'::regclass), 'p', 'Q: the same call then converts sq340');
select is((select answer from public.sq340_reader), 42, 'Q: the reading view still reads the renamed materialized view');

-- (R) a composite type a table's column uses
create table public.sr340 (id bigint primary key, body text);
insert into public.sr340 select g, 'r' || g from generate_series(1, 19) g;
create type public.sr340_pgpm_new as (a int, b text);
create table public.sr340_other (c public.sr340_pgpm_new);
select is((select relkind::text from pg_class where oid = 'public.sr340_pgpm_new'::regclass), 'c',
  'LIVENESS: (R) a composite type holds sr340''s staging name');
select throws_like($$ drop type public.sr340_pgpm_new $$, '%because other objects depend on it%',
  'LIVENESS: (R) and DROP TYPE is refused while a column is of that type');
select pg_temp.refusal340('public.sr340') as msg_r \gset
select ok(:'msg_r' like 'pg_partition_magician: public.sr340_pgpm_new already exists as a composite type, and transmute needs that name as a staging name for the new parent. PostgreSQL refuses to drop it while column c of table sr340_other depends on it,%',
  'R: refused on the staging name, naming the composite type and the column of that type: ' || coalesce(:'msg_r', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_r'), null, 'R: no DROP statement is named for it');
select lives_ok($$ alter type public.sr340_pgpm_new rename to sr340_kept $$, 'R: renaming it, as the refusal says, runs');
select ok(to_regclass('public.sr340_pgpm_new') is null and to_regtype('public.sr340_pgpm_new') is null,
  'R: and the staging name is free afterwards, as a relation and as a type');
select to_regclass('public.sr340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sr340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sr340'::regclass), 'p', 'R: the same call then converts sr340');
select is((select format_type(a.atttypid, null) from pg_attribute a
            where a.attrelid = 'public.sr340_other'::regclass and a.attname = 'c'), 'sr340_kept',
  'R: the other table''s column is still of that type, under the new name');

-- (S) a table another table's foreign key references: the table branch, whose remedy was `drop table`
create table public.ss340 (id bigint primary key, body text);
insert into public.ss340 select g, 's' || g from generate_series(1, 20) g;
create table public.ss340_pgpm_new (k int, constraint ss340_held_k primary key (k));
create table public.ss340_ref (r int, constraint ss340_ref_fk foreign key (r) references public.ss340_pgpm_new);
select is((select relkind::text from pg_class where oid = 'public.ss340_pgpm_new'::regclass), 'r',
  'LIVENESS: (S) a table holds ss340''s staging name');
select throws_like($$ drop table public.ss340_pgpm_new $$, '%because other objects depend on it%',
  'LIVENESS: (S) and DROP TABLE is refused while a foreign key references it');
select pg_temp.refusal340('public.ss340') as msg_s \gset
select ok(:'msg_s' like 'pg_partition_magician: public.ss340_pgpm_new already exists as a table, and transmute needs that name as a staging name for the new parent. PostgreSQL refuses to drop it while constraint ss340_ref_fk on table ss340_ref depends on it,%',
  'S: refused on the staging name, naming the table and the foreign key that references it: ' || coalesce(:'msg_s', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_s'), null, 'S: no DROP statement is named for it');
select lives_ok($$ alter table public.ss340_pgpm_new rename to ss340_kept $$, 'S: renaming it, as the refusal says, runs');
select is(to_regclass('public.ss340_pgpm_new'), null, 'S: and the staging name is free afterwards');
select to_regclass('public.ss340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.ss340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.ss340'::regclass), 'p', 'S: the same call then converts ss340');
select is((select confrelid::regclass::text from pg_constraint where conname = 'ss340_ref_fk'
            and conrelid = 'public.ss340_ref'::regclass), 'ss340_kept',
  'S: the foreign key still references the table, under its new name');

-- (T) a PARTITIONED table a foreign key references: the same branch, for the shape an interrupted run leaves
create table public.st340 (id bigint primary key, body text);
insert into public.st340 select g, 't' || g from generate_series(1, 21) g;
create table public.st340_pgpm_new (k int, constraint st340_held_k primary key (k)) partition by range (k);
create table public.st340_ref (r int, constraint st340_ref_fk foreign key (r) references public.st340_pgpm_new);
select is((select relkind::text from pg_class where oid = 'public.st340_pgpm_new'::regclass), 'p',
  'LIVENESS: (T) a partitioned table holds st340''s staging name');
select throws_like($$ drop table public.st340_pgpm_new $$, '%because other objects depend on it%',
  'LIVENESS: (T) and DROP TABLE is refused while a foreign key references it');
select pg_temp.refusal340('public.st340') as msg_t \gset
select ok(:'msg_t' like 'pg_partition_magician: public.st340_pgpm_new already exists as a partitioned table, and transmute needs that name as a staging name for the new parent. PostgreSQL refuses to drop it while constraint st340_ref_fk on table st340_ref depends on it,%',
  'T: refused on the staging name, naming the partitioned table and the foreign key that references it: ' || coalesce(:'msg_t', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_t'), null, 'T: no DROP statement is named for it');
select lives_ok($$ alter table public.st340_pgpm_new rename to st340_kept $$, 'T: renaming it, as the refusal says, runs');
select is(to_regclass('public.st340_pgpm_new'), null, 'T: and the staging name is free afterwards');
select to_regclass('public.st340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.st340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.st340'::regclass), 'p', 'T: the same call then converts st340');
select is((select confrelid::regclass::text from pg_constraint where conname = 'st340_ref_fk'
            and conrelid = 'public.st340_ref'::regclass), 'st340_kept',
  'T: the foreign key still references the partitioned table, under its new name');

-- (U) a free-standing unique index a foreign key uses
create table public.su340 (id bigint primary key, body text);
insert into public.su340 select g, 'u' || g from generate_series(1, 22) g;
create table public.su340_other (v int not null);
create unique index su340_pgpm_new on public.su340_other (v);
create table public.su340_ref (r int, constraint su340_ref_fk foreign key (r) references public.su340_other (v));
select is((select relkind::text from pg_class where oid = 'public.su340_pgpm_new'::regclass), 'i',
  'LIVENESS: (U) a unique index holds su340''s staging name');
select throws_like($$ drop index public.su340_pgpm_new $$, '%because other objects depend on it%',
  'LIVENESS: (U) and DROP INDEX is refused while a foreign key uses it');
select pg_temp.refusal340('public.su340') as msg_u \gset
select ok(:'msg_u' like 'pg_partition_magician: public.su340_pgpm_new already exists as an index, and transmute needs that name as a staging name for the new parent. PostgreSQL refuses to drop it while constraint su340_ref_fk on table su340_ref depends on it,%',
  'U: refused on the staging name, naming the index and the foreign key that uses it: ' || coalesce(:'msg_u', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_u'), null, 'U: no DROP statement is named for it');
select lives_ok($$ alter index public.su340_pgpm_new rename to su340_other_v_key $$, 'U: renaming it, as the refusal says, runs');
select is(to_regclass('public.su340_pgpm_new'), null, 'U: and the staging name is free afterwards');
select to_regclass('public.su340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.su340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.su340'::regclass), 'p', 'U: the same call then converts su340');
select is((select conindid::regclass::text from pg_constraint where conname = 'su340_ref_fk'
            and conrelid = 'public.su340_ref'::regclass), 'su340_other_v_key',
  'U: the foreign key still uses the index, under its new name');

-- (V) a table one of whose OWN parts belongs to something else: a sequence its column owns is a member of
-- an extension. DROP TABLE would take the sequence along, PostgreSQL then asks for the extension, and
-- refuses; nothing has a normal dependency on the table at all.
create table public.sv340 (id bigint primary key, body text);
insert into public.sv340 select g, 'v' || g from generate_series(1, 23) g;
create table public.sv340_pgpm_new (k bigint);
create sequence public.sv340_owned owned by public.sv340_pgpm_new.k;
alter extension pgtap add sequence public.sv340_owned;
select ok((select c.relkind = 'r' from pg_class c where c.oid = 'public.sv340_pgpm_new'::regclass)
          and not exists (select 1 from pg_depend d where d.refclassid = 'pg_class'::regclass
                             and d.refobjid = 'public.sv340_pgpm_new'::regclass and d.deptype = 'n'),
  'LIVENESS: (V) a table nothing has a normal dependency on holds sv340''s staging name');
select throws_like($$ drop table public.sv340_pgpm_new $$, '%because other objects depend on it%',
  'LIVENESS: (V) and DROP TABLE is refused, for the extension its owned sequence is a member of');
select pg_temp.refusal340('public.sv340') as msg_v \gset
select ok(:'msg_v' like 'pg_partition_magician: public.sv340_pgpm_new already exists as a table, and transmute needs that name as a staging name for the new parent. PostgreSQL refuses to drop it while extension pgtap depends on it,%',
  'V: refused on the staging name, naming the table and the extension: ' || coalesce(:'msg_v', '(no refusal)'));
select is(pg_temp.remedy340(:'msg_v'), null, 'V: no DROP statement is named for it');
select lives_ok($$ alter table public.sv340_pgpm_new rename to sv340_kept $$, 'V: renaming it, as the refusal says, runs');
select is(to_regclass('public.sv340_pgpm_new'), null, 'V: and the staging name is free afterwards');
select to_regclass('public.sv340_pgpm_new') is null as free \gset
\if :free
call pgpm.transmute('public.sv340', 'id', 100::bigint, p_obtain => 2);
\endif
select is((select relkind::text from pg_class where oid = 'public.sv340'::regclass), 'p', 'V: the same call then converts sv340');
alter extension pgtap drop sequence public.sv340_owned;

-- no conversion left a staging name behind
select is((select array_agg(c.relname::text order by c.relname) from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relname like '%340%pgpm_new'), null,
  'no staging name is left behind by any conversion');

select * from finish();
