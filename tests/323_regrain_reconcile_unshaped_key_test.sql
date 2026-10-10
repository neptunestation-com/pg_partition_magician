-- Issue #709, the regrain reconcile's decode (review pass 11, F3-01; #1123's P1-02): a captured text_time key
-- that the table accepts but that lacks the declared shape is reconciled into the fine child that holds it,
-- by its ENCODED value, the way the copy placed its row; it never wedges the run.
--
-- THE DEFECT. _regrain_reconcile grouped every batch by _grid_floor(_decode(key)), and _decode raises 22P02 on
-- a text_time value that is too short or holds a character outside the alphabet. Such a value is a legal row
-- (the column is text; the partition bound only compares strings), pgpm itself treats one as reachable
-- (_frontier_native, #661), and the copy moves it without decoding it. So an ordinary DELETE of one after
-- the copy passed it (F3-01), or a key written straight into the delta by any role with INSERT on the table
-- (P1-02), raised on every later tick and at the swap, with the cursor never moving, until regrain_cancel.
-- Discarding the key instead would be wrong too: the copy already put the row in a fine child, so a
-- discarded DELETE comes back at the swap and a discarded UPDATE or INSERT is lost with the source.
--
-- (A) carries a three-way asymmetric DML set on off-shape keys (one DELETE, one UPDATE, one INSERT, each in a
-- different sub-range) plus a shaped UPDATE in the same batch and a forged delta row naming no source row,
-- and every assertion names the rows. (B) is the aged path for an off-shape key: discarded and counted as
-- regrain_reconcile_aged, because no fine child exists for it and the range is below the horizon. (C) is the
-- other half: an off-shape key whose fine child is missing in a range that is NOT aged refuses, and keeps the
-- key, exactly as a shaped one does (tests/120 (C)). bench/regrain_reconcile_unshaped_key.sh runs this file
-- against the mutant regrain_reconcile_decodes_unshaped_key.
set timezone = 'UTC';
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(42);

create function pg_temp.tt(p_ts timestamptz) returns text language sql immutable as $$
  select pgpm._ts_to_text_time(p_ts, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') $$;
create function pg_temp.shaped(p_key text) returns boolean language sql immutable as $$
  select pgpm._text_time_shaped(p_key, '', 10, 32, '0123456789ABCDEFGHJKMNPQRSTVWXYZ') $$;
create function pg_temp.delta_ids(p_parent regclass) returns text language plpgsql as $f$
declare v text;
begin
  execute format('select string_agg(id, '','' order by id) from %s',
                 (select regrain_delta_oid::regclass from pgpm.config where parent_table = p_parent)) into v;
  return v;
end $f$;
-- one fine child's payloads, by the child pgpm.part recorded for this regrain at [lo, ...)
create function pg_temp.child_payloads(p_parent regclass, p_lo timestamptz) returns text language plpgsql as $f$
declare v text; v_rel regclass;
begin
  select child_oid::regclass into v_rel from pgpm.part
   where parent_table = p_parent and not attached and lo::timestamptz = p_lo;
  execute format('select string_agg(payload, '','' order by payload) from %s', v_rel) into v;
  return v;
end $f$;

-- ============ (A) off-shape keys in three sub-ranges, reconciled by their encoded value ============
-- ULID-shaped keys (no prefix, 10 Crockford base-32 digits of milliseconds). The cell [T, T+1 day) is a forward
-- partition, frozen by a row two days on, and regrained to 6 hours: S0 [T, T+6h), S1, S2, S3.
create table public.ru (id text collate "C" primary key, payload text);
insert into public.ru values (pg_temp.tt('2024-01-01 12:00+00') || 'H', 'history');
call pgpm.transmute('public.ru', 'id', interval '1 day', p_obtain => 4, p_paused => true,
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
create temp table cell as
  select lo::timestamptz as t, child_name from pgpm.part where parent_table = 'public.ru'::regclass and attached
   order by lo::timestamptz offset 1 limit 1;
-- the off-shape keys: a key's first 8 or 9 characters (too short), or one holding 'U', which Crockford omits
create temp table k as select
  left(pg_temp.tt(t + interval '9 hours'), 8)                                    as oa,   -- S1, deleted later
  left(pg_temp.tt(t + interval '3 hours'), 9)                                    as ob,   -- S0, updated later
  overlay(pg_temp.tt(t + interval '14 hours') placing 'U' from 10 for 1) || 'X'  as oc,   -- S2, inserted later
  overlay(pg_temp.tt(t + interval '4 hours') placing 'U' from 10 for 1) || 'F'   as forged, -- S0, delta only
  pg_temp.tt(t + interval '7 hours') || 'S'                                      as s1a  -- S1, shaped, updated later
  from cell;
insert into public.ru
  select pg_temp.tt(t + interval '1 hour') || 'S', 's0a' from cell union all
  select pg_temp.tt(t + interval '2 hours') || 'S', 's0b' from cell union all
  select s1a, 's1a' from k union all
  select pg_temp.tt(t + interval '13 hours') || 'S', 's2a' from cell union all
  select pg_temp.tt(t + interval '19 hours') || 'S', 's3a' from cell union all
  select oa, 'oa' from k union all
  select ob, 'ob' from k union all
  select pg_temp.tt(t + interval '2 days 1 hour') || 'S', 'frontier' from cell;

select ok((select not pg_temp.shaped(oa) and not pg_temp.shaped(ob) and not pg_temp.shaped(oc)
                  and not pg_temp.shaped(forged) and pg_temp.shaped(s1a) from k),
  'LIVENESS: oa, ob, oc and the forged key lack the declared text_time shape; s1a has it');
select throws_like(
  (select format($$ select pgpm._decode('text_time', %L, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') $$, oa) from k),
  '%does not have the expected text_time shape%', 'LIVENESS: oa (too short) does not decode');
select throws_like(
  (select format($$ select pgpm._decode('text_time', %L, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') $$, oc) from k),
  '%not a valid base-32 digit string%', 'LIVENESS: oc (a character outside the alphabet) does not decode');
select is((select string_agg(r.payload, ',' order by r.payload) from public.ru r join pg_class c on c.oid = r.tableoid
            where c.relname = (select child_name from cell)),
  'oa,ob,s0a,s0b,s1a,s2a,s3a', 'GUARD: the cell holds the five shaped rows and the two off-shape ones');

select is(pgpm.regrain_step('public.ru', (select child_name from cell), '6 hours', 1000), 'prepared',
  'tick 1 installs capture');
select is(pgpm.regrain_step('public.ru', (select child_name from cell), '6 hours', 1000), 'copied:3', 'tick 2 copies S0');
select is(pgpm.regrain_step('public.ru', (select child_name from cell), '6 hours', 1000), 'copied:2', 'tick 3 copies S1');
select is(pgpm.regrain_step('public.ru', (select child_name from cell), '6 hours', 1000), 'copied:1', 'tick 4 copies S2');
select is((select regrain_cursor::timestamptz from pgpm.config where parent_table = 'public.ru'::regclass),
  (select t + interval '18 hours' from cell), 'LIVENESS: the cursor is at S3: S0, S1 and S2 are finished, so their keys are eligible');
select is(pg_temp.child_payloads('public.ru', (select t + interval '6 hours' from cell)), 'oa,s1a',
  'LIVENESS: the copy placed oa in S1''s fine child, so a discarded DELETE of it would come back at the swap');
select is(pg_temp.child_payloads('public.ru', (select t from cell)), 'ob,s0a,s0b',
  'LIVENESS: and ob in S0''s, so a discarded UPDATE of it would be lost');

-- committed DML on the finished sub-ranges, and a forged delta row (#1123 P1-02's route) naming no source row
delete from public.ru where id = (select oa from k);
update public.ru set payload = 'ob-updated' where id = (select ob from k);
insert into public.ru select oc, 'oc-inserted' from k;
update public.ru set payload = 's1a-updated' where id = (select s1a from k);
select regrain_delta_oid::regclass::text as ru_delta from pgpm.config where parent_table = 'public.ru'::regclass \gset
insert into :ru_delta (id) select forged from k;
select is(pg_temp.delta_ids('public.ru'),
  (select array_to_string(array(select x from unnest(array[oa, ob, ob, oc, forged, s1a, s1a]) x order by x), ',') from k),
  'LIVENESS: the delta holds the seven captured keys (each UPDATE writes OLD and NEW), four of them off-shape');
select ok(not exists (select 1 from public.ru where id = (select forged from k)),
  'LIVENESS: the forged key names no row of the table');

select lives_ok($$ select pgpm.regrain_step('public.ru', (select child_name from cell), '6 hours', 1000) $$,
  'tick 5 reconciles the batch: no tick raises on an off-shape key');
select is(pg_temp.delta_ids('public.ru'), null, 'and it consumed every captured key: the delta is empty');
select is((select rows from pgpm.log where parent_table = 'public.ru'::regclass and action = 'regrain_reconcile'),
  7::bigint, 'WITNESS: the regrain_reconcile row counts all seven');
select is((select count(*)::int from pgpm.log where parent_table = 'public.ru'::regclass and action = 'regrain_reconcile_aged'),
  0, 'and none was taken for aged: there is no retention policy');
select is((select regrain_cursor::timestamptz from pgpm.config where parent_table = 'public.ru'::regclass),
  (select t + interval '18 hours' from cell), 'the reconcile took the tick, so the cursor has not moved past S3 yet');

-- before the swap: each fine child, by identity
select is(pg_temp.child_payloads('public.ru', (select t from cell)), 'ob-updated,s0a,s0b',
  'S0''s child: ob carries its update; the forged key added nothing');
select is(pg_temp.child_payloads('public.ru', (select t + interval '6 hours' from cell)), 's1a-updated',
  'S1''s child: oa is gone and the shaped s1a carries its update, in the same batch');
select is(pg_temp.child_payloads('public.ru', (select t + interval '12 hours' from cell)), 'oc-inserted,s2a',
  'S2''s child: oc, inserted after the copy passed S2, is there');

select is(pgpm.regrain_step('public.ru', (select child_name from cell), '6 hours', 1000), 'copied:1', 'tick 6 copies S3');
select is(pgpm.regrain_step('public.ru', (select child_name from cell), '6 hours', 1000), 'swapped:4',
  'tick 7 swaps: the run finished');
select is((select string_agg(r.payload, ',' order by r.payload) from public.ru r
            where r.id >= pg_temp.tt((select t from cell)) and r.id < pg_temp.tt((select t + interval '1 day' from cell))),
  'ob-updated,oc-inserted,s0a,s0b,s1a-updated,s2a,s3a',
  'after the swap the day holds exactly what was committed: oa deleted, ob and s1a updated, oc inserted');
select is((select id from public.ru where payload = 'oc-inserted'), (select oc from k),
  'and oc is there under its own key');
select ok(to_regclass('public.' || (select child_name from cell)) is null
          and (select count(distinct r.tableoid) from public.ru r
                where r.id >= pg_temp.tt((select t from cell)) and r.id < pg_temp.tt((select t + interval '1 day' from cell))) = 4,
  'WITNESS: those rows are served by the four fine children: the source is gone, the swap really happened');

-- ============ (B) an off-shape key in an aged sub-range is discarded and counted ============
-- retain 3 days on a day grid: the monolith's sub-ranges below the horizon are skipped as aged (no fine child),
-- and a captured change to an off-shape row in one of them goes with the source, logged as aged.
create table public.rv (id text collate "C" primary key, payload text);
insert into public.rv select pg_temp.tt(date_trunc('day', now()) - make_interval(days => d) + interval '12 hours') || 'R', 'd' || d
  from generate_series(1, 8) d;
insert into public.rv values (left(pg_temp.tt(date_trunc('day', now()) - interval '6 days' + interval '9 hours'), 8), 'aged-odd');
call pgpm.transmute('public.rv', 'id', interval '1 day', p_obtain => 2, p_paused => true, p_retain => '3 days',
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
create temp table mono as
  select child_name, lo::timestamptz as lo, hi::timestamptz as hi from pgpm.part
   where parent_table = 'public.rv'::regclass and attached order by lo::timestamptz limit 1;
insert into public.rv select pg_temp.tt(hi + interval '1 hour') || 'F', 'frontier' from mono;
select is(pgpm.regrain_step('public.rv', (select child_name from mono), '1 day', 1000), 'prepared', 'aged: tick 1 installs capture');
select is(pgpm.regrain_step('public.rv', (select child_name from mono), '1 day', 1000), 'copied:1',
  'aged: tick 2 skips the aged sub-ranges and copies the first one at the horizon');
select ok((select count(*) from pgpm.log where parent_table = 'public.rv'::regclass and action = 'regrain_aged') >= 4,
  'LIVENESS: the sub-ranges below the horizon were skipped as aged, so no fine child exists for them');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.rv'::regclass and not attached
                       and lo::timestamptz <= date_trunc('day', now()) - interval '6 days'
                       and hi::timestamptz > date_trunc('day', now()) - interval '6 days'),
  'LIVENESS: in particular none holds the aged-odd row''s day');
delete from public.rv where payload = 'aged-odd';
select is(pg_temp.delta_ids('public.rv'), left(pg_temp.tt(date_trunc('day', now()) - interval '6 days' + interval '9 hours'), 8),
  'LIVENESS: the DELETE of the off-shape row is captured, below the cursor');
select is(pgpm.regrain_step('public.rv', (select child_name from mono), '1 day', 1000), 'reconciled:1',
  'aged: tick 3 consumes it rather than raising');
select is((select hi::timestamptz from pgpm.log where parent_table = 'public.rv'::regclass and action = 'regrain_reconcile_aged'),
  (select min(lo::timestamptz) from pgpm.part where parent_table = 'public.rv'::regclass and not attached),
  'and says so: one regrain_reconcile_aged row whose range ends at the first fine child, the aged run the key fell in');
select ok((select hi from pgpm.log where parent_table = 'public.rv'::regclass and action = 'regrain_reconcile_aged')::timestamptz
          <= (select pgpm._retain_boundary(c)::timestamptz from pgpm.config c where parent_table = 'public.rv'::regclass),
  'WITNESS: that range lies below the retention horizon');
select is(pg_temp.delta_ids('public.rv'), null, 'the delta is clear');

-- ============ (C) an off-shape key whose fine child is missing in a range that is not aged refuses ============
create table public.rw (id text collate "C" primary key, payload text);
insert into public.rw values (pg_temp.tt('2024-01-01 12:00+00') || 'H', 'history');
call pgpm.transmute('public.rw', 'id', interval '1 day', p_obtain => 4, p_paused => true,
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
create temp table cw as
  select lo::timestamptz as t, child_name from pgpm.part where parent_table = 'public.rw'::regclass and attached
   order by lo::timestamptz offset 1 limit 1;
insert into public.rw
  select pg_temp.tt(t + interval '1 hour') || 'S', 'w0' from cw union all
  select left(pg_temp.tt(t + interval '3 hours'), 8), 'w-odd' from cw union all
  select pg_temp.tt(t + interval '7 hours') || 'S', 'w1' from cw union all
  select pg_temp.tt(t + interval '2 days 1 hour') || 'S', 'frontier' from cw;
select is(pgpm.regrain_step('public.rw', (select child_name from cw), '6 hours', 1000), 'prepared', 'not aged: tick 1 installs capture');
select is(pgpm.regrain_step('public.rw', (select child_name from cw), '6 hours', 1000), 'copied:2', 'not aged: tick 2 copies S0');
select is(pgpm.regrain_step('public.rw', (select child_name from cw), '6 hours', 1000), 'copied:1', 'not aged: tick 3 copies S1');
-- S0's copy disappears out from under pgpm, then the off-shape row in it is deleted
select child_oid::regclass::text as rw_s0 from pgpm.part
 where parent_table = 'public.rw'::regclass and not attached and lo::timestamptz = (select t from cw) \gset
drop table :rw_s0;
delete from pgpm.part where parent_table = 'public.rw'::regclass and not attached and lo::timestamptz = (select t from cw);
delete from public.rw where payload = 'w-odd';
select is(pg_temp.delta_ids('public.rw'), (select left(pg_temp.tt(t + interval '3 hours'), 8) from cw),
  'LIVENESS: the DELETE is captured, below the cursor, in a range with no fine child and no retention policy');
select throws_like(
  $$ select pgpm.regrain_step('public.rw', (select child_name from cw), '6 hours', 1000) $$,
  'pg_partition_magician: internal error reconciling%no fine child%not below the retention horizon%',
  'the tick refuses: a missing child for a range that is not aged is not an aged range');
select is(pg_temp.delta_ids('public.rw'), (select left(pg_temp.tt(t + interval '3 hours'), 8) from cw),
  'and the captured key is still in the delta: nothing was discarded');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rw'::regclass and action = 'regrain_reconcile_aged'),
  0, 'and it was not logged as aged');

select * from finish();
