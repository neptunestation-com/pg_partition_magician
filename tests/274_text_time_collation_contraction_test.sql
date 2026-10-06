-- A collation with a two-character CONTRACTION does not order text_time digit strings by place value,
-- and _check_text_time_collation used to accept it (issue #639, bullet 2; F2-01 in pass 9). Under
-- da-x-icu 'aa' is one letter, a-ring, which sorts after 'z', so the hex string '69aa0000' sorts after
-- '69cc6000' although its place value is below it; under cs-x-icu 'ch' is one letter sorting after
-- 'h', so Crockford's 'CH' sorts after 'CJ'. The check probed adjacent single-character digit pairs at
-- one position, which no contraction disturbs, so transmute accepted a hex (ObjectId-shaped) column
-- collated da-x-icu, and PostgreSQL routed a row whose timestamp field held 'aa' (decoded 28 November)
-- into the December partition, where retain drops it on December's schedule.
--
-- The check is now a proof for the alphabet in use: every one- and two-character string over the
-- alphabet, behind the declared prefix, must sort under the column's collation in place-value order.
-- That catches any two-character contraction at any position (comparing 'aa' with 'ab' is what
-- misorders '69aa0000' against '69ab0000'), a contraction spanning the prefix and the first digit, and
-- a digit the collation ignores. It also stays exact: a collation that orders the alphabet correctly
-- is still accepted, which is why cs-x-icu passes for hex (Czech's one contraction is 'ch', and hex has
-- no 'h') and fails for base32 and Crockford, which have one.
--
-- Every refusal is paired with a witness that the collation really misorders strings of that
-- alphabet, and the da-x-icu fixture is shown to hold a row that sorts outside its own month before the
-- refusal is checked. Every acceptance is a check_text_time that returns its fraction, or a transmute
-- that converts, with the misordered row then asserted, by identity, to sit in the partition whose
-- range holds its decoded time. bench/text_time_collation_proof.sh runs this file against the mutant
-- text_time_collation_probe_only (the pre-fix probes) and requires it to fail there.
create extension if not exists pgtap;
set timezone = 'UTC';
set client_min_messages = warning;

select plan(28);

-- ------------------------------------------------------------------------------------------ witnesses
select ok(
  ('69aa0000' collate "da-x-icu") > ('69cc6000' collate "da-x-icu")
  and ('69aa0000' collate "C") < ('69cc6000' collate "C"),
  'witness: under da-x-icu the hex string 69aa0000 sorts after 69cc6000, against place value'
);
select ok(
  ('01CH0000' collate "cs-x-icu") > ('01CJ0000' collate "cs-x-icu")
  and ('01CH0000' collate "C") < ('01CJ0000' collate "C"),
  'witness: under cs-x-icu the Crockford string 01CH0000 sorts after 01CJ0000, against place value'
);
select ok(
  ('cha' collate "cs-x-icu") > ('cia' collate "cs-x-icu") and ('xha' collate "cs-x-icu") < ('xia' collate "cs-x-icu"),
  'witness: under cs-x-icu a prefix c and a digit h contract, and a prefix x and the same digit do not'
);

-- ObjectId-shaped hex: 8 digits of epoch seconds, then a payload. One row a day for 13 months, plus
-- one row built to sort outside its own month under da-x-icu: a month's upper bound with its digits at
-- positions k, k+1 replaced by 'aa' and zeros after, which is below the bound in place value (the bound
-- has b..f at k) and, by less than a month, still inside the month, while a-ring sorts it above.
create function public.hex_id(p_ts timestamptz, p_payload bigint) returns text language sql immutable as $$
  select lpad(to_hex(floor(extract(epoch from p_ts))::bigint), 8, '0') || lpad(to_hex(p_payload), 16, '0')
$$;
create function public.hex_ts(p_id text) returns timestamptz language sql immutable as $$
  select pgpm._text_time_to_ts(p_id, '', 8, 16, 's', '0123456789abcdef')
$$;
create table public.tt274_rows (id text collate "C" primary key, body text);
insert into public.tt274_rows
select public.hex_id(now() - interval '13 months' + g * interval '1 day', g), 'r' || g
  from generate_series(1, 390) g;
insert into public.tt274_rows
select v, 'contracted'
  from (select rpad(substr(b, 1, k - 1) || 'aa', 8, '0') || '00000000000000ff' as v, m
          from generate_series(2, 12) as mm(n)
          cross join lateral (select date_trunc('month', now()) - mm.n * interval '1 month' as m) mo
          cross join lateral (select lpad(to_hex(floor(extract(epoch from mo.m + interval '1 month'))::bigint), 8, '0') as b) bb
          cross join generate_series(3, 7) as k
         where substr(b, k, 1) in ('b', 'c', 'd', 'e', 'f')) c
 where public.hex_ts(v) >= m
 order by m desc, v
 limit 1;
select is(
  (select count(*) from public.tt274_rows where body = 'contracted'), 1::bigint,
  'witness: the fixture holds the row built with aa in its timestamp field'
);
select ok(
  (select (r.id collate "da-x-icu") >= (public.hex_id(date_trunc('month', public.hex_ts(r.id)) + interval '1 month', 0) collate "da-x-icu")
     from public.tt274_rows r where r.body = 'contracted'),
  'witness: under da-x-icu that row sorts at or above the next month''s bound, outside its own month'
);

-- ------------------------------------------------------------- refusal: hex on da-x-icu (the reproduction)
create table public.tt274_hex_da (id text collate "da-x-icu" primary key, body text);
insert into public.tt274_hex_da select id, body from public.tt274_rows;
select throws_like(
  $$ call pgpm.transmute('public.tt274_hex_da', 'id', interval '1 month', p_obtain => 2,
       p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's', p_tt_alphabet => '0123456789abcdef') $$,
  $p$pg_partition_magician: column %tt274_hex_da.id has collation "da-x-icu"%digit 'a' (value 10)%digit 'b' (value 11)%'aa' does not sort before 'ab'%alter table %tt274_hex_da alter column id type text collate "C"%$p$,
  'transmute refuses a hex column on da-x-icu, naming the collation, the contracted pair and the collate "C" remedy'
);
select is(
  (select relkind::text from pg_class where oid = 'public.tt274_hex_da'::regclass),
  'r', 'the refused table is left untouched (still a plain table)'
);
select is(
  (select count(*) from pgpm.config where parent_table = 'public.tt274_hex_da'::regclass),
  0::bigint, 'the refused table was never registered'
);
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt274_hex_da', 'id', '', 8, 16, 's', 1000, '0123456789abcdef') $$,
  $p$pg_partition_magician: column %tt274_hex_da.id has collation "da-x-icu"%digit 'a' (value 10)%digit 'b' (value 11)%collate "C"%$p$,
  'check_text_time gives the same refusal for hex on da-x-icu'
);
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt274_hex_da', 'id', '', 7, 32, 's', 1000) $$,
  $p$pg_partition_magician: column %tt274_hex_da.id has collation "da-x-icu"%digit 'a' (value 10)%digit 'b' (value 11)%$p$,
  'check_text_time refuses the default base32 alphabet on da-x-icu'
);
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt274_hex_da', 'id', '', 10, 32, 'ms', 1000, '0123456789ABCDEFGHJKMNPQRSTVWXYZ') $$,
  $p$pg_partition_magician: column %tt274_hex_da.id has collation "da-x-icu"%digit 'A' (value 10)%digit 'B' (value 11)%$p$,
  'check_text_time refuses Crockford base32 on da-x-icu'
);

-- ------------------------------------------------------------------------- refusal: base32 on cs-x-icu
create table public.tt274_cs (id text collate "cs-x-icu" primary key, body text);
insert into public.tt274_cs select id, body from public.tt274_rows;
select throws_like(
  $$ call pgpm.transmute('public.tt274_cs', 'id', interval '1 month', p_obtain => 2,
       p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
       p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ', p_force_text_time => true) $$,
  $p$pg_partition_magician: column %tt274_cs.id has collation "cs-x-icu"%digit 'H' (value 17)%digit 'J' (value 18)%'CH' does not sort before 'CJ'%collate "C"%$p$,
  'transmute refuses Crockford base32 on cs-x-icu, p_force_text_time notwithstanding'
);
select is(
  (select relkind::text from pg_class where oid = 'public.tt274_cs'::regclass),
  'r', 'the refused cs-x-icu table is left untouched'
);
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt274_cs', 'id', '', 7, 32, 's', 1000) $$,
  $p$pg_partition_magician: column %tt274_cs.id has collation "cs-x-icu"%digit 'h' (value 17)%digit 'i' (value 18)%$p$,
  'check_text_time refuses the default base32 alphabet on cs-x-icu'
);
-- the contraction spans the prefix and the first digit; the alphabet alone has none
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt274_cs', 'id', 'c', 8, 10, 's', 1000, 'ghijklmnop') $$,
  $p$pg_partition_magician: column %tt274_cs.id has collation "cs-x-icu"%digit 'h' (value 1)%digit 'i' (value 2)%'chp' does not sort before 'ci'%$p$,
  'check_text_time refuses a prefix that contracts with a digit under cs-x-icu'
);
select is(
  (select count(*) from pgpm.check_text_time('public.tt274_cs', 'id', 'x', 8, 10, 's', 1000, 'ghijklmnop')),
  1::bigint, 'the same alphabet behind a prefix that contracts with nothing is accepted on cs-x-icu'
);
-- exact, not merely strict: Czech's one contraction is 'ch', so hex (no 'h') is ordered correctly
select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tt274_cs', 'id', '', 8, 16, 's', 1000, '0123456789abcdef')),
  '>=', 0.95::numeric, 'hex on cs-x-icu is accepted and samples as plausible'
);

-- --------------------------------------------------------- acceptance: bytewise collations and en_US hex
create table public.tt274_posix (id text collate "POSIX" primary key, body text);
insert into public.tt274_posix select id, body from public.tt274_rows;
select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tt274_posix', 'id', '', 8, 16, 's', 1000, '0123456789abcdef')),
  '>=', 0.95::numeric, 'hex on collate "POSIX" is accepted'
);
create table public.tt274_ucs (id text collate ucs_basic primary key, body text);
insert into public.tt274_ucs select id, body from public.tt274_rows;
select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tt274_ucs', 'id', '', 8, 16, 's', 1000, '0123456789abcdef')),
  '>=', 0.95::numeric, 'hex on collate ucs_basic is accepted'
);
create table public.tt274_dflt (id text primary key, body text);
insert into public.tt274_dflt select id, body from public.tt274_rows;
select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tt274_dflt', 'id', '', 8, 16, 's', 1000, '0123456789abcdef')),
  '>=', 0.95::numeric, 'hex on the database default collation (en_US.utf8) is accepted'
);

-- ------------------------------------------- a digit the collation ignores: '-' under glibc's en_US
select ok(
  ('-9' collate "en_US.utf8") > ('0' collate "en_US.utf8") and ('-9' collate "C") < ('0' collate "C"),
  'witness: en_US.utf8 ignores - at the primary level, so -9 sorts after 0 against place value'
);
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt274_dflt', 'id', '', 8, 11, 's', 1000, '-0123456789') $$,
  $p$pg_partition_magician: column %tt274_dflt.id has collation "default" (the database default, en_US.utf8)%digit '-' (value 0)%digit '0' (value 1)%'-9' does not sort before '0'%$p$,
  'check_text_time refuses an alphabet whose digit the default collation ignores'
);
select is(
  (select count(*) from pgpm.check_text_time('public.tt274_posix', 'id', '', 8, 11, 's', 1000, '-0123456789')),
  1::bigint, 'the same alphabet on collate "POSIX" is accepted'
);

-- ------------------------------------------------- acceptance: the same rows on collate "C" convert
call pgpm.transmute('public.tt274_rows', 'id', interval '1 month', p_obtain => 3,
  p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's', p_tt_alphabet => '0123456789abcdef');
select is(
  (select relkind::text from pg_class where oid = 'public.tt274_rows'::regclass),
  'p', 'collate "C": the hex column converts'
);
select is(
  (select array_agg(id order by id collate "C") from public.tt274_rows),
  (select array_agg(id order by id collate "C") from public.tt274_hex_da),
  'collate "C": every id survived the conversion, by identity'
);
select pgpm.resume('public.tt274_rows');
call pgpm.maintain('public.tt274_rows');
-- a fresh contracted row for each fine month ahead, built the same way, then where each one sits
create temporary table _fine as
with p as materialized (
  select child_oid, child_name, lo, hi from pgpm.part
   where parent_table = 'public.tt274_rows'::regclass and attached)
select child_oid, child_name, lo::timestamptz as lo, hi::timestamptz as hi from p where lo::timestamptz > now();
select cmp_ok((select count(*) from _fine), '>=', 2::bigint, 'witness: at least two fine month partitions exist ahead');
insert into public.tt274_rows
select distinct on (f.child_name) rpad(substr(b, 1, k - 1) || 'aa', 8, '0') || '00000000000000fe', 'fresh_' || f.child_name
  from _fine f
  cross join lateral (select lpad(to_hex(floor(extract(epoch from f.hi))::bigint), 8, '0') as b) bb
  cross join generate_series(3, 7) as k
 where substr(b, k, 1) in ('b', 'c', 'd', 'e', 'f')
   and public.hex_ts(rpad(substr(b, 1, k - 1) || 'aa', 8, '0')) >= f.lo
 order by f.child_name, k;
create temporary table _fresh as
select r.body, r.tableoid as actual, (select f.child_oid from _fine f where f.lo <= public.hex_ts(r.id) and public.hex_ts(r.id) < f.hi) as expected
  from public.tt274_rows r where r.body like 'fresh_%';
select ok(
  exists (select 1 from _fresh f join public.tt274_rows r on r.body = f.body
           where (r.id collate "da-x-icu") >= (public.hex_id((select hi from _fine where child_oid = f.expected), 0) collate "da-x-icu")),
  'witness: a fresh row sorts above its own month''s upper bound under da-x-icu'
);
select is(
  (select array_agg(body order by body) from _fresh where actual is distinct from expected),
  null, 'collate "C": every fresh contracted row sits in the partition whose range holds its decoded time'
);

select * from finish();
