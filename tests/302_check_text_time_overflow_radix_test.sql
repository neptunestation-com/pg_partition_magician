-- check_text_time counts a shaped value it cannot decode as implausible instead of aborting the sample
-- (issue #1084), and refuses a supplied alphabet's radix below 2, as transmute does (issue #1039 bullet 3).
--
-- (A) The shape gate (_text_time_shaped) bounds the characters, not the number they spell. With prefix 'c',
-- nine base-36 digits and unit 's', 'czzzzzzzzz...' is the declared shape and decodes to ~1.0e14 seconds,
-- past what an interval holds (~9.2e12 s), so _text_time_to_ts raised 'interval out of range' and the whole
-- report raised with it, where the reference promises that one bad row never aborts the sample and that a
-- maximum which cannot be decoded reports null. Both decodes now go through _text_time_to_ts_bounded, which
-- reports null for such a count. Fixtures are asymmetric: twenty decodable rows and one that is not (which
-- is also the column's maximum), in seconds and again in milliseconds; and a control column whose maximum
-- is far in the future but decodable (year 3000), which must still be reported as that instant, so the
-- bound is a bound and not "null for anything large". Then each of the decode's two limits on its own: a
-- count that overflows the interval while the instant it names is a timestamptz (an epoch before 1970),
-- and one that fits the interval and names an instant past the timestamptz range (an epoch after 1970),
-- with the second count decoding under the Unix epoch as the control.
--
-- (B) check_text_time's radix floor (< 2) sat only on the default-alphabet branch; with a supplied alphabet
-- it checked the length alone, so radix 1 with alphabet 'x' sampled a shape transmute refuses (#990). Both
-- now ask _text_time_radix_floor. The control: radix 2 with 'ab' is accepted and samples its rows.
--
-- (C) The rest of the shape transmute refuses (#1120), and the unit before any decode (the PR-verification
-- finding P1-03 on #1084's fix). check_text_time checked neither the width (0 decodes every value to the
-- epoch), nor the discard bits (-1 doubles every count), nor the unit up front: _text_time_to_ts_bounded returns
-- null for a count past its limits before the decoder's unit check is reached, so on a column whose shaped
-- values all overflow, unit 'h' was reported on (2 sampled, 0 plausible, a null maximum), and on a column with
-- no shaped value it always was. Each is refused now, before a row is read, with transmute's refusal of the
-- same shape witnessed beside it; the overflow column's values are witnessed to overflow (the bounded decode
-- swallows them under 's'), so the unit refusal there is not the decoder's.
--
-- bench/check_text_time_contract.sh runs this file against the mutants check_text_time_decode_unbounded,
-- check_text_time_radix_floor_dropped, check_text_time_unit_after_decode and
-- check_text_time_shape_floor_dropped, so it is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(26);

-- The error a statement raised, its SQLSTATE first; 'completed' if it raised none.
create function pg_temp._attempt(p_sql text) returns text language plpgsql as $f$
begin
  execute p_sql;
  return 'completed';
exception when others then
  return sqlstate || ' ' || sqlerrm;
end;
$f$;

-- ================================ (A) a shaped value past the decode's range ================================
create table public.tt302s (id text collate "C" primary key);
insert into public.tt302s
  select 'c' || pgpm._ts_to_text_time(now() - g * interval '1 minute', '', 9, 36, 's') || 'xyz'
    from generate_series(1, 20) g;
insert into public.tt302s values ('czzzzzzzzzabc');

create table public.tt302m (id text collate "C" primary key);
insert into public.tt302m
  select 'c' || pgpm._ts_to_text_time(now() - g * interval '1 minute', '', 12, 36, 'ms') || 'xyz'
    from generate_series(1, 20) g;
insert into public.tt302m values ('czzzzzzzzzzzzabc');

create table public.tt302f (id text collate "C" primary key);
insert into public.tt302f
  select 'c' || pgpm._ts_to_text_time(now() - g * interval '1 minute', '', 9, 36, 's') || 'xyz'
    from generate_series(1, 20) g;
insert into public.tt302f values ('c' || pgpm._ts_to_text_time(timestamptz '3000-01-01 00:00:00+00', '', 9, 36, 's') || 'far');

-- 1-2: LIVENESS. Each bad row has the declared shape and the plain decode raises on it; the other twenty in
-- each table decode to the last half hour.
select results_eq(
  $$ select pgpm._text_time_shaped('czzzzzzzzzabc', 'c', 9, 36),
            pgpm._text_time_shaped('czzzzzzzzzzzzabc', 'c', 12, 36),
            left(pg_temp._attempt($q$ select pgpm._text_time_to_ts('czzzzzzzzzabc', 'c', 9, 36, 's') $q$), 5),
            left(pg_temp._attempt($q$ select pgpm._text_time_to_ts('czzzzzzzzzzzzabc', 'c', 12, 36, 'ms') $q$), 5) $$,
  $$ values (true, true, '22008', '22008') $$,
  'LIVENESS: both bad rows have the declared shape and the plain decode raises on each (22008, out of range)');
select results_eq(
  $$ select (select count(*) from public.tt302s where id <> 'czzzzzzzzzabc'
               and pgpm._text_time_to_ts(id, 'c', 9, 36, 's') > now() - interval '30 minutes'),
            (select count(*) from public.tt302m where id <> 'czzzzzzzzzzzzabc'
               and pgpm._text_time_to_ts(id, 'c', 12, 36, 'ms') > now() - interval '30 minutes') $$,
  $$ values (20::bigint, 20::bigint) $$,
  'LIVENESS: the twenty other rows of each table decode to the last half hour');

-- 3-5: the report, not a raise: 21 sampled, the twenty plausible, the undecodable maximum null
select is(pg_temp._attempt($$ select * from pgpm.check_text_time('public.tt302s', 'id', 'c', 9, 36, 's') $$),
  'completed', 'check_text_time reports on a sample holding a shaped value past the decode''s range (s)');
select results_eq(
  $$ select sampled, plausible, fraction, newest_decoded, newest_in_future
       from pgpm.check_text_time('public.tt302s', 'id', 'c', 9, 36, 's') $$,
  $$ values (21::bigint, 20::bigint, 0.9524::numeric, null::timestamptz, null::boolean) $$,
  'unit s: the undecodable row counts implausible, the twenty plausible, and that maximum reports null');
select results_eq(
  $$ select sampled, plausible, fraction, newest_decoded, newest_in_future
       from pgpm.check_text_time('public.tt302m', 'id', 'c', 12, 36, 'ms') $$,
  $$ values (21::bigint, 20::bigint, 0.9524::numeric, null::timestamptz, null::boolean) $$,
  'unit ms: the same, twelve digits of milliseconds');

-- 6: the control, a maximum far ahead but decodable, is still reported as that instant
select results_eq(
  $$ select sampled, plausible, newest_decoded, newest_in_future
       from pgpm.check_text_time('public.tt302f', 'id', 'c', 9, 36, 's') $$,
  $$ values (21::bigint, 20::bigint, timestamptz '3000-01-01 00:00:00+00', true) $$,
  'a decodable maximum in the year 3000 is reported as that instant, in the future, not null');

-- 7: and the sample's maximum rows are the ones named: the undecodable row is the column's maximum in both
select results_eq(
  $$ select (select max(id) from public.tt302s) collate "default", (select max(id) from public.tt302m) collate "default" $$,
  $$ values ('czzzzzzzzzabc'::text, 'czzzzzzzzzzzzabc'::text) $$,
  'LIVENESS: the undecodable row is the column''s maximum in both tables, so the maximum path met it');

-- 8-10: each limit on its own. 9223400000000 s overflows an interval (2^63 - 1 us is 9223372036854.775807 s),
-- but from 1900 it names an instant inside the timestamptz range; 9223000000000 s fits an interval, but from
-- 2014-05-13 it names one past 294277-01-01, and from 1970 one before it.
create table public.tt302i (id text collate "C" primary key);
insert into public.tt302i values ('c' || pgpm._radix_encode(9223400000000, 36, 9) || 'i');
create table public.tt302e (id text collate "C" primary key);
insert into public.tt302e values ('c' || pgpm._radix_encode(9223000000000, 36, 9) || 'e');
select results_eq(
  $$ select pg_temp._attempt($q$ select pgpm._text_time_to_ts((select id from public.tt302i), 'c', 9, 36, 's', null, 0,
                                                              timestamptz '1900-01-01 00:00:00+00') $q$),
            pg_temp._attempt($q$ select pgpm._text_time_to_ts((select id from public.tt302e), 'c', 9, 36, 's', null, 0,
                                                              timestamptz '2014-05-13 16:53:20+00') $q$) $$,
  $$ values ('22008 interval out of range', '22008 timestamp out of range') $$,
  'LIVENESS: the plain decode overflows the interval on one and the timestamptz range on the other');
select results_eq(
  $$ select i.sampled, i.plausible, i.newest_decoded, e.sampled, e.plausible, e.newest_decoded
       from pgpm.check_text_time('public.tt302i', 'id', 'c', 9, 36, 's', 1000, null, 0,
                                 timestamptz '1900-01-01 00:00:00+00') i,
            pgpm.check_text_time('public.tt302e', 'id', 'c', 9, 36, 's', 1000, null, 0,
                                 timestamptz '2014-05-13 16:53:20+00') e $$,
  $$ values (1::bigint, 0::bigint, null::timestamptz, 1::bigint, 0::bigint, null::timestamptz) $$,
  'each is reported, one row sampled, none plausible, its maximum null');
select results_eq(
  $$ select sampled, plausible, newest_decoded, newest_in_future
       from pgpm.check_text_time('public.tt302e', 'id', 'c', 9, 36, 's') $$,
  $$ values (1::bigint, 0::bigint, timestamptz '1970-01-01 00:00:00+00' + interval '9223000000000 seconds', true) $$,
  'the second count from the Unix epoch is an instant short of the range edge, and is reported as that instant');

-- ============================== (B) a supplied alphabet still needs radix 2 ==============================
create table public.tt302r (id text collate "C" primary key);
insert into public.tt302r select 'c' || repeat('x', 8) || lpad(i::text, 4, '0') from generate_series(1, 5) i;
create table public.tt302t (id text collate "C" primary key);
insert into public.tt302t
  select pgpm._ts_to_text_time(now() - g * interval '1 day', 'b', 42, 2, 'ms', 'ab') || 'zz'
    from generate_series(1, 3) g;

-- 11: LIVENESS: transmute refuses this exact shape (#990), the refusal check_text_time is to agree with
select throws_like(
  $$ call pgpm.transmute('public.tt302r', 'id', interval '1 month', p_tt_prefix => 'c', p_tt_width => 8,
       p_tt_radix => 1, p_tt_unit => 'ms', p_tt_alphabet => 'x', p_force_text_time => true) $$,
  'pg_partition_magician: p_tt_radix must be at least 2 (got 1)%',
  'LIVENESS: transmute refuses p_tt_radix 1 with a one-character alphabet');

-- 12-13: check_text_time refuses it, and radix 0 with an empty alphabet, with the same rule
select throws_ok(
  $$ select * from pgpm.check_text_time('public.tt302r', 'id', 'c', 8, 1, 'ms', 1000, 'x') $$,
  'P0001',
  'pg_partition_magician: p_radix must be at least 2 (got 1) -- a base-1 encoding has no place value to order bounds by; supply an alphabet of two or more characters, one per digit',
  'check_text_time refuses p_radix 1 with a one-character alphabet');
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt302r', 'id', 'c', 8, 0, 'ms', 1000, '') $$,
  'pg_partition_magician: p_radix must be at least 2 (got 0)%',
  'check_text_time refuses p_radix 0 with an empty alphabet');

-- 14: the default alphabet keeps its own 2-36 message
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt302r', 'id', 'c', 8, 1, 'ms') $$,
  'pg_partition_magician: radix 1 is out of range for the default 0-9a-z alphabet%',
  'check_text_time still refuses radix 1 without an alphabet with the default alphabet''s message');

-- 15-16: the control, radix 2 with 'ab', is accepted: the floor is 2, not "no supplied alphabet"
select results_eq(
  $$ select sampled, plausible from pgpm.check_text_time('public.tt302t', 'id', 'b', 42, 2, 'ms', 1000, 'ab') $$,
  $$ values (3::bigint, 3::bigint) $$,
  'check_text_time samples a supplied radix-2 alphabet: three rows, three plausible');
select results_eq(
  $$ select (select c.relkind::text from pg_class c where c.oid = 'public.tt302r'::regclass),
            (select count(*) from pgpm.config where parent_table = 'public.tt302r'::regclass)::int,
            (select string_agg(id, ',' order by id) from public.tt302r) collate "default" $$,
  $$ values ('r', 0, 'cxxxxxxxx0001,cxxxxxxxx0002,cxxxxxxxx0003,cxxxxxxxx0004,cxxxxxxxx0005') $$,
  'the refused calls left public.tt302r a plain, unmanaged table with its five rows');

-- ================ (C) the width, the discard bits and the unit, refused before a row is read ================
create table public.tt302u (id text collate "C" primary key);
insert into public.tt302u values ('czzzzzzzzzabc'), ('czzzzzzzzyabd');
create table public.tt302z (id text collate "C" primary key);
create table public.tt302h (id text collate "C" primary key, note text);
insert into public.tt302h
  select 'c' || pgpm._radix_encode(floor(extract(epoch from now() - g * interval '1 hour') * 1000 / 2), 36, 8) || 'r' || g,
         g || ' hours ago'
    from generate_series(1, 3) g;

-- 17-18: LIVENESS. Both rows of tt302u have the shape and overflow (the bounded decode swallows each under 's',
-- so it would swallow them under any unit it read as seconds), and transmute refuses unit 'h' on that table.
select results_eq(
  $$ select bool_and(pgpm._text_time_shaped(id, 'c', 9, 36)),
            bool_and(pgpm._text_time_to_ts_bounded(id, 'c', 9, 36, 's') is null) from public.tt302u $$,
  $$ values (true, true) $$,
  'LIVENESS: both rows of tt302u have the declared shape and decode past the range (the bounded decode nulls them)');
select throws_like(
  $$ call pgpm.transmute('public.tt302u', 'id', interval '1 month', p_tt_prefix => 'c', p_tt_width => 9,
       p_tt_radix => 36, p_tt_unit => 'h') $$,
  'pg_partition_magician: p_tt_unit must be ''ms'' or ''s'' (got h)%',
  'LIVENESS: transmute refuses unit h on tt302u');

-- 19-21: the unit, on the overflowing column and on an empty one (whose control reports under 's')
select throws_ok(
  $$ select * from pgpm.check_text_time('public.tt302u', 'id', 'c', 9, 36, 'h') $$,
  'P0001', 'pg_partition_magician: unknown text_time unit h (expected ms or s)',
  'check_text_time refuses unit h on a column whose shaped values all overflow');
select results_eq(
  $$ select sampled, plausible, newest_decoded from pgpm.check_text_time('public.tt302z', 'id', 'c', 9, 36, 's') $$,
  $$ values (0::bigint, 0::bigint, null::timestamptz) $$,
  'LIVENESS: the empty tt302z reports under unit s: nothing sampled');
select throws_ok(
  $$ select * from pgpm.check_text_time('public.tt302z', 'id', 'c', 9, 36, 'h') $$,
  'P0001', 'pg_partition_magician: unknown text_time unit h (expected ms or s)',
  'check_text_time refuses unit h on an empty column, where no decode would ever see it');

-- 22-23: the width
select throws_like(
  $$ call pgpm.transmute('public.tt302u', 'id', interval '1 month', p_tt_prefix => 'c', p_tt_width => 0,
       p_tt_radix => 36, p_tt_unit => 's') $$,
  'pg_partition_magician: p_tt_width must be positive (got 0)%',
  'LIVENESS: transmute refuses p_tt_width 0');
select throws_ok(
  $$ select * from pgpm.check_text_time('public.tt302h', 'id', 'c', 0, 36, 'ms') $$,
  'P0001', 'pg_partition_magician: p_width must be positive (got 0)',
  'check_text_time refuses p_width 0, as transmute does');

-- 24-26: the discard bits. Under -1 every row of tt302h decodes to the hour it was minted for, so the column
-- would read 100% plausible on a shape transmute refuses.
select results_eq(
  $$ select note from public.tt302h
      where pgpm._text_time_shaped(id, 'c', 8, 36)
        and pgpm._text_time_to_ts(id, 'c', 8, 36, 'ms', null, -1) between now() - interval '3 hours 5 minutes' and now()
      order by note $$,
  $$ values ('1 hours ago'), ('2 hours ago'), ('3 hours ago') $$,
  'LIVENESS: every row of tt302h has the shape and decodes, under discard bits -1, to the last three hours');
select throws_like(
  $$ call pgpm.transmute('public.tt302h', 'id', interval '1 month', p_tt_prefix => 'c', p_tt_width => 8,
       p_tt_radix => 36, p_tt_unit => 'ms', p_tt_discard_bits => -1) $$,
  'pg_partition_magician: p_tt_discard_bits must not be negative (got -1)%',
  'LIVENESS: transmute refuses p_tt_discard_bits -1');
select throws_ok(
  $$ select * from pgpm.check_text_time('public.tt302h', 'id', 'c', 8, 36, 'ms', 1000, null, -1) $$,
  'P0001', 'pg_partition_magician: p_discard_bits must not be negative (got -1)',
  'check_text_time refuses p_discard_bits -1, as transmute does');

select * from finish();
