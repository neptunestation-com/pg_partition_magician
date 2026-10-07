-- Issue #989: a text_time grid's anchor and step must be whole multiples of the encoding's unit.
--
-- _ts_to_text_time floors every bound to the unit (a whole second for ObjectId, a millisecond for cuid,
-- ULID), counted from p_tt_epoch. transmute accepted p_anchor '2000-01-01 00:00:00.5+00' on a seconds grid,
-- so pgpm.part recorded every bound half a second above the bound the catalog holds: a row decoding to
-- 2026-10-11 00:00:00 sat in the partition recorded as [2026-10-11 00:00:00.5, ...). transmute now refuses
-- an anchor or a step the encoding cannot express, before anything is touched, as _id_step_contract does
-- for a numeric column's scale.
--
-- The rule is relative to the unit and to the epoch, not "whole seconds": the same half-second anchor is a
-- whole number of milliseconds, so an 'ms' grid takes it, and its recorded bounds are then exactly the
-- catalog's (the identity the defect broke, asserted bound by bound below). And a whole-second anchor is
-- not a whole number of seconds from an epoch that carries a fraction.
create extension if not exists pgtap;

select plan(10);

-- An ObjectId-shaped key (8 hex digits of seconds) and a 12-hex-digit millisecond key. Five rows and three,
-- so neither table's survival can stand in for the other's.
create table public.oid_s (id text collate "C" primary key, v int);
insert into public.oid_s
  select lpad(to_hex(extract(epoch from t)::bigint), 8, '0') || '0000000000000001', 1
    from generate_series(now() - interval '20 days', now(), interval '5 days') t;
create table public.hex_ms (id text collate "C" primary key, v int);
insert into public.hex_ms
  select lpad(to_hex((extract(epoch from t) * 1000)::bigint), 12, '0') || 'aaaa', 2
    from generate_series(now() - interval '10 days', now(), interval '5 days') t;

-- 1-4: refusals, each before anything is touched. The messages are pinned (throws_like): a transmute that
-- did not refuse would die at its first COMMIT inside pgTAP's function with 2D000, which must not pass.
select throws_like(
  $$ call pgpm.transmute('public.oid_s', 'id', interval '1 day', p_obtain => 3,
       p_anchor => '2000-01-01 00:00:00.5+00',
       p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's') $$,
  'pg_partition_magician: cannot partition %oid_s on id with step 1 day and anchor %whole multiples of 1 second from %',
  'transmute refuses an anchor half a second off a seconds-unit text_time grid'
);

select throws_like(
  $$ call pgpm.transmute('public.oid_s', 'id', interval '1 day 0.5 seconds', p_obtain => 3,
       p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's') $$,
  'pg_partition_magician: cannot partition %oid_s on id with step 1 day 00:00:00.5 and anchor %whole multiples of 1 second from%',
  'transmute refuses a step that is not a whole number of seconds on a seconds-unit grid'
);

select throws_like(
  $$ call pgpm.transmute('public.hex_ms', 'id', interval '1 day', p_obtain => 3,
       p_anchor => '2000-01-01 00:00:00.0005+00',
       p_tt_prefix => '', p_tt_width => 12, p_tt_radix => 16, p_tt_unit => 'ms') $$,
  'pg_partition_magician: cannot partition %hex_ms on id with step 1 day and anchor %whole multiples of 1 millisecond from%',
  'transmute refuses an anchor half a millisecond off a millisecond-unit text_time grid'
);

select throws_like(
  $$ call pgpm.transmute('public.oid_s', 'id', interval '1 day', p_obtain => 3,
       p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's',
       p_tt_epoch => '1970-01-01 00:00:00.5+00') $$,
  'pg_partition_magician: cannot partition %oid_s on id with step 1 day and anchor %whole multiples of 1 second from %:00.5%',
  'transmute measures the anchor from p_tt_epoch: a whole-second anchor is refused against an epoch carrying a half second'
);

-- 5: the refusals left the seconds table as it was: a plain table, no claim, its five rows.
select results_eq(
  $$ select (select c.relkind::text from pg_class c where c.oid = 'public.oid_s'::regclass),
            (select count(*) from pgpm.config where parent_table = 'public.oid_s'::regclass)::int,
            (select count(*) from public.oid_s)::int $$,
  $$ values ('r', 0, 5) $$,
  'the refused transmutes left public.oid_s a plain, unmanaged table holding its five rows'
);

-- The half-second anchor is a whole number of milliseconds, so the 'ms' grid takes it.
call pgpm.transmute('public.hex_ms', 'id', interval '1 day', p_obtain => 3,
  p_anchor => '2000-01-01 00:00:00.5+00',
  p_tt_prefix => '', p_tt_width => 12, p_tt_radix => 16, p_tt_unit => 'ms');

-- 6: LIVENESS. The acceptance is real: the 'ms' table is partitioned and managed, with its three rows.
select results_eq(
  $$ select (select c.relkind::text from pg_class c where c.oid = 'public.hex_ms'::regclass),
            (select count(*) from pgpm.config where parent_table = 'public.hex_ms'::regclass)::int,
            (select count(*) from public.hex_ms)::int $$,
  $$ values ('p', 1, 3) $$,
  'transmute accepted the same half-second anchor on a millisecond grid: public.hex_ms is partitioned and managed, its three rows kept'
);

-- The parent's attached cells, bound read from the catalog, the parent filtered first (#973).
create temporary table _hex_cells as
  with mine as materialized (
    select p.child_oid, p.lo, p.hi from pgpm.part p
     where p.parent_table = 'public.hex_ms'::regclass and p.attached
  )
  select m.child_oid, m.lo, m.hi,
         (regexp_match(pg_get_expr(c.relpartbound, c.oid), $re$FROM \('([^']*)'\) TO \('([^']*)'\)$re$))[1] as cat_lo,
         (regexp_match(pg_get_expr(c.relpartbound, c.oid), $re$FROM \('([^']*)'\) TO \('([^']*)'\)$re$))[2] as cat_hi
    from mine m join pg_class c on c.oid = m.child_oid;

-- 7: LIVENESS. The cells exist and carry the anchor's half second, so the identity below is not vacuous
-- (a grid on whole seconds would agree with any floor).
select ok(
  (select count(*) from _hex_cells where cat_lo is not null) >= 3
  and (select bool_and(extract(microseconds from lo::timestamptz)::bigint % 1000000 = 500000) from _hex_cells),
  'public.hex_ms has at least three attached cells, every recorded lower bound half a second past the second'
);

-- 8-9: the identity #989 broke. Every recorded bound is exactly the instant the catalog's bound decodes to.
select is_empty(
  $$ select child_oid::regclass::text, lo, pgpm._text_time_to_ts(cat_lo, '', 12, 16, 'ms')
       from _hex_cells where pgpm._text_time_to_ts(cat_lo, '', 12, 16, 'ms') <> lo::timestamptz $$,
  'every hex_ms cell''s recorded lo is the instant its catalog lower bound decodes to'
);
select is_empty(
  $$ select child_oid::regclass::text, hi, pgpm._text_time_to_ts(cat_hi, '', 12, 16, 'ms')
       from _hex_cells where pgpm._text_time_to_ts(cat_hi, '', 12, 16, 'ms') <> hi::timestamptz $$,
  'every hex_ms cell''s recorded hi is the instant its catalog upper bound decodes to'
);

-- 10: and a whole-second anchor still converts the seconds table (the refusal is of the fraction, not of
-- ObjectId grids).
call pgpm.transmute('public.oid_s', 'id', interval '1 day', p_obtain => 3,
  p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's');
select results_eq(
  $$ select (select c.relkind::text from pg_class c where c.oid = 'public.oid_s'::regclass),
            (select count(*) from public.oid_s)::int $$,
  $$ values ('p', 5) $$,
  'a whole-second anchor converts public.oid_s, its five rows kept'
);

select * from finish();
