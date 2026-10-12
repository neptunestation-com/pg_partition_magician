-- Issue #1276: a whole-month time grid an older install anchored off its control column's unit (a date key at
-- 12:00 UTC, a timestamptz(0) key 0.4 s off the second, a uuidv7 key half a millisecond off) has every bound
-- where pgpm.part records it, because a calendar step's bounds are midnight on the 1st of a month whatever the
-- anchor's time (_grid_floor's calendar branch keeps only the anchor's month). Only a FIXED step counts its
-- bounds from the anchor instant. The unit rule asked the anchor whatever the step, so:
--   * the upgrade's warn_grid_off_unit said of such a grid that "every partition obtain mints is attached at
--     other bounds than pgpm.part records for it, and every regrain of the table is refused", which is false,
--     and sent the operator to a reconversion for bounds that are right;
--   * set_regrain refused a whole-month target on it (a 1-month target on a 3-month grid) for the same false
--     reason, and the encoded-unit refusal did the same to a uuidv7 key.
-- Now the anchor is held to the unit only where a step counts from it: the registered step when it is fixed,
-- and the regrain target when it is fixed. A whole-month target on such a grid is accepted and its regrain
-- completes with every fine bound the catalog's; a fixed target (days, hours) on it is still refused, naming the
-- anchor; the upgrade still logs the grid (a fixed regrain of it is refused, which only a reconversion lifts),
-- but says what is true of it. A FIXED grid anchored off the unit is refused and flagged as before, its
-- message unchanged, and its minted partitions do disagree with the catalog (the witness that the claim the
-- month grid no longer gets is still made where it is true).
--
-- The older installs' registrations are planted in pgpm.config by hand (the state each left), as tests/324:
--   m342  date key, 3-month step, anchor planted at 12:00 UTC          -> 1 month accepted and completes; 1 day refused
--   t342  timestamptz(0) key, 2-month step, anchor planted 0.4 s off   -> 1 month accepted and completes; 1 hour refused
--   v342  uuidv7 key, 2-month step, anchor planted 0.5 ms off          -> 1 month accepted and completes; 1 day refused
--   f342  date key, 7-day step, anchor planted at 12:00 UTC            -> refused whatever the target, flagged as before
--   xk342 text_time (unit s) key, 2-month step, epoch on the second, anchor 0.5 s off -> 1 month accepted
--   xe342 text_time (unit s) key, 2-month step, epoch 0.5 s off the second, anchor on it -> 1 month refused: its
--         midnight bounds are themselves off the epoch's seconds, so the whole-month exemption does not apply
-- (xk342 and xe342 are registered by hand, as tests/308's encoded grids are.)
-- The monoliths are frozen on an instrumented clock (a shim now() ahead of pg_catalog in search_path, tests/311's
-- technique). install.sql is read with \ir, relative to this file; the psql variable `install` overrides the
-- path. bench/month_grid_anchor_time.sh runs this file against the mutants.
\if :{?install}
\else
\set install ../pgpm_core/install.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
create schema clk342;
create table clk342.clock (t timestamptz);
insert into clk342.clock values ('2024-10-15 00:00:00+00');
create function clk342.now() returns timestamptz language sql stable as $$ select t from clk342.clock $$;
set search_path = clk342, pg_catalog, public;
select plan(37);

-- ============ four time grids, each converted on the default anchor, then planted off the unit ============
create table public.m342 (id bigint, dt date not null, v text, primary key (id, dt));
insert into public.m342 values (1, '2024-07-01', 'm-0701'), (2, '2024-07-31', 'm-0731'), (3, '2024-08-01', 'm-0801a'),
                               (4, '2024-08-01', 'm-0801b'), (5, '2024-09-30', 'm-0930');
create table public.t342 (id bigint, ts timestamptz(0) not null, primary key (id, ts));
insert into public.t342 values (11, '2024-07-01 00:00:00+00'), (12, '2024-07-31 23:59:59+00'), (13, '2024-08-01 00:00:00+00'),
                               (14, '2024-10-31 23:59:59+00');
create table public.v342 (id bigint, k uuid not null, primary key (id, k));
insert into public.v342 values (21, pgpm._ts_to_uuid('2024-07-01 00:00:00+00')), (22, pgpm._ts_to_uuid('2024-08-01 00:00:00+00')),
                               (23, pgpm._ts_to_uuid('2024-08-31 23:59:59.999+00')), (24, pgpm._ts_to_uuid('2024-10-05 00:00:00+00')),
                               (25, pgpm._ts_to_uuid('2024-10-06 00:00:00+00'));
create table public.f342 (id bigint, dt date not null, primary key (id, dt));
insert into public.f342 select g, date '2024-09-01' + (g % 30) from generate_series(1, 45) g;
call pgpm.transmute('public.m342', 'dt', interval '3 months', p_obtain => 1);
call pgpm.transmute('public.t342', 'ts', interval '2 months', p_obtain => 1);
call pgpm.transmute('public.v342', 'k', interval '2 months', p_obtain => 1);
call pgpm.transmute('public.f342', 'dt', interval '7 days', p_obtain => 1);
update clk342.clock set t = '2025-03-15 00:00:00+00';
-- the older installs' registrations (transmute refuses each of these anchors today)
update pgpm.config set partition_anchor = '2000-01-01 12:00:00+00'
 where parent_table in ('public.m342'::regclass, 'public.f342'::regclass);
update pgpm.config set partition_anchor = '2000-01-01 00:00:00.4+00' where parent_table = 'public.t342'::regclass;
update pgpm.config set partition_anchor = '2000-01-01 00:00:00.0005+00' where parent_table = 'public.v342'::regclass;
-- partitions minted on the planted anchors
select pgpm.extend_to('public.m342', '2025-09-01') as m_ext \gset
select pgpm.extend_to('public.f342', '2025-04-01') as f_ext \gset

create function pg_temp.attempt(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return 'completed';
exception when others then return sqlstate || ' ' || sqlerrm; end; $f$;
-- the copies a run left, the capture trigger on any child, and the cursor: what a refusal must not leave
create function pg_temp.run_marks(p_parent regclass) returns text language sql as $f$
  select (select count(*) from pgpm.part where parent_table = p_parent and not attached)::text || ' copies/'
      || (select count(*) from pg_trigger t join pg_inherits i on i.inhrelid = t.tgrelid
           where i.inhparent = p_parent and t.tgname = 'pgpm_regrain_capture')::text || ' captures/'
      || coalesce((select regrain_cursor from pgpm.config where parent_table = p_parent), 'no cursor')
$f$;
-- every attached cell of a date or timestamptz grid whose recorded bounds are not the catalog's, the parent's
-- cells filtered first (#973); a date literal is read as midnight UTC, the session's zone
create function pg_temp.mismatch(p_rel regclass) returns text language sql as $f$
  with mine as materialized (
    select p.child_oid, p.lo, p.hi from pgpm.part p where p.parent_table = p_rel and p.attached
  ), cat as (
    select m.lo, m.hi, regexp_match(pg_get_expr(c.relpartbound, c.oid), $re$FROM \('([^']*)'\) TO \('([^']*)'\)$re$) b
      from mine m join pg_class c on c.oid = m.child_oid
  )
  select coalesce(string_agg(format('[%s, %s) attached as [%s, %s)', lo, hi, b[1], b[2]), '; ' order by lo), 'none')
    from cat where b is null or b[1]::timestamptz <> lo::timestamptz or b[2]::timestamptz <> hi::timestamptz
$f$;
-- which rows each attached cell whose recorded lo falls in [p_from, p_to) holds, by id
create function pg_temp.cells(p_rel regclass, p_from timestamptz, p_to timestamptz) returns text language plpgsql as $f$
declare v text;
begin
  execute format($q$
    with mine as materialized (select p.child_name, p.child_oid, p.lo from pgpm.part p
                                where p.parent_table = %L::regclass and p.attached)
    select string_agg(m.child_name || '@' || coalesce((select string_agg(r.id::text, ',' order by r.id) from %s r
                                                        where r.tableoid = m.child_oid), '-'), ' ' order by m.lo::timestamptz)
      from mine m where m.lo::timestamptz >= %L and m.lo::timestamptz < %L$q$,
    p_rel, p_rel, p_from, p_to) into v;
  return v;
end; $f$;

select child_name as m_mono from pgpm.part where parent_table = 'public.m342'::regclass and lo = '2024-07-01 00:00:00+00' \gset
select child_name as t_mono from pgpm.part where parent_table = 'public.t342'::regclass and lo = '2024-07-01 00:00:00+00' \gset
select child_name as v_mono from pgpm.part where parent_table = 'public.v342'::regclass and lo = '2024-07-01 00:00:00+00' \gset

select is((select string_agg(c.parent_table::text || '=' || c.partition_anchor || '/' || c.partition_step, ', '
                             order by c.parent_table::text)
             from pgpm.config c where c.parent_table::text in ('f342', 'm342', 't342', 'v342')),
  'f342=2000-01-01 12:00:00+00/7 days, m342=2000-01-01 12:00:00+00/3 mons, '
  || 't342=2000-01-01 00:00:00.4+00/2 mons, v342=2000-01-01 00:00:00.0005+00/2 mons',
  'LIVENESS: the four grids are registered as planted: three whole-month grids off their unit, one 7-day grid at noon');
select is(:'m_mono' || ' ' || :'t_mono' || ' ' || :'v_mono',
  'm342_p2024_07_to_2025_01 t342_p2024_07_to_2024_11 v342_p2024_07_to_2024_11',
  'LIVENESS: m342, t342 and v342 each have a coarse monolith from 2024-07-01 for a regrain to split');
select ok((select coarse_frozen from pgpm.progress('public.m342')) > 0
          and (select coarse_frozen from pgpm.progress('public.t342')) > 0
          and (select coarse_frozen from pgpm.progress('public.v342')) > 0,
  'LIVENESS: and each monolith is frozen, so a regrain may pick it');

-- ============ the premise: a whole-month grid's bounds are the catalog's, a fixed grid's are not ============
select is((select string_agg(child_name, ',' order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.m342'::regclass and lo::timestamptz >= '2025-01-01'),
  'm342_p2025_01,m342_p2025_04,m342_p2025_07',
  'LIVENESS: extend_to minted three m342 partitions on the noon anchor');
select is(pg_temp.mismatch('public.m342'), 'none',
  'every m342 partition, the three minted on the noon anchor included, records the bounds the catalog attached it on');
select is((select string_agg(child_name, ',' order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.f342'::regclass and lo::timestamptz >= '2025-01-01'),
  'f342_p2025_03_08,f342_p2025_03_15,f342_p2025_03_22,f342_p2025_03_29',
  'LIVENESS: extend_to minted four f342 partitions on the noon anchor');
select is((select count(*)::int from regexp_split_to_table(pg_temp.mismatch('public.f342'), '; ')), 4,
  'and on the 7-day grid every one of those four is recorded at noon over a catalog bound at midnight');
select ok(pg_temp.mismatch('public.f342') like '[2025-03-08 12:00:00+00, 2025-03-15 12:00:00+00) attached as [2025-03-08, 2025-03-15)%',
  'f342_p2025_03_08 is recorded [03-08 12:00, 03-15 12:00) and attached [03-08, 03-15)');

-- ============ a whole-month target is accepted on each whole-month grid, and the regrain completes ============
select lives_ok($$ select pgpm.set_regrain('public.m342', '1 month') $$,
  'set_regrain accepts a 1-month target on m342, a 3-month date grid anchored at noon');
select is((select regrain_to from pgpm.config where parent_table = 'public.m342'::regclass), '1 month',
  'and stores m342''s target');
select lives_ok($$ select pgpm.set_regrain('public.m342', null) $$, 'm342''s target cleared again');
select is(pg_temp.attempt(format('select pgpm.regrain(%L, %L, %L)', 'public.m342', :'m_mono', '1 month')), 'completed',
  'regrain splits m342''s monolith into months');
select is(pg_temp.cells('public.m342', '2024-07-01', '2024-10-01'),
  'm342_p2024_07@1,2 m342_p2024_08@3,4 m342_p2024_09@5',
  'each row of m342 is in the month cell of its date: 07-01 and 07-31 in July, both 08-01 rows in August, 09-30 in September');
select is(pg_temp.mismatch('public.m342'), 'none', 'and every m342 cell, the fine ones included, records the bounds it is attached on');
select is((select string_agg(v, ',' order by id) from public.m342), 'm-0701,m-0731,m-0801a,m-0801b,m-0930',
  'with every m342 row in place');

select lives_ok($$ select pgpm.set_regrain('public.t342', '1 month') $$,
  'set_regrain accepts a 1-month target on t342, a 2-month timestamptz(0) grid anchored 0.4 s off the second');
select lives_ok($$ select pgpm.set_regrain('public.t342', null) $$, 't342''s target cleared again');
select is(pg_temp.attempt(format('select pgpm.regrain(%L, %L, %L)', 'public.t342', :'t_mono', '1 month')), 'completed',
  'regrain splits t342''s monolith into months');
select is(pg_temp.cells('public.t342', '2024-07-01', '2024-11-01'),
  't342_p2024_07@11,12 t342_p2024_08@13 t342_p2024_09@- t342_p2024_10@14',
  'each row of t342 is in its month cell, the last second of July and of October included');
select is(pg_temp.mismatch('public.t342'), 'none', 'and every t342 cell records the bounds it is attached on');

select lives_ok($$ select pgpm.set_regrain('public.v342', '1 month') $$,
  'set_regrain accepts a 1-month target on v342, a 2-month uuidv7 grid anchored half a millisecond off');
select lives_ok($$ select pgpm.set_regrain('public.v342', null) $$, 'v342''s target cleared again');
select is(pg_temp.attempt(format('select pgpm.regrain(%L, %L, %L)', 'public.v342', :'v_mono', '1 month')), 'completed',
  'regrain splits v342''s monolith into months');
select is(pg_temp.cells('public.v342', '2024-07-01', '2024-11-01'),
  'v342_p2024_07@21 v342_p2024_08@22,23 v342_p2024_09@- v342_p2024_10@24,25',
  'each row of v342 is in its month cell, the last millisecond of August included');

-- ============ a fixed target on the same grids is still refused, naming the anchor ============
select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.m342', '1 day'),
  'pg_partition_magician: cannot regrain m342 -- its grid is not on its control column dt''s unit: the column is date, which keeps whole days only, and the registered partition_anchor 2000-01-01 12:00:00+00 and partition_step 3 mons put a fixed step''s bounds off it%a regrain toward 1 day counts its fine cells from the anchor%A whole number of months is not refused.%whole multiples of 1 day (an anchor at 00:00 UTC)%',
  'set_regrain refuses a 1-day target on m342: a fixed step counts its fine cells from the noon anchor');
select throws_like(format('select pgpm.regrain_step(%L, %L, %L)', 'public.m342', 'm342_p2025_01', '1 day'),
  'pg_partition_magician: cannot regrain m342 -- its grid is not on its control column dt''s unit%',
  'regrain_step refuses it too, before it prepares');
select is(pg_temp.run_marks('public.m342'), '0 copies/0 captures/no cursor',
  'nothing was copied for m342''s refused day regrain');
select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.t342', '1 hour'),
  'pg_partition_magician: cannot regrain t342 -- its grid is not on its control column ts''s unit: the column is timestamp(0) with time zone, which keeps whole seconds only, and the registered partition_anchor 2000-01-01 00:00:00.4+00 and partition_step 2 mons put a fixed step''s bounds off it%a regrain toward 1 hour counts its fine cells from the anchor%',
  'set_regrain refuses a 1-hour target on t342');
select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.v342', '1 day'),
  'pg_partition_magician: cannot regrain v342 -- its grid is not on its control column k''s encoded unit: it is a uuidv7 key, which encodes whole milliseconds from 1970-01-01 00:00:00+00, and the registered partition_anchor 2000-01-01 00:00:00.0005+00 and partition_step 2 mons put a fixed step''s bounds off it%a regrain toward 1 day counts its fine cells from the anchor%',
  'set_regrain refuses a 1-day target on v342');

-- ============ an encoded grid: the exemption is for bounds on the unit, which needs the epoch on it too ============
create table public.xk342 (id text collate "C" not null) partition by range (id);
create table public.xe342 (id text collate "C" not null) partition by range (id);
insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor,
                         text_time_prefix, text_time_width, text_time_radix, text_time_unit, text_time_epoch)
  values ('public.xk342', 'id', 'text_time', '2 months', '2000-01-01 00:00:00.5+00', '', 8, 16, 's', '1970-01-01 00:00:00+00'),
         ('public.xe342', 'id', 'text_time', '2 months', '2000-01-01 00:00:00+00', '', 8, 16, 's', '1970-01-01 00:00:00.5+00');
select is((select string_agg(parent_table::text || '=' || partition_anchor || '/' || partition_step || '/' || text_time_epoch, ', '
                             order by parent_table::text)
             from pgpm.config where parent_table in ('public.xk342'::regclass, 'public.xe342'::regclass)),
  'xe342=2000-01-01 00:00:00+00/2 months/1970-01-01 00:00:00.5+00, xk342=2000-01-01 00:00:00.5+00/2 months/1970-01-01 00:00:00+00',
  'LIVENESS: xk342 is anchored half a second off its epoch''s seconds, xe342''s epoch is half a second off the second');
select lives_ok($$ select pgpm.set_regrain('public.xk342', '1 month') $$,
  'set_regrain accepts a 1-month target on xk342: every month bound is midnight, whole seconds from its epoch');
select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.xe342', '1 month'),
  'pg_partition_magician: cannot regrain xe342 -- its grid is not on its control column id''s encoded unit: it is a text_time key, which encodes whole seconds from 1970-01-01 00:00:00.5+00, and the registered partition_anchor 2000-01-01 00:00:00+00 and partition_step 2 months do not both fall on whole seconds, so every bound of the grid and of any regrain of it is encoded by flooring it to that unit%',
  'set_regrain refuses it on xe342, whose midnight bounds are half a second off its epoch''s seconds');

-- ============ a fixed grid off the unit is refused whatever the target, as before ============
select throws_like(format('select pgpm.set_regrain(%L, %L)', 'public.f342', '1 day'),
  'pg_partition_magician: cannot regrain f342 -- its grid is not on its control column dt''s unit: the column is date, which keeps whole days only, and the registered partition_anchor 2000-01-01 12:00:00+00 and partition_step 7 days do not both fall on whole multiples of 1 day, so every bound of the grid and of any regrain of it is attached at another instant than pgpm records for it%',
  'set_regrain refuses any regrain of f342, a 7-day grid anchored at noon, with the grid''s own bounds named');

-- ============ the upgrade says what is true of each ============
select is((select count(*)::int from pgpm.log where action = 'warn_grid_off_unit'), 0,
  'LIVENESS: no grid was flagged before the upgrade');
reset search_path;
\ir :install
set client_min_messages = warning;
set search_path = clk342, pg_catalog, public;
select is((select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.log
            where action = 'warn_grid_off_unit' and parent_table::text in ('f342', 'm342', 't342', 'v342')),
  'f342,m342,t342',
  'the upgrade logs warn_grid_off_unit for f342, m342 and t342 (a uuidv7 key is not a time key it reads)');
select ok(exists (select 1 from pgpm.log where action = 'warn_grid_off_unit' and parent_table = 'public.f342'::regclass
                    and method like '%2000-01-01 12:00:00+00 and partition_step 7 days do not both fall on whole multiples of 1 day, so every partition obtain mints is attached at other bounds than pgpm.part records for it, and every regrain of the table is refused%'),
  'f342''s row says every partition obtain mints is attached at other bounds than pgpm.part records, which is true of it');
select is((select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.log
            where action = 'warn_grid_off_unit' and parent_table::text in ('m342', 't342')
              and method not like '%every partition obtain mints is attached at other bounds than pgpm.part records%'
              and method like '%is a whole number of months, whose bounds fall at midnight on the 1st of a month whatever the anchor''s time, so the partitions obtain mints are attached at the bounds pgpm.part records for them and a regrain toward a whole number of months is not refused, but a regrain toward a fixed step (days, hours) counts its fine cells from the anchor and is refused%'),
  'm342,t342',
  'm342''s and t342''s rows say their bounds are the ones pgpm.part records and only a fixed regrain is refused');

select * from finish();
