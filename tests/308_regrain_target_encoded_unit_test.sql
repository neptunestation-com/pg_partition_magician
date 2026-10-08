-- Issue #1039 bullet 2 (review pass 10, F3-01 and F3-04): a regrain target on an ENCODED time key (text_time,
-- uuidv7) must be a whole number of the encoding's unit, and is refused at call time and at every other
-- regrain entry point when it is not, finer or coarser than the unit.
--
-- _regrain_step_shape held a regrain target to a timestamp(p) column's precision (#980) and asked nothing of a
-- text_time key (whole seconds for ObjectId and KSUID, whole milliseconds for cuid and ULID) or a uuidv7 key
-- (whole milliseconds). '1.5 seconds' on an ObjectId key, or '1500 microseconds' on a uuidv7 key, was
-- accepted: the copy encodes each fine bound by flooring it to the unit, so the row at T+1 landed in the copy
-- [T+1.5, T+3), while the reconcile places a captured key by _grid_floor of its decoded instant, the copy
-- [T, T+1.5). A DELETE committed mid-regrain was consumed against the wrong copy, and the swap attached the
-- copy still holding the row: a committed DELETE undone. A target finer than the unit collapsed adjacent
-- bounds instead. transmute holds its own anchor and step to a text_time unit (#989); a regrain target now
-- answers to the same unit, through _time_unit_breach.
--
-- Every refusal is pinned to its message and paired with a witness that the same entry point accepts a whole
-- unit on the same table. The asymmetric pair is the point: the same '1.5 seconds' is refused on a key that
-- encodes seconds and accepted, and completed, on one that encodes milliseconds. The mid-regrain DELETE runs
-- at a whole-unit target on both affected kinds, so the fixed path is shown to keep a deleted row deleted,
-- naming which rows remain. The grid itself must be on the unit too: transmute refuses a uuidv7 anchor or
-- step off the millisecond (door 1), and a regrain of a grid an older install registered off the unit is
-- refused whatever its target (door 2). bench/regrain_target_encoded_unit.sh runs this file against the
-- mutants regrain_step_unit_uuidv7_unasked, regrain_step_unit_text_time_seconds_unread,
-- transmute_uuidv7_anchor_unasked, transmute_uuidv7_step_unasked (#1113),
-- regrain_step_registered_anchor_unasked and regrain_step_registered_step_unasked.
set timezone = 'UTC';
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(52);

-- ============ three encoded grids: ObjectId (text_time, unit s), hex ms (text_time, unit ms), uuidv7 ============
create function pg_temp.u7(p_ts timestamptz, n int) returns uuid language sql as $$
  select (substr(h,1,8)||'-'||substr(h,9,4)||'-'||substr(h,13,4)||'-'||substr(h,17,4)||'-'||substr(h,21,12))::uuid
    from (select lpad(to_hex(floor(extract(epoch from p_ts) * 1000)::bigint), 12, '0') || '7' || lpad(to_hex(n), 3, '0')
                 || '8' || lpad(to_hex(n), 15, '0') as h) x $$;
create function pg_temp.oid_key(p_ts timestamptz, n int) returns text language sql as $$
  select pgpm._ts_to_text_time(p_ts, '', 8, 16, 's', null) || lpad(to_hex(n), 16, '0') $$;
create function pg_temp.ms_key(p_ts timestamptz, n int) returns text language sql as $$
  select pgpm._ts_to_text_time(p_ts, '', 12, 16, 'ms', null) || lpad(to_hex(n), 8, '0') $$;

create table public.ob (id text collate "C" primary key, payload text);
insert into public.ob select pg_temp.oid_key('2024-01-01 00:00:00+00'::timestamptz + make_interval(secs => s), s), 'hist' || s
  from generate_series(0, 4) s;
call pgpm.transmute('public.ob', 'id', interval '6 seconds', p_obtain => 4, p_paused => false,
                    p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's');

create table public.cu (id text collate "C" primary key, payload text);
insert into public.cu select pg_temp.ms_key('2024-01-01 00:00:00+00'::timestamptz + make_interval(secs => s), s), 'hist' || s
  from generate_series(0, 4) s;
call pgpm.transmute('public.cu', 'id', interval '6 seconds', p_obtain => 4, p_paused => false,
                    p_tt_prefix => '', p_tt_width => 12, p_tt_radix => 16, p_tt_unit => 'ms');

create table public.uv (id uuid primary key, payload text);
insert into public.uv select pg_temp.u7(now() - interval '1 day' + make_interval(secs => s), s), 'hist' || s
  from generate_series(0, 4) s;
call pgpm.transmute('public.uv', 'id', interval '6 milliseconds', p_obtain => 4, p_paused => false);

-- T: the lo of each table's first forward partition, one 6-unit cell [T, T+6)
create temp table cell as
  select p.parent_table, (select lo::timestamptz from pgpm.part q where q.parent_table = p.parent_table and q.attached
                           order by lo::timestamptz offset 1 limit 1) as t
    from (values ('public.ob'::regclass), ('public.cu'::regclass), ('public.uv'::regclass)) p(parent_table);
-- rows at T+0, 1, 2, 4, 5 units in that cell (ObjectId and hex ms: seconds; uuidv7: milliseconds), and one at
-- T+13 units that freezes it
insert into public.ob select pg_temp.oid_key(t + make_interval(secs => s), 1000 + s), 'k' || s
  from cell, unnest(array[0, 1, 2, 4, 5, 13]) s where parent_table = 'public.ob'::regclass;
-- the hex ms key holds rows a half-second apart, so a 1.5-second cell takes three and no two cells tie
insert into public.cu select pg_temp.ms_key(t + make_interval(secs => s / 2.0), 1000 + s), 'k' || s
  from cell, unnest(array[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 30]) s where parent_table = 'public.cu'::regclass;
insert into public.uv select pg_temp.u7(t + make_interval(secs => s / 1000.0), 1000 + s), 'k' || s
  from cell, unnest(array[0, 1, 2, 4, 5, 13]) s where parent_table = 'public.uv'::regclass;
create temp table before_cu as select id, payload from public.cu;

create function pg_temp.cell_child(p_parent regclass) returns name language sql as $$
  select child_name from pgpm.part where parent_table = p_parent and attached
     and lo::timestamptz = (select t from cell where parent_table = p_parent) $$;
create function pg_temp.cell_rows(p_parent regclass) returns text language plpgsql as $$
declare v text;
begin
  execute format('select string_agg(payload, '','' order by payload) from %s r join pg_class c on c.oid = r.tableoid'
                 ' where c.relname = %L', p_parent, pg_temp.cell_child(p_parent)) into v;
  return v;
end $$;

select is(pg_temp.cell_rows('public.ob'), 'k0,k1,k2,k4,k5',
  'LIVENESS: ob''s 6-second cell [T, T+6) holds k0, k1, k2, k4, k5 (k1 at T+1s), and k13 sits past it');
select is(pg_temp.cell_rows('public.uv'), 'k0,k1,k2,k4,k5',
  'LIVENESS: uv''s 6-millisecond cell [T, T+6ms) holds k0, k1, k2, k4, k5 (k1 at T+1ms)');
select is(pg_temp.cell_rows('public.cu'), 'k0,k1,k10,k11,k2,k3,k4,k5,k6,k7,k8,k9',
  'LIVENESS: cu''s 6-second cell holds the twelve half-second rows k0 to k11');
select is(pgpm._encode('uuidv7', '2026-01-01 00:00:00+00'), pgpm._encode('uuidv7', '2026-01-01 00:00:00.0005+00'),
  'LIVENESS: uuidv7 encodes two instants 500 us apart as the same key (its unit is a millisecond)');
select is(pg_temp.oid_key('2026-01-01 00:00:01+00', 0), pg_temp.oid_key('2026-01-01 00:00:01.5+00', 0),
  'LIVENESS: the ObjectId key encodes two instants half a second apart as the same key (its unit is a second)');

-- =================== set_regrain: a whole unit is accepted, anything else is refused ===================
select lives_ok($$ select pgpm.set_regrain('public.ob', '2 seconds') $$,
  'LIVENESS: set_regrain accepts 2 seconds on the ObjectId key, which encodes whole seconds');
select throws_like($$ select pgpm.set_regrain('public.ob', '1.5 seconds') $$,
  'pg_partition_magician: regrain target step 1.5 seconds for ob is not a whole number of its control column id''s encoded unit: it is a text_time key, which encodes whole seconds%multiple of 1 second',
  'set_regrain refuses 1.5 seconds on the ObjectId key: coarser than its unit, but not a whole number of it');
select throws_like($$ select pgpm.set_regrain('public.ob', '500 milliseconds') $$,
  'pg_partition_magician: regrain target step 500 milliseconds for ob is not a whole number of its control column id''s encoded unit%',
  'set_regrain refuses 500 milliseconds on the ObjectId key, finer than its unit');
select is((select regrain_to from pgpm.config where parent_table = 'public.ob'::regclass), '2 seconds',
  'the refused calls left ob''s valid target in place');

select lives_ok($$ select pgpm.set_regrain('public.uv', '2 milliseconds') $$,
  'LIVENESS: set_regrain accepts 2 milliseconds on the uuidv7 key, which encodes whole milliseconds');
select throws_like($$ select pgpm.set_regrain('public.uv', '1500 microseconds') $$,
  'pg_partition_magician: regrain target step 1500 microseconds for uv is not a whole number of its control column id''s encoded unit: it is a uuidv7 key, which encodes whole milliseconds%multiple of 1 millisecond',
  'set_regrain refuses 1500 microseconds on the uuidv7 key');
select throws_like($$ select pgpm.set_regrain('public.uv', '500 microseconds') $$,
  'pg_partition_magician: regrain target step 500 microseconds for uv is not a whole number of its control column id''s encoded unit%',
  'set_regrain refuses 500 microseconds on the uuidv7 key, finer than its unit');
select is((select regrain_to from pgpm.config where parent_table = 'public.uv'::regclass), '2 milliseconds',
  'the refused calls left uv''s valid target in place');

-- the same 1.5 seconds is a whole number of milliseconds: the hex ms key takes it, and refuses a sub-unit step
select lives_ok($$ select pgpm.set_regrain('public.cu', '1.5 seconds') $$,
  'set_regrain accepts 1.5 seconds on the hex ms text_time key, which encodes whole milliseconds');
select throws_like($$ select pgpm.set_regrain('public.cu', '1500 microseconds') $$,
  'pg_partition_magician: regrain target step 1500 microseconds for cu is not a whole number of its control column id''s encoded unit: it is a text_time key, which encodes whole milliseconds%multiple of 1 millisecond',
  'set_regrain refuses 1500 microseconds on the hex ms key');

-- ============= the operator-driven entry points go through the same check, before any copy =============
select throws_like(format($$ select pgpm.regrain_step('public.ob', %L, '1.5 seconds') $$, pg_temp.cell_child('public.ob')),
  'pg_partition_magician: regrain target step 1.5 seconds for ob is not a whole number of its control column id''s encoded unit%',
  'regrain_step refuses 1.5 seconds on the ObjectId key before it reads or mutates anything');
select throws_like(format($$ select pgpm.regrain_step('public.uv', %L, '1500 microseconds') $$, pg_temp.cell_child('public.uv')),
  'pg_partition_magician: regrain target step 1500 microseconds for uv is not a whole number of its control column id''s encoded unit%',
  'regrain_step refuses 1500 microseconds on the uuidv7 key before it reads or mutates anything');
create function pg_temp.try_regrain(p_parent regclass, p_child name, p_step text) returns text language plpgsql as $f$
begin
  return 'swapped:' || pgpm.regrain(p_parent, p_child, p_step);
exception when others then return 'refused: ' || sqlerrm;
end $f$;
select alike(pg_temp.try_regrain('public.ob', pg_temp.cell_child('public.ob'), '1.5 seconds'),
  'refused: pg_partition_magician: regrain target step 1.5 seconds for ob is not a whole number of its control column id''s encoded unit%',
  'regrain() refuses 1.5 seconds on the ObjectId key');
select alike(pg_temp.try_regrain('public.uv', pg_temp.cell_child('public.uv'), '1500 microseconds'),
  'refused: pg_partition_magician: regrain target step 1500 microseconds for uv is not a whole number of its control column id''s encoded unit%',
  'regrain() refuses 1500 microseconds on the uuidv7 key');

-- a target an older install could have stored is refused at the tick, with the refusal's own words
update pgpm.config set regrain_to = '1.5 seconds' where parent_table = 'public.ob'::regclass;
update pgpm.config set regrain_to = '1500 microseconds' where parent_table = 'public.uv'::regclass;
call pgpm.maintain('public.ob', null);
call pgpm.maintain('public.uv', null);
select ok(exists (select 1 from pgpm.log where parent_table = 'public.ob'::regclass and action = 'skip_regrain'
                   and method like '%regrain target step 1.5 seconds for ob is not a whole number of its control column id''s encoded unit%'),
  'a stored 1.5 seconds makes ob''s tick log skip_regrain with the refusal');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.uv'::regclass and action = 'skip_regrain'
                   and method like '%regrain target step 1500 microseconds for uv is not a whole number of its control column id''s encoded unit%'),
  'a stored 1500 microseconds makes uv''s tick log skip_regrain with the refusal');
select is((select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.part
            where parent_table in ('public.ob'::regclass, 'public.uv'::regclass) and not attached), null,
  'no refused call or tick minted a fine copy of ob or uv');
select is((select string_agg(t.tgname || '@' || c.relname, ',') from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where c.relname in (pg_temp.cell_child('public.ob'), pg_temp.cell_child('public.uv'))
              and t.tgname in ('pgpm_regrain_capture', 'pgpm_regrain_truncate_guard')), null,
  'and none left the capture trigger or the TRUNCATE refusal on either cell');
update pgpm.config set regrain_to = null where parent_table in ('public.ob'::regclass, 'public.uv'::regclass);
select lives_ok($$ select pgpm.set_regrain('public.cu', null) $$, 'fixture: auto-regrain off on cu');

-- ===== a whole-unit target keeps a row deleted mid-regrain deleted (the run the refusal protects) =====
create function pg_temp.step(p_parent regclass, p_step text) returns text language plpgsql as $$
begin
  return pgpm.regrain_step(p_parent, pg_temp.cell_child(p_parent), p_step);
exception when others then return 'refused: ' || sqlerrm;
end $$;
create function pg_temp.copy_holds(p_parent regclass, p_payload text) returns boolean language plpgsql as $$
declare r record; v boolean;
begin
  for r in select child_oid from pgpm.part where parent_table = p_parent and not attached loop
    execute format('select exists (select 1 from %s where payload = %L)', r.child_oid::regclass, p_payload) into v;
    if v then return true; end if;
  end loop;
  return false;
end $$;
create function pg_temp.drive(p_parent regclass, p_step text) returns text language plpgsql as $$
declare v text; i int := 0;
begin
  loop
    v := pg_temp.step(p_parent, p_step);
    exit when v like 'swapped:%' or v like 'refused:%' or i > 40;
    i := i + 1;
  end loop;
  return v;
end $$;

create temp table st (parent_table regclass, n int, s text);
insert into st select 'public.ob', 1, pg_temp.step('public.ob', '2 seconds');   -- prepare
insert into st select 'public.ob', 2, pg_temp.step('public.ob', '2 seconds');   -- [T, T+2)
insert into st select 'public.uv', 1, pg_temp.step('public.uv', '2 milliseconds');
insert into st select 'public.uv', 2, pg_temp.step('public.uv', '2 milliseconds');
select is((select string_agg(parent_table::text || ':' || s, ',' order by parent_table::text) from st where n = 1),
  'ob:prepared,uv:prepared', 'LIVENESS: the whole-unit regrains of ob and uv were prepared');
select ok(pg_temp.copy_holds('public.ob', 'k1') and pg_temp.copy_holds('public.uv', 'k1'),
  'LIVENESS: a not-yet-attached copy of each already holds k1');
delete from public.ob where payload = 'k1';
delete from public.uv where payload = 'k1';
select ok(pgpm._regrain_delta_count('public.ob') = 1 and pgpm._regrain_delta_count('public.uv') = 1,
  'LIVENESS: capture recorded each DELETE of k1 in its delta');
select alike(pg_temp.drive('public.ob', '2 seconds'), 'swapped:%', 'LIVENESS: ob''s 2-second run reached its swap');
select alike(pg_temp.drive('public.uv', '2 milliseconds'), 'swapped:%', 'LIVENESS: uv''s 2-millisecond run reached its swap');
select results_eq($$ select payload from public.ob where payload like 'k%' order by payload $$,
  $$ values ('k0'), ('k13'), ('k2'), ('k4'), ('k5') $$,
  'ob: the row deleted mid-regrain (k1) stays deleted, and k0, k2, k4, k5, k13 remain');
select results_eq($$ select payload from public.uv where payload like 'k%' order by payload $$,
  $$ values ('k0'), ('k13'), ('k2'), ('k4'), ('k5') $$,
  'uv: the row deleted mid-regrain (k1) stays deleted, and k0, k2, k4, k5, k13 remain');
select is((with p as materialized (select child_name, lo, hi from pgpm.part where parent_table = 'public.ob'::regclass and attached)
           select string_agg(r.payload || '@' || (p.hi::timestamptz - p.lo::timestamptz)::text, ',' order by r.payload)
             from public.ob r join pg_class c on c.oid = r.tableoid join p on p.child_name = c.relname
            where r.payload in ('k0', 'k2', 'k4', 'k5')
              and pgpm._decode('text_time', r.id, '', 8, 16, 's', null)::timestamptz >= p.lo::timestamptz
              and pgpm._decode('text_time', r.id, '', 8, 16, 's', null)::timestamptz < p.hi::timestamptz),
          'k0@00:00:02,k2@00:00:02,k4@00:00:02,k5@00:00:02',
  'ob: each surviving row of the cell sits in a recorded 2-second cell that holds its decoded instant');

-- ===== the asymmetric half: 1.5 seconds on the ms key splits and keeps every row in its own cell =====
select alike(pg_temp.try_regrain('public.cu', pg_temp.cell_child('public.cu'), '1.5 seconds'), 'swapped:%',
  'regrain() splits the hex ms key''s cell at 1.5 seconds');
select is((with p as materialized (select child_name, lo, hi from pgpm.part where parent_table = 'public.cu'::regclass and attached)
           select string_agg(r.payload || '@' || (p.hi::timestamptz - p.lo::timestamptz)::text, ',' order by (substr(r.payload, 2))::int)
             from public.cu r join pg_class c on c.oid = r.tableoid join p on p.child_name = c.relname
            where r.payload like 'k%' and r.payload <> 'k30'
              and pgpm._decode('text_time', r.id, '', 12, 16, 'ms', null)::timestamptz >= p.lo::timestamptz
              and pgpm._decode('text_time', r.id, '', 12, 16, 'ms', null)::timestamptz < p.hi::timestamptz),
          (select string_agg('k' || g || '@00:00:01.5', ',' order by g) from generate_series(0, 11) g),
  'cu: k0 to k11 each sit in a recorded 1.5-second cell that holds its decoded instant');
select is((select count(distinct tableoid) from public.cu where payload like 'k%' and payload <> 'k30'), 4::bigint,
  'cu: twelve half-second rows, four 1.5-second cells (three apiece)');
select set_eq($$ select id, payload from public.cu $$, $$ select id, payload from before_cu $$,
  'cu: every row survived the split with its own key and payload');
select is((select count(*) from pgpm.part where parent_table = 'public.cu'::regclass and not attached), 0::bigint,
  'cu: no copy left unattached after the swap');

-- ======== door 1: transmute holds a uuidv7 anchor and step to whole milliseconds, as #989 does text_time's ========
-- (pass-10 per-PR verification V-01: a half-millisecond anchor registered, a whole-millisecond target then cut
-- bounds off the unit and a row deleted mid-regrain came back at the swap)
create table public.ua (id uuid primary key, payload text);
insert into public.ua select pg_temp.u7(now() - interval '1 day' + make_interval(secs => s), s), 'a' || s
  from generate_series(0, 2) s;
select throws_like($$ call pgpm.transmute('public.ua', 'id', interval '6 milliseconds', p_obtain => 2,
                                           p_anchor => '2000-01-01 00:00:00.0005+00') $$,
  'pg_partition_magician: cannot partition ua on id with step 00:00:00.006 and anchor 2000-01-01 00:00:00.0005+00 -- its uuidv7 encoding counts whole milliseconds%',
  'transmute refuses a uuidv7 anchor half a millisecond off the unit');
select throws_like($$ call pgpm.transmute('public.ua', 'id', interval '4500 microseconds', p_obtain => 2) $$,
  'pg_partition_magician: cannot partition ua on id with step 00:00:00.0045 and anchor 2000-01-01 00:00:00+00 -- its uuidv7 encoding counts whole milliseconds%',
  'transmute refuses a uuidv7 partition_step that is not a whole number of milliseconds');
-- #1113: a sub-millisecond step committed and validated the monolith's bound CHECK and then died at the
-- cutover on 'empty range bound', leaving the table rejecting current writes; 1500 microseconds converted with
-- pgpm.part bounds half a millisecond off the attached ones. Both are refused before anything commits.
create table public.ub (id uuid primary key, payload text);
insert into public.ub select pg_temp.u7(now() - interval '1 day' + make_interval(secs => s), s), 'b' || s
  from generate_series(0, 2) s;
select throws_like($$ call pgpm.transmute('public.ub', 'id', interval '500 microseconds', p_obtain => 4) $$,
  'pg_partition_magician: cannot partition ub on id with step 00:00:00.0005 and anchor 2000-01-01 00:00:00+00 -- its uuidv7 encoding counts whole milliseconds%',
  'transmute refuses a 500 microsecond uuidv7 step, finer than the unit');
select throws_like($$ call pgpm.transmute('public.ub', 'id', interval '1500 microseconds', p_obtain => 4) $$,
  'pg_partition_magician: cannot partition ub on id with step 00:00:00.0015 and anchor 2000-01-01 00:00:00+00 -- its uuidv7 encoding counts whole milliseconds%',
  'transmute refuses a 1500 microsecond uuidv7 step, coarser than the unit but not a whole number of it');
select is((select string_agg(conname, ',') from pg_constraint
            where conrelid = 'public.ub'::regclass and conname = 'pgpm_monolith_bound'), null,
  'the refused steps left no write-rejecting pgpm_monolith_bound CHECK on ub');
select lives_ok($$ insert into public.ub values (pg_temp.u7(clock_timestamp() + interval '1 hour', 99), 'current') $$,
  'and ub still takes a current write');
select is((select relkind::text from pg_class where oid = 'public.ua'::regclass)
          || ':' || (select count(*) from pgpm.config where parent_table = 'public.ua'::regclass), 'r:0',
  'the refused conversions left ua a plain table with no grid registered');
call pgpm.transmute('public.ua', 'id', interval '6 milliseconds', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.ua'::regclass)
          || ':' || (select count(*) from pgpm.config where parent_table = 'public.ua'::regclass), 'p:1',
  'LIVENESS: the same table converts with a whole-millisecond step and the default anchor');

-- ===== door 2: a grid an older install registered off the unit is refused any regrain, fresh or resumed =====
-- Registered by hand, as tests/277's domain parents are: transmute now refuses these grids, and an install
-- that predates it registered them as given.
create table public.hu (id uuid not null) partition by range (id);
create table public.hs (id uuid not null) partition by range (id);
create table public.hk (id uuid not null) partition by range (id);
create table public.ht (id text collate "C" not null) partition by range (id);
insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor)
  values ('public.hu', 'id', 'uuidv7', '6 milliseconds', '2000-01-01 00:00:00.0005+00'),
         ('public.hs', 'id', 'uuidv7', '4500 microseconds', '2000-01-01 00:00:00+00'),
         ('public.hk', 'id', 'uuidv7', '6 milliseconds', '2000-01-01 00:00:00+00');
insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor,
                         text_time_prefix, text_time_width, text_time_radix, text_time_unit)
  values ('public.ht', 'id', 'text_time', '6 seconds', '2000-01-01 00:00:00.5+00', '', 8, 16, 's');
select is((select string_agg(parent_table::text || '@' || (extract(microseconds from partition_anchor::timestamptz)::bigint % 1000000)
                             || '/' || partition_step, ',' order by parent_table::text)
             from pgpm.config where parent_table in ('public.hu'::regclass, 'public.hs'::regclass, 'public.ht'::regclass)),
          'hs@0/4500 microseconds,ht@500000/6 seconds,hu@500/6 milliseconds',
  'LIVENESS: the off-unit grids are registered: hu''s anchor 500 us off, hs''s step 4.5 ms, ht''s anchor half a second off');
select lives_ok($$ select pgpm.set_regrain('public.hk', '1 millisecond') $$,
  'LIVENESS: set_regrain accepts 1 millisecond on a hand-registered uuidv7 grid that is on the unit');
select throws_like($$ select pgpm.set_regrain('public.hu', '1 millisecond') $$,
  'pg_partition_magician: cannot regrain hu -- its grid is not on its control column id''s encoded unit: it is a uuidv7 key, which encodes whole milliseconds%partition_anchor 2000-01-01 00:00:00.0005+00%',
  'set_regrain refuses a whole-millisecond target on a uuidv7 grid whose registered anchor is off the unit');
select throws_like($$ select pgpm.regrain_step('public.hu', 'hu_any', '1 millisecond') $$,
  'pg_partition_magician: cannot regrain hu -- its grid is not on its control column id''s encoded unit%',
  'regrain_step refuses it too, before it looks for the child, so a resumed run is refused as a fresh one is');
select throws_like($$ select pgpm.set_regrain('public.hs', '9 milliseconds') $$,
  'pg_partition_magician: cannot regrain hs -- its grid is not on its control column id''s encoded unit%partition_step 4500 microseconds%',
  'set_regrain refuses a whole-millisecond target on a uuidv7 grid whose registered step is off the unit');
select throws_like($$ select pgpm.set_regrain('public.ht', '2 seconds') $$,
  'pg_partition_magician: cannot regrain ht -- its grid is not on its control column id''s encoded unit: it is a text_time key, which encodes whole seconds from 1970-01-01 00:00:00+00%',
  'set_regrain refuses a whole-second target on a text_time grid whose registered anchor is off its unit');
select is((select string_agg(parent_table::text || '=' || coalesce(regrain_to, 'null'), ',' order by parent_table::text)
             from pgpm.config where parent_table in ('public.hu'::regclass, 'public.hs'::regclass,
                                                    'public.ht'::regclass, 'public.hk'::regclass)),
          'hk=1 millisecond,hs=null,ht=null,hu=null',
  'the refused grids stored no target, and the grid on the unit kept its own');

select * from finish();
