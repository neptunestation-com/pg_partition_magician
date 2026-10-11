-- Issue #1039 bullet 1: transmute refuses a partition step (or an anchor) a timestamp(p) or timestamptz(p)
-- key cannot hold, before anything is committed.
--
-- #980 gave a regrain target a precision rule (pgpm._regrain_step_shape), and transmute's preflight never
-- asked it of a partition_step. '500 milliseconds' on a timestamptz(0) key passed the preflight, phases 1
-- and 2 committed and VALIDATED the pgpm_monolith_bound CHECK, and the cutover's obtain then died on 'empty
-- range bound' (the forward cells' bounds '..:41.5' and '..:42' both round to '..:42'), leaving the plain
-- table rejecting every current write until transmute_abort; a retry resumed the recorded bound and failed
-- the same way. '1500 milliseconds' converted, but four of the five pgpm.part rows recorded bounds
-- ('..:13.5') the catalog rounds to another instant ('..:14'). The rule is now one helper,
-- pgpm._time_unit_breach, which _regrain_step_shape and transmute's new _time_unit_contract both ask:
-- every bound is the anchor plus whole steps, so it is one the column holds exactly when the step (unless
-- it is a whole number of months) and the anchor are whole multiples of the column's unit, 10^-p seconds.
--
-- THE CASE TABLE, one key type per block, every refusal pinned to its message (transmute commits, so an
-- unpinned throws_* would also accept the 2D000 a non-refusing build dies with):
--   timestamp(0)    finer (500 ms) and not a multiple (1500 ms) refused; the unit (1 s) and a multiple
--                   (2 s) convert, a month converts.
--   timestamp(3)    finer (500 us) and not a multiple (1500 us) refused; the unit (1 ms) and a multiple
--                   (250 ms) convert.
--   timestamptz(6)  no interval is finer than its unit, a microsecond, nor a fraction of one, so nothing is
--                   refused: the unit (1 us) and the very 1500 us refused on timestamp(3) convert.
--   anchor          half a second off on timestamptz(0) is refused; the same anchor on timestamptz(3) is
--                   whole milliseconds and converts, its bounds carrying the half second.
--   resume          a claim an older install recorded on a 500 ms grid is not resumed on that step, nor on
--                   a whole-second one; transmute_abort clears it and a whole-second step converts.
--
-- INSTRUMENT, as tests/268 part B: transmute runs through dblink as a top-level CALL, so a build that does
-- not refuse really commits its CHECK, and each refusal is followed by the table's state by identity (same
-- oid, still plain, no config, no bound CHECK, no claim, no pgpm.part row) and a current write the defect's
-- CHECK would reject. Every converted table is checked cell by cell: each pgpm.part bound is the catalog's.
-- Fixtures are asymmetric (5, 4, 3, 6 rows; distinct payloads checked by id). bench/transmute_step_precision.sh
-- runs this file against the mutants.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(42);

select dblink_connect('t287', 'dbname=' || current_database());

create table t287_oid (rel text primary key, oid oid);

-- the table's state after a refused call, by identity
create function pg_temp.t287_state(p_rel regclass) returns text language sql as $$
  select concat_ws(' | ',
    (select relkind::text from pg_class where oid = p_rel),
    case when p_rel::oid = (select oid from t287_oid where rel = p_rel::text) then 'same oid' else 'new oid' end,
    'config:' || exists (select 1 from pgpm.config where parent_table = p_rel),
    'bound:' || exists (select 1 from pg_constraint where conrelid = p_rel and conname = 'pgpm_monolith_bound'),
    'claim:' || exists (select 1 from pgpm.transmute_inflight where parent_table = p_rel),
    'part:' || exists (select 1 from pgpm.part where parent_table = p_rel))
$$;

-- every attached cell whose recorded bound is not the catalog's, the parent filtered first (#973)
create function pg_temp.t287_mismatch(p_rel regclass) returns text language sql as $$
  with mine as materialized (
    select p.child_oid, p.lo, p.hi from pgpm.part p where p.parent_table = p_rel and p.attached
  ), cat as (
    select m.lo, m.hi, regexp_match(pg_get_expr(c.relpartbound, c.oid), $re$FROM \('([^']*)'\) TO \('([^']*)'\)$re$) b
      from mine m join pg_class c on c.oid = m.child_oid
  )
  select coalesce(string_agg(format('[%s, %s) attached as [%s, %s)', lo, hi, b[1], b[2]), '; '), 'none')
    from cat where b is null or b[1]::timestamptz <> lo::timestamptz or b[2]::timestamptz <> hi::timestamptz
$$;

-- converted, with the cells to compare: relkind and how many attached cells there are
create function pg_temp.t287_converted(p_rel regclass) returns boolean language sql as $$
  select (select relkind from pg_class where oid = p_rel) = 'p'
     and (select count(*) from pgpm.part where parent_table = p_rel and attached) >= 4
$$;

-- ======================================================================================================
-- A. timestamp(0): whole seconds
-- ======================================================================================================
create table public.t287_s0 (id bigint, ts timestamp(0) not null, v text, primary key (id, ts));
insert into public.t287_s0 select g, localtimestamp(0) - g * interval '1 second', 's0-' || g from generate_series(1, 5) g;
insert into t287_oid values ('t287_s0', 'public.t287_s0'::regclass);
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.t287_s0'::regclass and attname = 'ts'),
  'timestamp(0) without time zone', 'LIVENESS: (A) the key is timestamp(0), which keeps whole seconds');
select throws_like(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_s0', 'ts', interval '500 milliseconds', p_obtain => 3) $c$) $$,
  'pg_partition_magician: cannot partition t287_s0 on ts with step 00:00:00.5 and anchor % -- the column is timestamp(0) without time zone, which keeps whole seconds only,%whole multiples of 1 second%',
  'A: transmute refuses a 500 ms step on a timestamp(0) key (finer than its unit)');
select throws_like(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_s0', 'ts', interval '1500 milliseconds', p_obtain => 3) $c$) $$,
  'pg_partition_magician: cannot partition t287_s0 on ts with step 00:00:01.5 and anchor % -- the column is timestamp(0) without time zone, which keeps whole seconds only,%',
  'A: transmute refuses a 1500 ms step on a timestamp(0) key (coarser than its unit, but not a whole multiple)');
select is(pg_temp.t287_state('public.t287_s0'), 'r | same oid | config:false | bound:false | claim:false | part:false',
  'A: both refused before anything committed: the same plain table, no config, bound CHECK, claim or ledger row');
select lives_ok($$ insert into public.t287_s0 values (100, localtimestamp(0) + interval '1 minute', 's0-current') $$,
  'A: the table still accepts a current write');
-- 40 cells of 2 s reach past the current write a minute ahead, which the monolith takes
select lives_ok(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_s0', 'ts', interval '2 seconds', p_obtain => 40) $c$) $$,
  'A: a 2 second step (a whole multiple of the unit) converts the same table');
select ok(pg_temp.t287_converted('public.t287_s0'), 'LIVENESS: (A) t287_s0 is partitioned, with cells to compare');
select is(pg_temp.t287_mismatch('public.t287_s0'), 'none', 'A: every t287_s0 cell records the bounds it is attached on');
select is((select string_agg(v, ',' order by id) from public.t287_s0 where id in (1, 5, 100)), 's0-1,s0-5,s0-current',
  'A: with the rows, the current write included, in place');

create table public.t287_s0u (id bigint, ts timestamp(0) not null, primary key (id, ts));
insert into public.t287_s0u select g, localtimestamp(0) - g * interval '1 second' from generate_series(1, 4) g;
select lives_ok(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_s0u', 'ts', interval '1 second', p_obtain => 3) $c$) $$,
  'A: a 1 second step (exactly the unit) converts a timestamp(0) table');
select ok(pg_temp.t287_converted('public.t287_s0u'), 'LIVENESS: (A) t287_s0u is partitioned, with cells to compare');
select is(pg_temp.t287_mismatch('public.t287_s0u'), 'none', 'A: every t287_s0u cell records the bounds it is attached on');

create table public.t287_s0m (id bigint, ts timestamp(0) not null, primary key (id, ts));
insert into public.t287_s0m select g, localtimestamp(0) - g * interval '1 day' from generate_series(1, 3) g;
select lives_ok(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_s0m', 'ts', interval '1 month', p_obtain => 3) $c$) $$,
  'A: a calendar step (1 month, whole seconds by construction) converts a timestamp(0) table');

-- ======================================================================================================
-- B. timestamp(3): whole milliseconds
-- ======================================================================================================
create table public.t287_s3 (id bigint, ts timestamp(3) not null, v text, primary key (id, ts));
insert into public.t287_s3 select g, localtimestamp(3) - g * interval '1.25 seconds', 's3-' || g from generate_series(1, 4) g;
insert into t287_oid values ('t287_s3', 'public.t287_s3'::regclass);
select throws_like(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_s3', 'ts', interval '500 microseconds', p_obtain => 3) $c$) $$,
  'pg_partition_magician: cannot partition t287_s3 on ts with step 00:00:00.0005 and anchor % -- the column is timestamp(3) without time zone, which keeps 3 fractional-second digit(s),%whole multiples of 0.001 seconds%',
  'B: transmute refuses a 500 us step on a timestamp(3) key (finer than its unit)');
select throws_like(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_s3', 'ts', interval '1500 microseconds', p_obtain => 3) $c$) $$,
  'pg_partition_magician: cannot partition t287_s3 on ts with step 00:00:00.0015 and anchor % -- the column is timestamp(3) without time zone, which keeps 3 fractional-second digit(s),%',
  'B: transmute refuses a 1500 us step on a timestamp(3) key (not a whole multiple of its unit)');
select is(pg_temp.t287_state('public.t287_s3'), 'r | same oid | config:false | bound:false | claim:false | part:false',
  'B: both refused before anything committed');
select lives_ok(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_s3', 'ts', interval '250 milliseconds', p_obtain => 3) $c$) $$,
  'B: a 250 ms step (a whole multiple of the unit) converts the same table');
select ok(pg_temp.t287_converted('public.t287_s3'), 'LIVENESS: (B) t287_s3 is partitioned, with cells to compare');
select is(pg_temp.t287_mismatch('public.t287_s3'), 'none', 'B: every t287_s3 cell records the bounds it is attached on');
select is((select string_agg(v, ',' order by id) from public.t287_s3), 's3-1,s3-2,s3-3,s3-4', 'B: with its four rows in place');

create table public.t287_s3u (id bigint, ts timestamp(3) not null, primary key (id, ts));
insert into public.t287_s3u select g, localtimestamp(3) - g * interval '0.125 seconds' from generate_series(1, 3) g;
select lives_ok(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_s3u', 'ts', interval '1 millisecond', p_obtain => 3) $c$) $$,
  'B: a 1 ms step (exactly the unit) converts a timestamp(3) table');
select ok(pg_temp.t287_converted('public.t287_s3u'), 'LIVENESS: (B) t287_s3u is partitioned, with cells to compare');
select is(pg_temp.t287_mismatch('public.t287_s3u'), 'none', 'B: every t287_s3u cell records the bounds it is attached on');

-- ======================================================================================================
-- C. timestamptz(6): a microsecond, below which no interval goes, so no step is refused
-- ======================================================================================================
select is(interval '0.4 microseconds', interval '0', 'LIVENESS: (C) no interval is finer than a microsecond (0.4 us reads as 0)');
create table public.t287_z6 (id bigint, ts timestamptz(6) not null, primary key (id, ts));
insert into public.t287_z6 select g, now() - g * interval '1.000001 seconds' from generate_series(1, 6) g;
select lives_ok(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_z6', 'ts', interval '1500 microseconds', p_obtain => 3) $c$) $$,
  'C: the 1500 us step refused on timestamp(3) converts a timestamptz(6) table (a whole number of its unit)');
select ok(pg_temp.t287_converted('public.t287_z6'), 'LIVENESS: (C) t287_z6 is partitioned, with cells to compare');
select is(pg_temp.t287_mismatch('public.t287_z6'), 'none', 'C: every t287_z6 cell records the bounds it is attached on');
create table public.t287_z6u (id bigint, ts timestamptz(6) not null, primary key (id, ts));
insert into public.t287_z6u select g, now() - g * interval '3 microseconds' from generate_series(1, 3) g;
select lives_ok(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_z6u', 'ts', interval '1 microsecond', p_obtain => 3) $c$) $$,
  'C: a 1 us step (exactly the unit) converts a timestamptz(6) table');
select ok(pg_temp.t287_converted('public.t287_z6u'), 'LIVENESS: (C) t287_z6u is partitioned, with cells to compare');

-- ======================================================================================================
-- D. the anchor: every bound is the anchor plus whole steps, so it must be whole units too
-- ======================================================================================================
create table public.t287_a0 (id bigint, ts timestamptz(0) not null, primary key (id, ts));
insert into public.t287_a0 select g, now() - g * interval '1 hour' from generate_series(1, 5) g;
insert into t287_oid values ('t287_a0', 'public.t287_a0'::regclass);
select throws_like(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_a0', 'ts', interval '1 hour', p_obtain => 3,
       p_anchor => '2000-01-01 00:00:00.5+00') $c$) $$,
  'pg_partition_magician: cannot partition t287_a0 on ts with step 01:00:00 and anchor 2000-01-01 00:00:00.5+00 -- the column is timestamp(0) with time zone, which keeps whole seconds only,%',
  'D: transmute refuses an anchor half a second off a timestamptz(0) key''s seconds');
select is(pg_temp.t287_state('public.t287_a0'), 'r | same oid | config:false | bound:false | claim:false | part:false',
  'D: refused before anything committed');
create table public.t287_a3 (id bigint, ts timestamptz(3) not null, primary key (id, ts));
insert into public.t287_a3 select g, now() - g * interval '1 hour' from generate_series(1, 5) g;
select lives_ok(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_a3', 'ts', interval '1 hour', p_obtain => 3,
       p_anchor => '2000-01-01 00:00:00.5+00') $c$) $$,
  'D: the same anchor converts a timestamptz(3) table, where half a second is whole milliseconds');
select ok(pg_temp.t287_converted('public.t287_a3')
          and (select bool_and(extract(microseconds from lo::timestamptz)::bigint % 1000000 = 500000)
                 from pgpm.part where parent_table = 'public.t287_a3'::regclass and attached),
  'LIVENESS: (D) t287_a3 is partitioned and every recorded lower bound carries the anchor''s half second');
select is(pg_temp.t287_mismatch('public.t287_a3'), 'none', 'D: every t287_a3 cell records the bounds it is attached on');

-- ======================================================================================================
-- E. resume: a claim an older install recorded on a 500 ms grid is refused before anything commits
-- ======================================================================================================
create table public.t287_r0 (id bigint, ts timestamptz(0) not null, v text, primary key (id, ts));
insert into public.t287_r0 select g, date_trunc('second', now()) - g * interval '1 second', 'r0-' || g from generate_series(1, 5) g;
insert into t287_oid values ('t287_r0', 'public.t287_r0'::regclass);
-- the claim and its NOT VALID CHECK as phase 1 left them, owned by a session that has gone
create function pg_temp.t287_claim(p_rel regclass, p_lo text, p_hi text) returns void language plpgsql as $$
declare v_pid int; v_start timestamptz;
begin
  perform dblink_connect('t287_owner', 'dbname=' || current_database());
  select pid, backend_start into v_pid, v_start
    from dblink('t287_owner', 'select pg_backend_pid(), (select backend_start from pg_stat_activity where pid = pg_backend_pid())')
      as t(pid int, backend_start timestamptz);
  perform dblink_disconnect('t287_owner');
  insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz,
                                       control_attnum, owner_pid, owner_backend_start)
  select p_rel, n.nspname, c.relname, 'time', p_lo, p_hi, 'UTC',
         (select attnum from pg_attribute where attrelid = p_rel and attname = 'ts'), v_pid, v_start
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_rel;
  execute format('alter table %s add constraint pgpm_monolith_bound check (ts >= %L and ts < %L) not valid', p_rel, p_lo, p_hi);
end $$;
-- the owner's backend exits asynchronously; poll with a fresh pg_stat_activity snapshot each time (tests/269)
create function pg_temp.t287_owner_gone(p_rel regclass) returns boolean language plpgsql as $$
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
select set_config('t287.lo', pgpm._ts_text(date_trunc('second', now()) - interval '9.5 seconds'), false),
       set_config('t287.hi', pgpm._ts_text(date_trunc('second', now()) + interval '30.5 seconds'), false);
select pg_temp.t287_claim('public.t287_r0', current_setting('t287.lo'), current_setting('t287.hi'));
select ok(pg_temp.t287_owner_gone('public.t287_r0'), 'LIVENESS: (E) the session that recorded the claim is gone');
select is(pg_temp.t287_state('public.t287_r0'), 'r | same oid | config:false | bound:true | claim:true | part:false',
  'LIVENESS: (E) the older install''s state: a claim on half-second bounds and its CHECK');
select throws_like(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_r0', 'ts', interval '500 milliseconds', p_obtain => 3) $c$) $$,
  'pg_partition_magician: cannot partition t287_r0 on ts with step 00:00:00.5 and anchor %pgpm.transmute_abort(t287_r0)%',
  'E: a re-run on the recorded 500 ms step is refused, naming transmute_abort');
select throws_like(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_r0', 'ts', interval '1 second', p_obtain => 3) $c$) $$,
  'pg_partition_magician: cannot resume the transmute of t287_r0 with step 00:00:01 %does not lie on that grid%pgpm.transmute_abort(t287_r0)%',
  'E: a re-run on a whole-second step does not resume the half-second bound either');
select is((select concat_ws(' | ', lo, hi, (select convalidated::text from pg_constraint
                                               where conrelid = 'public.t287_r0'::regclass and conname = 'pgpm_monolith_bound'))
             from pgpm.transmute_inflight where parent_table = 'public.t287_r0'::regclass),
          concat_ws(' | ', current_setting('t287.lo'), current_setting('t287.hi'), 'false'),
  'E: refused before anything committed: the recorded claim and its CHECK as they were, not validated');
select ok(pgpm.transmute_abort('public.t287_r0'), 'E: transmute_abort clears the claim and its CHECK');
select lives_ok(
  $$ select dblink_exec('t287', $c$ call pgpm.transmute('public.t287_r0', 'ts', interval '1 second', p_obtain => 3) $c$) $$,
  'E: and a whole-second step then converts the table on a fresh bound');
select is(pg_temp.t287_mismatch('public.t287_r0'), 'none', 'E: every t287_r0 cell records the bounds it is attached on');

select dblink_disconnect('t287');
select * from finish();
