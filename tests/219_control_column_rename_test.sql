-- A renamed control column is followed, not lost (issue #826).
--
-- THE BUG. pgpm.config.control_column records the control column by NAME, and every reader resolved it by
-- that name: obtain's ceiling check read the column's type by attname, _frontier_native read max(<name>),
-- extend_to, untransmute's monolith CHECK, regrain's copy and its step-shape refusals, set_partition_tz's
-- naive-column refusal. PostgreSQL allows ALTER TABLE ... RENAME COLUMN of a partition-key column (the key
-- is held by attnum) and the table keeps routing, but from then on obtain's type lookup found nothing, its
-- ceiling check ran `select '<bound>'::` and raised a syntax error, every tick logged skip_obtain and the
-- forward grid never grew again: once the lookahead was used up every write was refused. The readers that
-- did not raise failed OPEN instead: a type lookup that finds nothing reads as "not naive" and "not an
-- integer", so set_partition_tz moved a naive grid's zone and set_regrain stored a step no tick can place.
--
-- THE CONTRACT. pgpm resolves the control column through the parent's partition key (its attnum), so
-- after a rename every reader acts on the column under its new name, exactly as before the rename:
--   PART A  time grid: the obtain tick builds exactly the missing forward cells, logs no skip_obtain, and a
--           write inside the raised lookahead lands in the cell built for it.
--   PART B  id grid: obtain reads the frontier from the renamed column and builds exactly the cells past
--           it; extend_to builds exactly the cells up to its target; writes land in the cells built.
--   PART C  regrain: set_regrain's integer-step refusal still sees the bigint column (and names it by its
--           new name), and a regrain of the monolith copies every row into the fine cell its key places.
--   PART D  set_partition_tz still refuses to move a NAIVE (timestamp) grid's zone, naming the new name,
--           and the zone stays UTC.
--   PART E  untransmute hands the table back whole, under the column's new name.
--   PART F  the class, not the five sites above: every load of a whole config row in pgpm's installed code
--           is followed by pgpm._control_followed, so a reader added later cannot quietly take the stale name.
--
-- ASYMMETRIC FIXTURES. Every table holds a different set of ids, and the cells each step must build are
-- named by their bounds, so a missing cell, an extra one, a lost row or a resurrected one cannot stand in
-- for the right answer.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(30);

create schema pgpm_t219;

-- the lower bounds of the attached cells at or above p_from, in grid order (numeric: an id grid)
create function pgpm_t219.cells_from(p_parent regclass, p_from numeric) returns numeric[] language sql as $$
  select array_agg(lo::numeric order by lo::numeric) from pgpm.part
   where parent_table = p_parent and attached and lo::numeric >= p_from
$$;
-- a statement's result as text, or its error: a defect in one part is reported by that part's assertions
-- rather than aborting the file (pg_prove stops at the first top-level error) and hiding every part after it
create function pgpm_t219.run(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  if p_sql ~* '^\s*select' then execute p_sql into v; else execute p_sql; end if;
  return coalesce(v, 'done');
exception when others then
  return 'ERROR: ' || sqlerrm;
end;
$$;
-- the [lo, hi) of the cell a row's ACTUAL relation is registered under, by oid (tableoid), never by name
create function pgpm_t219.home(p_parent regclass, p_tableoid oid) returns text language sql as $$
  select lo || '..' || hi from pgpm.part where parent_table = p_parent and child_oid = p_tableoid
$$;

-- ==================== PART A: a time grid's obtain tick ====================================================
create table pgpm_t219.tg (id bigint, at timestamptz, payload text, primary key (id, at));
insert into pgpm_t219.tg values (1, now(), 'a'), (2, now() - interval '2 days', 'b');
call pgpm.transmute('pgpm_t219.tg', 'at', '1 day'::interval, p_obtain => 3, p_paused => false);
create temporary table a_base as
  select max(hi::timestamptz) as top from pgpm.part where parent_table = 'pgpm_t219.tg'::regclass and attached;

alter table pgpm_t219.tg rename column at to created_at;
select is(pg_get_partkeydef('pgpm_t219.tg'::regclass), 'RANGE (created_at)',
  'A LIVENESS: the partition key column is now created_at');
select is((select count(*)::int from pg_attribute where attrelid = 'pgpm_t219.tg'::regclass and attname = 'at'), 0,
  'A LIVENESS: no column of the table answers to the registered name any more');
select throws_like(format($$ insert into pgpm_t219.tg values (3, %L, 'past the grid') $$, (select top from a_base) + interval '12 hours'),
  '%no partition of relation%',
  'A LIVENESS: a write one cell past the grid has nowhere to go before the tick');

select pgpm.set_obtain('pgpm_t219.tg', 5);
create temporary table a_tick (s text);
do $$ declare s text; begin call pgpm.maintain_obtain('pgpm_t219.tg', s); insert into a_tick values (s); end $$;
select ok((select s from a_tick) ~ '^obtained=', 'A LIVENESS: the obtain tick ran (not paused)');

select is((select array_agg(lo::timestamptz order by lo::timestamptz) from pgpm.part
            where parent_table = 'pgpm_t219.tg'::regclass and attached and lo::timestamptz >= (select top from a_base)),
  array[(select top from a_base), (select top from a_base) + interval '1 day'],
  'A: the obtain tick built exactly the two missing cells past the old top of the grid');
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'pgpm_t219.tg'::regclass and action = 'skip_obtain'),
  null::text[], 'A: and logged no skip_obtain');
select pgpm_t219.run(format($$ insert into pgpm_t219.tg values (3, %L, 'inside the raised lookahead') $$,
                             (select top from a_base) + interval '12 hours'));
select is((select pgpm_t219.home('pgpm_t219.tg', tableoid) from pgpm_t219.tg where id = 3),
  (select pgpm._ts_text(top) || '..' || pgpm._ts_text(top + interval '1 day') from a_base),
  'A: the write inside the raised lookahead lands in the cell the tick built for it');

-- ==================== PART B: an id grid's frontier, obtain and extend_to ===================================
create table pgpm_t219.ig (id bigint primary key, body text);
insert into pgpm_t219.ig values (5, 'five'), (17, 'seventeen');
call pgpm.transmute('pgpm_t219.ig', 'id', 100::bigint, p_obtain => 2);
select pgpm.obtain('pgpm_t219.ig');
select is(pgpm_t219.cells_from('pgpm_t219.ig', 0), array[0, 100, 200]::numeric[],
  'B LIVENESS: before the rename the grid is the monolith and two forward cells');

alter table pgpm_t219.ig rename column id to ident;
insert into pgpm_t219.ig values (250, 'two fifty');   -- the frontier moves into the last cell
select is(pg_get_partkeydef('pgpm_t219.ig'::regclass), 'RANGE (ident)',
  'B LIVENESS: the partition key column is now ident');

select is(pgpm_t219.run($$ select pgpm.obtain('pgpm_t219.ig') $$), '2', 'B: obtain reads the frontier from the renamed column and builds two cells');
select is(pgpm_t219.cells_from('pgpm_t219.ig', 0), array[0, 100, 200, 300, 400]::numeric[],
  'B: exactly the two cells past the frontier''s, 300 and 400');
select is(pgpm_t219.run($$ select pgpm.extend_to('pgpm_t219.ig', '720') $$), '3', 'B: extend_to builds the three cells up to 720');
select is(pgpm_t219.cells_from('pgpm_t219.ig', 0), array[0, 100, 200, 300, 400, 500, 600, 700]::numeric[],
  'B: exactly 500, 600 and 700');
select pgpm_t219.run($$ insert into pgpm_t219.ig values (333, 'three thirty-three'), (720, 'seven twenty') $$);
select is((select array_agg(ident || '@' || pgpm_t219.home('pgpm_t219.ig', tableoid) order by ident)
             from pgpm_t219.ig where ident > 300),
  array['333@300..400', '720@700..800'],
  'B: the writes land in the cells obtain and extend_to built for them');

-- ==================== PART C: regrain through the renamed column ===========================================
select throws_like($$ select pgpm.set_regrain('pgpm_t219.ig', '50.5') $$,
  '%regrain target step 50.5 for pgpm_t219.ig is not a whole number, but its control column ident is int8%',
  'C: set_regrain still sees the renamed column is a bigint, and refuses a fractional step naming it ident');
select is((select regrain_to from pgpm.config where parent_table = 'pgpm_t219.ig'::regclass), null,
  'C: and stored no target');
create temporary table c_mon as
  select child_name from pgpm.part where parent_table = 'pgpm_t219.ig'::regclass and attached and lo = '0';
select matches(pgpm_t219.run(format($$ select pgpm.regrain('pgpm_t219.ig', %L, '50') $$, (select child_name from c_mon))), '^[1-9][0-9]*$',
  'C LIVENESS: the monolith''s regrain ran');
select is(pgpm_t219.cells_from('pgpm_t219.ig', 0), array[0, 50, 100, 200, 300, 400, 500, 600, 700]::numeric[],
  'C: the monolith [0, 100) became the two fine cells [0, 50) and [50, 100)');
select is((select array_agg(ident || '@' || pgpm_t219.home('pgpm_t219.ig', tableoid) order by ident)
             from pgpm_t219.ig where ident < 100),
  array['5@0..50', '17@0..50'],
  'C: both of the monolith''s rows are in the fine cell their key places, none lost');
select is((select array_agg(ident order by ident) from pgpm_t219.ig),
  array[5, 17, 250, 333, 720]::bigint[], 'C: and the table holds exactly its five rows');

-- ==================== PART D: a naive grid's zone ==========================================================
create table pgpm_t219.nv (id bigint, at timestamp, body text, primary key (id, at));
insert into pgpm_t219.nv values (7, now()::timestamp, 'seven');
call pgpm.transmute('pgpm_t219.nv', 'at', '1 day'::interval, p_obtain => 2);
select throws_like($$ select pgpm.set_partition_tz('pgpm_t219.nv', 'America/New_York') $$,
  '%refused -- column at of pgpm_t219.nv is a timestamp or date column%',
  'D LIVENESS: before the rename, set_partition_tz refuses to move a naive grid''s zone');
alter table pgpm_t219.nv rename column at to logged_at;
select throws_like($$ select pgpm.set_partition_tz('pgpm_t219.nv', 'America/New_York') $$,
  '%refused -- column logged_at of pgpm_t219.nv is a timestamp or date column%',
  'D: after the rename it still refuses, naming the column logged_at');
select is((select partition_tz from pgpm.config where parent_table = 'pgpm_t219.nv'::regclass), 'UTC',
  'D: and the zone is still UTC');

-- ==================== PART E: untransmute ==================================================================
create table pgpm_t219.ut (id bigint, at timestamptz, body text, primary key (id, at));
insert into pgpm_t219.ut values (11, now() - interval '3 days', 'eleven'), (12, now() - interval '1 hour', 'twelve'),
                                 (13, now() - interval '9 days', 'thirteen');
call pgpm.transmute('pgpm_t219.ut', 'at', '1 day'::interval, p_obtain => 2);
alter table pgpm_t219.ut rename column at to occurred_at;
select is(pg_get_partkeydef('pgpm_t219.ut'::regclass), 'RANGE (occurred_at)',
  'E LIVENESS: the partition key column is now occurred_at');
select lives_ok($$ select pgpm.untransmute('pgpm_t219.ut') $$, 'E: untransmute runs on the renamed table');
select is((select relkind::text from pg_class where oid = 'pgpm_t219.ut'::regclass), 'r',
  'E: the table is a plain table again');
select is((select array_agg(id order by id) from pgpm_t219.ut where occurred_at is not null),
  array[11, 12, 13]::bigint[], 'E: holding exactly its three rows, under the column''s new name');
select is((select count(*)::int from pgpm.config where parent_table = 'pgpm_t219.ut'::regclass), 0,
  'E: and pgpm no longer manages it');

-- ==================== PART F: every config load follows ===================================================
-- each `select * into <var> from pgpm.config ...;` in an installed pgpm function, and whether the statement
-- right after it is `<var> := pgpm._control_followed(<var>);`
create temporary table f_loads as
  select p.oid::regprocedure::text as fn, m[1] as var, m[2] as next_stmt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
         lateral regexp_matches(p.prosrc, 'select \* into (\w+) from pgpm\.config [^;]*;\s*([^;]*;)', 'g') m
   where n.nspname = 'pgpm';
select cmp_ok((select count(*)::int from f_loads), '>=', 30,
  'F LIVENESS: the probe finds pgpm''s whole-row config loads (obtain, extend_to, retain, regrain, untransmute, ...)');
select is((select array_agg(fn order by fn) from f_loads
            where next_stmt <> format('%1$s := pgpm._control_followed(%1$s);', var)),
  null::text[], 'F: every one of them is followed by pgpm._control_followed');

select * from finish();
