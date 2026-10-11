-- Issue #707: the name-keyed sites left after #631 (regrain) and #671 (transmute's name guards).
--
-- pgpm.part records WHICH relation a fine child is (child_oid, #421), and #631 made the copy branch check
-- it. Four other sites still acted on whatever answered to a recorded NAME, or asked pg_class alone
-- whether a name was free:
--
-- (A) the swap's attach loop ATTACHed `%I.%I` of each copy's recorded name and dropped that relation's
--     `<name>_ck`. A completed copy renamed aside and a table created under its old name LIKE it
--     INCLUDING ALL (so it carries the `_ck`) was attached, the source dropped, and the copied rows of
--     that sub-range left the managed table: Tier 1, not the rollback the issue first assumed. The swap
--     now resolves every copy through _regrain_copy_rel before it suspends an FK or takes a lock, and
--     attaches the resolved relation, so it refuses with nothing mutated.
-- (B) regrain_cancel dropped the capture and TRUNCATE-guard triggers `on %I.%I` of every pgpm.part row's
--     name, so a source renamed aside kept its pgpm triggers (TRUNCATE refused for good, every write
--     taxed into a delta nobody reads) and a relation that took its name lost its own triggers of those
--     names. It now drops them from the relation each row's child_oid recorded.
-- (C) regrain_step's create branch inserted the new copy's pgpm.part row `on conflict do nothing`, so a
--     row already holding the rendered name over OTHER bounds went on describing a different range
--     while the copy filled the new table. It now refuses before creating anything.
-- (D) obtain's cell-name check asked to_regclass only, so a TYPE holding a forward cell's name made the
--     CREATE TABLE fail with 42710 and took every other cell of the call down with it, on every tick. A
--     type holding the name now leaves that one cell unbuilt, as a relation pgpm does not own does.
-- (E) transmute's orphan-child guard looked in pg_class only, so the same type passed the conversion
--     and (D) met it on the first tick. It now refuses up front, naming the type, through _type_squatter.
--
-- Fixtures are asymmetric (three rows in the renamed copy, none in the squatter; three cells built around
-- one squatted cell) and every row and cell is named. Each refusal is pinned by its message.
-- bench/regrain_child_oid_sites.sh runs this file against one mutant per site, so it is also required
-- to FAIL there.
create extension if not exists pgtap;
select plan(34);

set timezone = 'UTC';

-- ======================================================================================================
-- (A) the swap attaches the copy pgpm.part recorded, or refuses
-- ======================================================================================================
create table public.sw7 (id bigint primary key, payload text);
insert into public.sw7 values (10, 'a'), (20, 'b'), (30, 'c'), (150000, 'd'), (1999999, 'widen');
call pgpm.transmute('public.sw7', 'id', 1000000);
select pgpm.obtain('public.sw7');
insert into public.sw7 values (3500000, 'frontier');
select child_name as sw7_src, child_oid as sw7_src_oid from pgpm.part
 where parent_table = 'public.sw7'::regclass and attached order by lo::numeric limit 1 \gset

select is(pgpm.regrain_step('public.sw7', :'sw7_src', '100000', 1000), 'prepared', 'fixture: (A) the prepare tick');
select is(pgpm.regrain_step('public.sw7', :'sw7_src', '100000', 1000), 'copied:3',
  'fixture: (A) sub-range [0, 100000) is copied whole in one short batch');
select child_oid as sw7_copy_oid from pgpm.part
 where parent_table = 'public.sw7'::regclass and not attached and child_name = 'sw7_p0000000000000000000' \gset

alter table public.sw7_p0000000000000000000 rename to sw7_copy_aside;
create table public.sw7_p0000000000000000000 (like public.sw7_copy_aside including all);

select ok(:sw7_copy_oid = 'public.sw7_copy_aside'::regclass::oid
          and (select array_agg(id order by id) from public.sw7_copy_aside) = array[10, 20, 30]::bigint[],
  'LIVENESS: (A) the recorded copy of [0, 100000), by oid, is the renamed table holding 10, 20, 30');
select ok('public.sw7_p0000000000000000000'::regclass::oid <> :sw7_copy_oid
          and not exists (select 1 from public.sw7_p0000000000000000000)
          and exists (select 1 from pg_constraint where conrelid = 'public.sw7_p0000000000000000000'::regclass
                         and conname = 'sw7_p0000000000000000000_ck'),
  'LIVENESS: (A) an empty, unrelated table bears the copy''s name and carries its _ck, so an ATTACH would go through');

select throws_like(
  format($$select pgpm.regrain('public.sw7', %L, '100000')$$, :'sw7_src'),
  'pg_partition_magician: cannot attach the regrain copy public.sw7_p0000000000000000000 of public.sw7 for [0, 100000) -- that name resolves to oid %, and no longer names the copy this regrain created (oid ' || :sw7_copy_oid || ', now public.sw7_copy_aside)%',
  'A: the swap refuses: the copy''s name no longer resolves to the relation pgpm.part recorded');
select is((select array_agg(id || ':' || payload order by id) from public.sw7 where id < 100000),
  array['10:a', '20:b', '30:c'], 'A: every row of [0, 100000) is still readable through the managed table');
select ok(not exists (select 1 from pg_inherits where inhrelid = 'public.sw7_p0000000000000000000'::regclass),
  'A: the unrelated table was not attached as a partition');
select is((select inhparent::regclass::text from pg_inherits where inhrelid = :sw7_src_oid), 'sw7',
  'A: the source is still attached: the refused swap mutated nothing');

drop table public.sw7_p0000000000000000000;
alter table public.sw7_copy_aside rename to sw7_p0000000000000000000;
select is(pgpm.regrain('public.sw7', :'sw7_src', '100000'), 20,
  'LIVENESS: (A) with the copy back under its name the same run swaps, twenty fine children attached over the source''s [0, 2000000)');
select is((select inhrelid from pg_inherits where inhrelid = 'public.sw7_p0000000000000000000'::regclass), :sw7_copy_oid::oid,
  'A: the partition attached for [0, 100000) is the copy pgpm.part recorded');
select is((select array_agg(id || ':' || payload order by id) from public.sw7 where id < 200000),
  array['10:a', '20:b', '30:c', '150000:d'], 'A: the managed table holds exactly the copied rows after the swap');

-- ======================================================================================================
-- (B) regrain_cancel drops the regrain's triggers from the relations pgpm.part recorded
-- ======================================================================================================
create table public.cn7 (id bigint primary key, payload text);
insert into public.cn7 values (10, 'a'), (150000, 'b'), (1999999, 'widen');
call pgpm.transmute('public.cn7', 'id', 1000000);
select pgpm.obtain('public.cn7');
insert into public.cn7 values (3500000, 'frontier');
select child_name as cn7_src, child_oid as cn7_src_oid from pgpm.part
 where parent_table = 'public.cn7'::regclass and attached order by lo::numeric limit 1 \gset
select is(pgpm.regrain_step('public.cn7', :'cn7_src', '100000', 1000), 'prepared', 'fixture: (B) the prepare tick');

alter table public.:"cn7_src" rename to cn7_src_aside;
create table public.:"cn7_src" (id bigint);
create function public.cn7_own_trigger() returns trigger language plpgsql as $f$ begin return null; end $f$;
create trigger pgpm_regrain_capture after insert on public.:"cn7_src" for each row execute function public.cn7_own_trigger();
create trigger pgpm_regrain_truncate_guard before truncate on public.:"cn7_src" for each statement execute function public.cn7_own_trigger();

select is((select array_agg(tgname::text order by tgname) from pg_trigger where tgrelid = :cn7_src_oid and not tgisinternal),
  array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard'],
  'LIVENESS: (B) the recorded source, renamed aside, carries the regrain''s capture and TRUNCATE guard');
select is((select array_agg(tgname::text order by tgname) from pg_trigger
            where tgrelid = format('public.%I', :'cn7_src')::regclass and not tgisinternal),
  array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard'],
  'LIVENESS: (B) an unrelated table under the source''s old name carries its own triggers of those two names');

select is(pgpm.regrain_cancel('public.cn7'), 0, 'B: regrain_cancel runs (no copy existed yet)');
select is((select count(*)::int from pg_trigger where tgrelid = :cn7_src_oid and not tgisinternal), 0,
  'B: the recorded source no longer carries either regrain trigger');
select is((select array_agg(tgname::text order by tgname) from pg_trigger
            where tgrelid = format('public.%I', :'cn7_src')::regclass and not tgisinternal),
  array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard'],
  'B: the unrelated table keeps both of its own triggers');
select lives_ok('truncate public.cn7_src_aside',
  'B: TRUNCATE of the recorded source is no longer refused by a leftover guard');

-- ======================================================================================================
-- (C) the create branch refuses a pgpm.part row that holds the rendered name over other bounds
-- ======================================================================================================
create table public.cr7 (id bigint primary key, payload text);
insert into public.cr7 values (10, 'a'), (150000, 'b'), (1999999, 'widen');
call pgpm.transmute('public.cr7', 'id', 1000000);
select pgpm.obtain('public.cr7');
insert into public.cr7 values (3500000, 'frontier');
select child_name as cr7_src from pgpm.part
 where parent_table = 'public.cr7'::regclass and attached order by lo::numeric limit 1 \gset
select is(pgpm.regrain_step('public.cr7', :'cr7_src', '100000', 1000), 'prepared', 'fixture: (C) the prepare tick');
select is(pgpm.regrain_step('public.cr7', :'cr7_src', '100000', 1000), 'copied:1',
  'fixture: (C) sub-range [0, 100000) is copied whole');
insert into pgpm.part (parent_table, child_name, lo, hi, attached)
  values ('public.cr7', 'cr7_p0000000000000100000', '700000', '800000', false);

select ok((select regrain_cursor from pgpm.config where parent_table = 'public.cr7'::regclass) = '100000'
          and pgpm._part_name('cr7', 'id', '100000', '100000', '200000', 'UTC') = 'cr7_p0000000000000100000'
          and to_regclass('public.cr7_p0000000000000100000') is null,
  'LIVENESS: (C) the next sub-range [100000, 200000) renders cr7_p0000000000000100000, which no relation holds');
select throws_like(
  format($$select pgpm.regrain_step('public.cr7', %L, '100000', 1000)$$, :'cr7_src'),
  'pg_partition_magician: cannot regrain % -- the fine child for sub-range [100000, 200000) would be public.cr7_p0000000000000100000, but pgpm.part already records that name for public.cr7 over [700000, 800000)%',
  'C: regrain_step refuses before creating a copy its pgpm.part row would not describe');
select is(to_regclass('public.cr7_p0000000000000100000'), null, 'C: no relation was created under the name');
select is((select lo || '..' || hi from pgpm.part where parent_table = 'public.cr7'::regclass
            and child_name = 'cr7_p0000000000000100000'), '700000..800000', 'C: the existing row is unchanged');
delete from pgpm.part where parent_table = 'public.cr7'::regclass and child_name = 'cr7_p0000000000000100000';
select is(pgpm.regrain_step('public.cr7', :'cr7_src', '100000', 1000), 'copied:1',
  'LIVENESS: (C) without that row the same tick creates the copy and copies row 150000 into it');

-- ======================================================================================================
-- (D) obtain leaves a cell whose name a TYPE holds unbuilt, and builds the rest
-- ======================================================================================================
create table public.ob7 (id bigint primary key, payload text);
insert into public.ob7 values (10, 'a'), (250000, 'b');
call pgpm.transmute('public.ob7', 'id', 100000, p_obtain => 0);
create type public.ob7_p0000000000000400000 as enum ('x');
select pgpm.set_obtain('public.ob7', 4);

select ok(pgpm._part_name('ob7', 'id', '100000', '400000', '500000', 'UTC') = 'ob7_p0000000000000400000'
          and to_regclass('public.ob7_p0000000000000400000') is null
          and pgpm._type_squatter('public', 'ob7_p0000000000000400000') = 'an enum type',
  'LIVENESS: (D) forward cell [400000, 500000) renders a name an enum holds and no relation does');
select is((select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = 'public.ob7'::regclass),
  array['0'], 'LIVENESS: (D) before obtain the monolith is the only partition');
select is(pgpm.obtain('public.ob7'), 3, 'D: obtain builds three cells instead of failing on the squatted one');
select is((select array_agg(lo || '..' || hi order by lo::numeric) from pgpm.part where parent_table = 'public.ob7'::regclass),
  array['0..300000', '300000..400000', '500000..600000', '600000..700000'],
  'D: the cells on both sides of the squatted one are built; the squatted cell is not');
select is((select enum_range(null::public.ob7_p0000000000000400000)::text), '{x}', 'D: the enum is untouched');

-- ======================================================================================================
-- (E) transmute's orphan-child guard sees a TYPE holding a child's name
-- ======================================================================================================
create table public.or7 (id bigint primary key, payload text);
insert into public.or7 values (10, 'a'), (250000, 'b');
create domain public.or7_p0000000000000500000 as int;
select ok(to_regclass('public.or7_p0000000000000500000') is null
          and to_regtype('public.or7_p0000000000000500000') is not null,
  'LIVENESS: (E) a child-shaped name of or7 is free as a relation and taken as a domain');
select throws_like($$ call pgpm.transmute('public.or7', 'id', 100000::bigint) $$,
  'pg_partition_magician: public.or7_p0000000000000500000 already exists as a domain matching this parent''s partition naming%',
  'E: transmute refuses up front, naming the domain');
select is((select relkind::text from pg_class where oid = 'public.or7'::regclass), 'r', 'E: or7 is still a plain table');
alter domain public.or7_p0000000000000500000 rename to or7_elsewhere;
call pgpm.transmute('public.or7', 'id', 100000::bigint);
select is((select relkind::text from pg_class where oid = 'public.or7'::regclass), 'p',
  'LIVENESS: (E) with the domain renamed away the same call converts or7');

select * from finish();
