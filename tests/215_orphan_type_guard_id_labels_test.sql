-- transmute's pg_type orphan check recognises EVERY name _id_label can give a fine child (issue #794).
--
-- transmute refuses a type (an enum, a domain, a range type) named like one of the parent's children
-- (#707), because a partition's CREATE TABLE needs its name free in pg_type too. #726 moved the pg_class
-- half of the orphan guard to pgpm._is_fine_child_label, which recognises an id suffix by the round trip
-- through _id_label, but the pg_type half kept '^[0-9]{19}$', the label before #582. A type holding a
-- 20-digit label (a cell at or past 10^19), a fractional one (`_<frac>`) or a short negative one
-- (zeros before the sign) therefore passed: the conversion completed, and obtain left that cell unbuilt
-- (fail_obtain_name), so every write into it was refused. The fix: the pg_type half asks the same helper.
--
-- Every type here is NAMED by pgpm._part_name, and the first two assertions are the witnesses that each
-- name is the label function's own output and that none of them has the old 19-digit shape. The three
-- refusals are paired with liveness: a 19-digit control the old check already refused (so the guard
-- exists and fires), and, once the 20-digit type is gone, the same conversion building that very cell
-- and routing a write into it. The false-positive side is pinned too: types whose suffix is digits but
-- not a label _id_label can produce leave the conversion alone, and are still there after it.
-- bench/orphan_type_guard_id_labels.sh runs this file against the mutant orphan_type_guard_id_label_19_digits
-- (the pre-fix pattern), so it is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(11);

-- ============================ the labels, and the witness that the old pattern misses each ============================
select is(
  array[pgpm._part_name('t215a', 'id', '1000000000000000000', '10000000000000000000', null, 'UTC')::text,
        pgpm._part_name('t215b', 'id', '0.5', '1.5', null, 'UTC')::text,
        pgpm._part_name('t215c', 'id', '10', '-10', null, 'UTC')::text,
        pgpm._part_name('t215d', 'id', '10000', '1030000', null, 'UTC')::text],
  array['t215a_p10000000000000000000', 't215b_p0000000000000000001_5', 't215c_p0000000000000000-10',
        't215d_p0000000000001030000'],
  'fixture: _part_name labels 10^19 whole, 1.5 with its fraction, -10 padded around its sign, 1030000 in 19 digits');
select is(
  array['10000000000000000000' ~ '^[0-9]{19}$', '0000000000000000001_5' ~ '^[0-9]{19}$',
        '0000000000000000-10' ~ '^[0-9]{19}$', '0000000000001030000' ~ '^[0-9]{19}$'],
  array[false, false, false, true],
  'LIVENESS: the first three labels lack the pre-#582 shape, so each is a name the old check let through; the control has it');

create table public.t215a (id numeric primary key, v text);
insert into public.t215a values (9500000000000000000, 'x'), (9600000000000000000, 'y');
create table public.t215b (id numeric primary key, v text);
insert into public.t215b values (1.25, 'x'), (2.75, 'y'), (3, 'z');
create table public.t215c (id bigint primary key, v text);
insert into public.t215c values (-7, 'x'), (4, 'y');
create table public.t215d (id bigint primary key, v text);
insert into public.t215d values (1000005, 'x'), (1012345, 'y');
-- one type of a different kind per table, each under a fine child's name
create domain public.t215a_p10000000000000000000 as int;
create type public.t215b_p0000000000000000001_5 as enum ('x');
create type public."t215c_p0000000000000000-10" as range (subtype = int4);
create domain public.t215d_p0000000000001030000 as int;

select throws_like(
  $$ call pgpm.transmute('public.t215d', 'id', 10000::bigint, p_obtain => 2) $$,
  '%t215d_p0000000000001030000 already exists as a domain matching this parent''s partition naming%',
  'control: transmute refuses a domain under a 19-digit forward cell''s name (the check exists and fires)');
select throws_like(
  $$ call pgpm.transmute('public.t215a', 'id', 1000000000000000000::bigint, p_obtain => 2) $$,
  '%t215a_p10000000000000000000 already exists as a domain matching this parent''s partition naming%',
  'transmute refuses a domain under a 20-digit cell''s name (a cell at 10^19)');
select throws_like(
  $$ call pgpm.transmute('public.t215b', 'id', 1, p_obtain => 2) $$,
  '%t215b_p0000000000000000001_5 already exists as an enum type matching this parent''s partition naming%',
  'transmute refuses an enum under a fraction-labelled cell''s name');
select throws_like(
  $$ call pgpm.transmute('public.t215c', 'id', 10, p_obtain => 2) $$,
  '%t215c_p0000000000000000-10 already exists as a range type matching this parent''s partition naming%',
  'transmute refuses a range type under a short negative cell''s name');
select is(
  (select array_agg(c.relname::text || ':' || c.relkind::text || ':' || (cf.parent_table is not null)::text
                    order by c.relname)
     from pg_class c left join pgpm.config cf on cf.parent_table = c.oid
    where c.oid in ('public.t215a'::regclass, 'public.t215b'::regclass, 'public.t215c'::regclass,
                    'public.t215d'::regclass)),
  array['t215a:r:false', 't215b:r:false', 't215c:r:false', 't215d:r:false'],
  'the refusals converted nothing: all four are still plain tables with no pgpm.config row');

-- liveness of the 20-digit refusal: without the domain the same conversion builds the cell it was holding
drop domain public.t215a_p10000000000000000000;
call pgpm.transmute('public.t215a', 'id', 1000000000000000000::bigint, p_obtain => 2);
insert into public.t215a values (10500000000000000000, 'past 10^19');
select is(
  (select tableoid::regclass::text from public.t215a where id = 10500000000000000000),
  't215a_p10000000000000000000',
  'LIVENESS: with the domain gone, obtain builds the cell [10^19, 1.1*10^19) under that name and a write lands in it');
select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.t215a'::regclass and action = 'fail_obtain_name'),
  0,
  'and no cell of t215a was left unbuilt');

-- no false positive: types whose suffix is digits but NOT a label _id_label can produce (a trailing zero
-- in the fraction, a 21-character zero-padded integer) can never collide with a cell, so they are left alone
create table public.t215e (id numeric primary key, v text);
insert into public.t215e values (1, 'x'), (2, 'y');
create domain public.t215e_p0000000000000000001_50 as int;
create type public.t215e_p000000000000000000001 as enum ('x');
call pgpm.transmute('public.t215e', 'id', 1, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.t215e'::regclass), 'p',
  'types shaped like digits but not like any label do not trip the check: the conversion ran');
select is(
  (select array_agg(t.typname::text order by t.typname collate "C") from pg_type t
    where t.typnamespace = 'public'::regnamespace
      and t.typname in ('t215e_p0000000000000000001_50', 't215e_p000000000000000000001')),
  array['t215e_p000000000000000000001', 't215e_p0000000000000000001_50'],
  'and both types are still there, untouched');

select * from finish();
