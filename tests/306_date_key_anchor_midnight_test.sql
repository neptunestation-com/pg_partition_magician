-- Issue #769 (last bullet): transmute refuses an anchor off midnight UTC on a date key, before anything is
-- committed.
--
-- A date holds whole days and has no zone, so its grid is computed in UTC (#504) and every bound literal is
-- read by the column as a date. #581 held a date key's STEP to whole days and never its ANCHOR, and
-- _time_unit_breach, the time-precision rule transmute's preflight asks through _time_unit_contract, returned
-- null for a date. So an off-midnight anchor reached the grid, and every bound it produced was attached at its
-- date while pgpm.part recorded the instant:
--   * '2000-01-01 12:00+00' converted with every recorded bound at 12:00 and every catalog bound at the whole
--     date: a row dated a partition's first day lay before its recorded lo, and extend_to judged cells by the
--     recorded bounds, so it reported cells built while the write of the date it was asked for was refused.
--   * '2024-01-01' typed in an America/New_York session is 05:00 UTC. Phase 1 committed a NOT VALID bound
--     CHECK whose hi read as the newest row's own date, phase 2's VALIDATE died raw (23514) on that row, and
--     the CHECK and the claim stayed, rejecting every write dated on or after it until transmute_abort.
-- _time_unit_breach now knows a date: its unit is one day, and the anchor (and a duration step) must be a
-- whole number of days from the epoch, which on the UTC lattice a date grid uses is "at 00:00 UTC".
--
-- THE CASE TABLE, every refusal pinned to its message (transmute commits, so an unpinned throws_* would also
-- accept the 2D000 a non-refusing build dies with):
--   A  UTC session, noon anchor: refused on a daily step and on a monthly one; the table is the same plain
--      table and takes a write dated tomorrow; the default anchor then converts it, every cell's recorded bound
--      the catalog's, its rows in place.
--   B  New York session, '2024-01-01' (05:00 UTC): refused, naming the session's zone; the table still takes a
--      write dated tomorrow; '2024-01-01 00:00:00+00' from the same session converts it with the row dated
--      tomorrow (the one the defect's VALIDATE died on) in a cell whose recorded range holds its date.
--   C  a midnight-UTC anchor other than the default ('2000-01-03', a Monday, on a 7 day step) converts, and
--      every cell starts on a Monday at 00:00 UTC: the rule is midnight, not the default anchor.
--   D  resume: a claim an older install recorded on a noon grid (its owner gone) is not resumed on that anchor;
--      the claim and its CHECK are left as they were, transmute_abort clears them and the default anchor
--      converts.
--
-- INSTRUMENT, as tests/287: transmute runs through dblink as a top-level CALL, so a build that does not refuse
-- really commits its CHECK, and each refusal is followed by the table's state by identity (same oid, still
-- plain, no config, no bound CHECK, no claim, no pgpm.part row) and a write the defect's CHECK would reject.
-- Fixtures are asymmetric (3, 2, 4, 5 rows; distinct payloads checked by id). bench/date_key_anchor_midnight.sh
-- runs this file against the mutant.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(34);

select dblink_connect('t306', 'dbname=' || current_database());
select dblink_exec('t306', 'set timezone = ''UTC''');

create table t306_oid (rel text primary key, oid oid);

-- the table's state after a refused call, by identity
create function pg_temp.t306_state(p_rel regclass) returns text language sql as $$
  select concat_ws(' | ',
    (select relkind::text from pg_class where oid = p_rel),
    case when p_rel::oid = (select oid from t306_oid where rel = p_rel::text) then 'same oid' else 'new oid' end,
    'config:' || exists (select 1 from pgpm.config where parent_table = p_rel),
    'bound:' || exists (select 1 from pg_constraint where conrelid = p_rel and conname = 'pgpm_monolith_bound'),
    'claim:' || exists (select 1 from pgpm.transmute_inflight where parent_table = p_rel),
    'part:' || exists (select 1 from pgpm.part where parent_table = p_rel))
$$;

-- every attached cell whose recorded bound is not the catalog's, the parent filtered first (#973)
create function pg_temp.t306_mismatch(p_rel regclass) returns text language sql as $$
  with mine as materialized (
    select p.child_oid, p.lo, p.hi from pgpm.part p where p.parent_table = p_rel and p.attached
  ), cat as (
    select m.lo, m.hi, regexp_match(pg_get_expr(c.relpartbound, c.oid), $re$FROM \('([^']*)'\) TO \('([^']*)'\)$re$) b
      from mine m join pg_class c on c.oid = m.child_oid
  )
  select coalesce(string_agg(format('[%s, %s) attached as [%s, %s)', lo, hi, b[1], b[2]), '; '), 'none')
    from cat where b is null or b[1]::timestamptz <> lo::timestamptz or b[2]::timestamptz <> hi::timestamptz
$$;

-- converted, with cells to compare: relkind and at least three attached cells
create function pg_temp.t306_converted(p_rel regclass) returns boolean language sql as $$
  select (select relkind from pg_class where oid = p_rel) = 'p'
     and (select count(*) from pgpm.part where parent_table = p_rel and attached) >= 3
$$;

-- which rows sit in a cell whose recorded [lo, hi) does not hold their date, read as pgpm reads a date (wall
-- time in UTC); the parent's cells filtered first (#973)
create function pg_temp.t306_outside(p_rel regclass) returns text language plpgsql as $$
declare v text;
begin
  execute format($f$
    with mine as materialized (select p.child_oid, p.lo, p.hi from pgpm.part p where p.parent_table = %L::regclass)
    select string_agg(format('%%s=%%s in [%%s, %%s)', t.id, t.dt, m.lo, m.hi), '; ' order by t.id)
      from %s t join mine m on m.child_oid = t.tableoid
     where not (t.dt::timestamp at time zone 'UTC' >= m.lo::timestamptz and t.dt::timestamp at time zone 'UTC' < m.hi::timestamptz)
  $f$, p_rel::text, p_rel) into v;
  return coalesce(v, 'none');
end $$;

-- ======================================================================================================
-- A. a UTC session, an anchor at noon
-- ======================================================================================================
create table public.t306_noon (id bigint, dt date not null, v text, primary key (id, dt));
insert into public.t306_noon select g, current_date - g, 'noon-' || g from generate_series(1, 3) g;
insert into t306_oid values ('t306_noon', 'public.t306_noon'::regclass);
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.t306_noon'::regclass and attname = 'dt'),
  'date', 'A LIVENESS: the key is a date, which holds whole days');
select isnt(timestamptz '2000-01-01 12:00:00+00', date_trunc('day', timestamptz '2000-01-01 12:00:00+00'),
  'A LIVENESS: the anchor 2000-01-01 12:00+00 is not a midnight UTC');
select throws_like(
  $$ select dblink_exec('t306', $c$ call pgpm.transmute('public.t306_noon', 'dt', interval '1 day', p_obtain => 3,
       p_anchor => '2000-01-01 12:00:00+00') $c$) $$,
  'pg_partition_magician: cannot partition t306_noon on dt with step 1 day and anchor 2000-01-01 12:00:00+00 -- the column is a date,%this anchor falls at 12:00:00 UTC%pgpm.transmute_abort(t306_noon)%',
  'A: transmute refuses a noon anchor on a date key with a daily step');
select throws_like(
  $$ select dblink_exec('t306', $c$ call pgpm.transmute('public.t306_noon', 'dt', interval '1 month', p_obtain => 3,
       p_anchor => '2000-01-01 12:00:00+00') $c$) $$,
  'pg_partition_magician: cannot partition t306_noon on dt with step 1 mon and anchor 2000-01-01 12:00:00+00 -- the column is a date,%this anchor falls at 12:00:00 UTC%',
  'A: and with a monthly step (whole days by construction, but every bound still the anchor''s noon)');
select is(pg_temp.t306_state('public.t306_noon'), 'r | same oid | config:false | bound:false | claim:false | part:false',
  'A: both refused before anything committed: the same plain table, no config, bound CHECK, claim or ledger row');
select lives_ok($$ insert into public.t306_noon values (100, current_date + 1, 'noon-tomorrow') $$,
  'A: the table still accepts a write dated tomorrow');
select lives_ok(
  $$ select dblink_exec('t306', $c$ call pgpm.transmute('public.t306_noon', 'dt', interval '1 day', p_obtain => 3) $c$) $$,
  'A: the default anchor (2000-01-01 00:00+00) converts the same table');
select ok(pg_temp.t306_converted('public.t306_noon'), 'A LIVENESS: t306_noon is partitioned, with cells to compare');
select is(pg_temp.t306_mismatch('public.t306_noon'), 'none', 'A: every t306_noon cell records the bounds it is attached on');
select is(pg_temp.t306_outside('public.t306_noon'), 'none', 'A: no t306_noon row sits in a cell whose recorded range does not hold its date');
select is((select string_agg(v, ',' order by id) from public.t306_noon), 'noon-1,noon-2,noon-3,noon-tomorrow',
  'A: with its rows, the write dated tomorrow included, in place');

-- ======================================================================================================
-- B. a New York session, where '2024-01-01' is midnight on the operator's clock and 05:00 UTC
-- ======================================================================================================
create table public.t306_ny (id bigint not null, dt date not null, v text, primary key (id, dt));
insert into public.t306_ny values (1, current_date - 3, 'ny-old'), (2, current_date + 1, 'ny-tomorrow');
insert into t306_oid values ('t306_ny', 'public.t306_ny'::regclass);
select is((timestamp '2024-01-01 00:00' at time zone 'America/New_York') at time zone 'UTC', timestamp '2024-01-01 05:00',
  'B LIVENESS: midnight 2024-01-01 in New York is 05:00 UTC, off the date grid''s midnight');
select dblink_exec('t306', 'set timezone = ''America/New_York''');
select is((select s from dblink('t306', 'select current_setting(''TimeZone'')') as t(s text)), 'America/New_York',
  'B LIVENESS: the transmuting session is in New York');
select throws_like(
  $$ select dblink_exec('t306', $c$ call pgpm.transmute('public.t306_ny', 'dt', interval '1 day', p_anchor => '2024-01-01') $c$) $$,
  'pg_partition_magician: cannot partition t306_ny on dt with step 1 day and anchor 2024-01-01 00:00:00-05 -- the column is a date,%this anchor falls at 05:00:00 UTC%read in the session''s time zone, America/New_York%',
  'B: transmute refuses midnight typed in a New York session (05:00 UTC), naming the session''s zone');
select is(pg_temp.t306_state('public.t306_ny'), 'r | same oid | config:false | bound:false | claim:false | part:false',
  'B: refused before anything committed: no bound CHECK and no claim left behind');
select lives_ok($$ insert into public.t306_ny values (3, current_date + 1, 'ny-next') $$,
  'B: the table still accepts a write dated tomorrow');
select lives_ok(
  $$ select dblink_exec('t306', $c$ call pgpm.transmute('public.t306_ny', 'dt', interval '1 day', p_anchor => '2024-01-01 00:00:00+00') $c$) $$,
  'B: the same date written at 00:00 UTC converts the table from the same New York session');
select dblink_exec('t306', 'set timezone = ''UTC''');
select ok(pg_temp.t306_converted('public.t306_ny'), 'B LIVENESS: t306_ny is partitioned, with cells to compare');
select is((select partition_tz from pgpm.config where parent_table = 'public.t306_ny'::regclass), 'UTC',
  'B LIVENESS: the date grid is recorded in UTC whatever the session''s zone (#504)');
select is(pg_temp.t306_mismatch('public.t306_ny'), 'none', 'B: every t306_ny cell records the bounds it is attached on');
select is(pg_temp.t306_outside('public.t306_ny'), 'none', 'B: no t306_ny row sits in a cell whose recorded range does not hold its date');
select is((select string_agg(v, ',' order by id) from public.t306_ny), 'ny-old,ny-tomorrow,ny-next',
  'B: with its rows, both dated tomorrow included, in place');

-- ======================================================================================================
-- C. a midnight-UTC anchor other than the default converts: the rule is midnight, not one anchor
-- ======================================================================================================
create table public.t306_wk (id bigint, dt date not null, v text, primary key (id, dt));
insert into public.t306_wk select g, current_date - 5 * g, 'wk-' || g from generate_series(1, 4) g;
select is(extract(isodow from date '2000-01-03')::int, 1, 'C LIVENESS: 2000-01-03 is a Monday');
select lives_ok(
  $$ select dblink_exec('t306', $c$ call pgpm.transmute('public.t306_wk', 'dt', interval '7 days', p_obtain => 3,
       p_anchor => '2000-01-03 00:00:00+00') $c$) $$,
  'C: a midnight-UTC anchor on a Monday converts a date key with a 7 day step');
select ok(pg_temp.t306_converted('public.t306_wk'), 'C LIVENESS: t306_wk is partitioned, with cells to compare');
select is((select string_agg(distinct to_char(lo::timestamptz at time zone 'UTC', 'Dy HH24:MI:SS'), ',')
             from pgpm.part where parent_table = 'public.t306_wk'::regclass and attached
              and hi::timestamptz - lo::timestamptz = interval '7 days'),
  'Mon 00:00:00', 'C: every weekly cell starts on a Monday at 00:00 UTC');
select is(pg_temp.t306_mismatch('public.t306_wk'), 'none', 'C: every t306_wk cell records the bounds it is attached on');

-- ======================================================================================================
-- D. resume: a claim an older install recorded on a noon grid is refused before anything commits
-- ======================================================================================================
create table public.t306_r (id bigint, dt date not null, v text, primary key (id, dt));
insert into public.t306_r select g, current_date - g, 'r-' || g from generate_series(1, 5) g;
insert into t306_oid values ('t306_r', 'public.t306_r'::regclass);
-- the claim and its NOT VALID CHECK as phase 1 left them, owned by a session that has gone
create function pg_temp.t306_claim(p_rel regclass, p_lo text, p_hi text) returns void language plpgsql as $$
declare v_pid int; v_start timestamptz;
begin
  perform dblink_connect('t306_owner', 'dbname=' || current_database());
  select pid, backend_start into v_pid, v_start
    from dblink('t306_owner', 'select pg_backend_pid(), (select backend_start from pg_stat_activity where pid = pg_backend_pid())')
      as t(pid int, backend_start timestamptz);
  perform dblink_disconnect('t306_owner');
  insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz,
                                       control_attnum, owner_pid, owner_backend_start)
  select p_rel, n.nspname, c.relname, 'time', p_lo, p_hi, 'UTC',
         (select attnum from pg_attribute where attrelid = p_rel and attname = 'dt'), v_pid, v_start
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_rel;
  execute format('alter table %s add constraint pgpm_monolith_bound check (dt >= %L and dt < %L) not valid', p_rel, p_lo, p_hi);
end $$;
-- the owner's backend exits asynchronously; poll with a fresh pg_stat_activity snapshot each time (tests/269)
create function pg_temp.t306_owner_gone(p_rel regclass) returns boolean language plpgsql as $$
declare i int := 0;
begin
  while i < 600 and exists (select 1 from pgpm.transmute_inflight t join pg_stat_activity a
                             on a.pid = t.owner_pid and a.backend_start = t.owner_backend_start
                             where t.parent_table = p_rel) loop
    perform pg_sleep(0.05); i := i + 1;
    perform pg_stat_clear_snapshot();
  end loop;
  perform pg_stat_clear_snapshot();
  return not exists (select 1 from pgpm.transmute_inflight t join pg_stat_activity a
                      on a.pid = t.owner_pid and a.backend_start = t.owner_backend_start
                      where t.parent_table = p_rel);
end $$;
select set_config('t306.lo', pgpm._ts_text((current_date - 6)::timestamp at time zone 'UTC' + interval '12 hours'), false),
       set_config('t306.hi', pgpm._ts_text((current_date + 3)::timestamp at time zone 'UTC' + interval '12 hours'), false);
select pg_temp.t306_claim('public.t306_r', current_setting('t306.lo'), current_setting('t306.hi'));
select ok(pg_temp.t306_owner_gone('public.t306_r'), 'D LIVENESS: the session that recorded the claim is gone');
select is(pg_temp.t306_state('public.t306_r'), 'r | same oid | config:false | bound:true | claim:true | part:false',
  'D LIVENESS: the older install''s state: a claim on noon bounds and its CHECK');
select throws_like(
  $$ select dblink_exec('t306', $c$ call pgpm.transmute('public.t306_r', 'dt', interval '1 day', p_obtain => 3,
       p_anchor => '2000-01-01 12:00:00+00') $c$) $$,
  'pg_partition_magician: cannot partition t306_r on dt with step 1 day and anchor 2000-01-01 12:00:00+00 -- the column is a date,%pgpm.transmute_abort(t306_r)%',
  'D: a re-run on the recorded noon anchor is refused, naming transmute_abort');
select is((select concat_ws(' | ', lo, hi, (select convalidated::text from pg_constraint
                                               where conrelid = 'public.t306_r'::regclass and conname = 'pgpm_monolith_bound'))
             from pgpm.transmute_inflight where parent_table = 'public.t306_r'::regclass),
          concat_ws(' | ', current_setting('t306.lo'), current_setting('t306.hi'), 'false'),
  'D: refused before anything committed: the recorded claim and its CHECK as they were, not validated');
select ok(pgpm.transmute_abort('public.t306_r'), 'D: transmute_abort clears the claim and its CHECK');
select lives_ok(
  $$ select dblink_exec('t306', $c$ call pgpm.transmute('public.t306_r', 'dt', interval '1 day', p_obtain => 3) $c$) $$,
  'D: and the default anchor then converts the table on a fresh bound');
select is(pg_temp.t306_mismatch('public.t306_r'), 'none', 'D: every t306_r cell records the bounds it is attached on');

select dblink_disconnect('t306');
select * from finish();
