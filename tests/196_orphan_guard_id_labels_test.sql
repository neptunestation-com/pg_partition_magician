-- transmute's orphan guard and restore_incoming_fks's in-flight gate recognise EVERY name _id_label can
-- give a fine child (issue #726).
--
-- Both decide whether a standalone relation named <rel>_p<suffix> is a child of this parent's grid, and
-- both matched an id grid's suffix with '^[0-9]{19}$', the label before #582. _id_label now leaves a value
-- at or past 10^19 whole (20 or more digits), appends `_<frac>` to a fractional one, and pads a short
-- negative one around its sign (lpad('-10', 19, '0')). An orphan an interrupted regrain left under such a
-- name passed the guard: the conversion completed, obtain found the forward cell's name held by a
-- relation it does not own and left the cell unbuilt (nothing logged), and every write into it was
-- refused. The same orphan let restore_incoming_fks re-add a suspended FK while a child was still out of
-- the parent. The fix: one helper, pgpm._is_fine_child_label, that both sites call, and that recognises
-- an id suffix by the round trip through _id_label itself, so the two cannot drift from the label again.
--
-- Every orphan here is NAMED by pgpm._part_name, so the fixture is the label function's own output, and
-- the first assertion is the witness that none of those names is 19 digits (each one really is a case
-- the old pattern missed). Each refusal is paired with its liveness: the guard's 20-digit refusal with a
-- conversion that, once the orphan is gone, builds that very cell and routes a write into it; the gate's
-- two zeros with the 1 it returns, re-adding that very FK, once the orphans are gone.
-- bench/orphan_guard_id_labels.sh runs this file against the mutants orphan_guard_id_label_19_digits and
-- fk_gate_id_label_19_digits, so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(15);

-- ============================ the labels, and the witness that the old pattern misses each ============================
select is(
  array[pgpm._part_name('t196a', 'id', '1000000000000000000', '10000000000000000000', null, 'UTC')::text,
        pgpm._part_name('t196b', 'id', '0.5', '1.5', null, 'UTC')::text,
        pgpm._part_name('t196c', 'id', '10', '-10', null, 'UTC')::text],
  array['t196a_p10000000000000000000', 't196b_p0000000000000000001_5', 't196c_p0000000000000000-10'],
  'fixture: _part_name labels the cell at 10^19 whole, 1.5 with its fraction, and -10 padded around its sign');
select is(
  array['10000000000000000000' ~ '^[0-9]{19}$', '0000000000000000001_5' ~ '^[0-9]{19}$',
        '0000000000000000-10' ~ '^[0-9]{19}$'],
  array[false, false, false],
  'witness: none of the three labels has the pre-#582 shape, so each is a name the old guard let through');

-- ============================ transmute's orphan guard ============================
create table public.t196a (id numeric primary key, v text);
insert into public.t196a values (9500000000000000000, 'x'), (9600000000000000000, 'y');
create table public.t196b (id numeric primary key, v text);
insert into public.t196b values (1.25, 'x'), (2.75, 'y'), (3, 'z');
create table public.t196c (id bigint primary key, v text);
insert into public.t196c values (-7, 'x'), (4, 'y');
-- the orphans an interrupted regrain of an earlier incarnation of each table left behind
create table public.t196a_p10000000000000000000 (like public.t196a);
create table public.t196b_p0000000000000000001_5 (like public.t196b);
create table public."t196c_p0000000000000000-10" (like public.t196c);

select throws_like(
  $$ call pgpm.transmute('public.t196a', 'id', 1000000000000000000::bigint, p_obtain => 2) $$,
  '%t196a_p10000000000000000000 already exists as a standalone table%',
  'transmute refuses an orphan whose label is 20 digits (a cell at 10^19)');
select throws_like(
  $$ call pgpm.transmute('public.t196b', 'id', 1, p_obtain => 2) $$,
  '%t196b_p0000000000000000001_5 already exists as a standalone table%',
  'transmute refuses an orphan whose label carries a fraction (a regrain toward 0.5)');
select throws_like(
  $$ call pgpm.transmute('public.t196c', 'id', 10, p_obtain => 2) $$,
  '%t196c_p0000000000000000-10 already exists as a standalone table%',
  'transmute refuses an orphan whose label is a padded negative value');
select is(
  (select array_agg(relkind::text order by relname) from pg_class
    where oid in ('public.t196a'::regclass, 'public.t196b'::regclass, 'public.t196c'::regclass)),
  array['r', 'r', 'r'],
  'the refusals converted nothing: all three are still plain tables');

-- liveness of the 20-digit refusal: without the orphan the same conversion builds the cell it was holding
drop table public.t196a_p10000000000000000000;
call pgpm.transmute('public.t196a', 'id', 1000000000000000000::bigint, p_obtain => 2);
insert into public.t196a values (10500000000000000000, 'past 10^19');
select is(
  (select tableoid::regclass::text from public.t196a where id = 10500000000000000000),
  't196a_p10000000000000000000',
  'liveness: with the orphan gone, obtain builds the cell [10^19, 1.1*10^19) under that name and a write lands in it');

-- no false positive: a sibling whose suffix is digits but NOT a label _id_label can produce (a trailing
-- zero in the fraction, a 21-character zero-padded integer) can never collide with a cell, so it is left alone
create table public.t196e (id numeric primary key, v text);
insert into public.t196e values (1, 'x'), (2, 'y');
create table public.t196e_p0000000000000000001_50 (note text);
create table public.t196e_p000000000000000000001 (note text);
call pgpm.transmute('public.t196e', 'id', 1, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.t196e'::regclass), 'p',
  'siblings shaped like digits but not like any label do not trip the guard: the conversion ran');
select is(
  (select array_agg(c.relname::text order by c.relname collate "C") from pg_class c
    where c.relname in ('t196e_p0000000000000000001_50', 't196e_p000000000000000000001')
      and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)),
  array['t196e_p000000000000000000001', 't196e_p0000000000000000001_50'],
  'and both siblings are still there, standalone and untouched');

-- ============================ restore_incoming_fks's in-flight gate ============================
create table public.t196g (id numeric primary key, v text);
insert into public.t196g values (9500000000000000000, 'a'), (9600000000000000000, 'b');
create table public.r196g (id int primary key, g_id numeric references public.t196g (id));
insert into public.r196g values (1, 9500000000000000000);
call pgpm.transmute('public.t196g', 'id', 1000000000000000000::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
select is(
  (select array_agg(referencing_table::text) from pgpm.dropped_fk
    where parent_table = 'public.t196g'::regclass and restored_at is null),
  array['r196g'],
  'precondition: r196g''s FK is suspended and not yet restored');

-- an orphan at 5*10^19 (past obtain's lookahead, so the name is free) is a child still out of the parent
do $$ begin
  execute format('create table public.%I (like public.t196g)',
                 pgpm._part_name('t196g', 'id', '1000000000000000000', '50000000000000000000', null, 'UTC'));
end $$;
select is(pgpm.restore_incoming_fks('public.t196g'), 0,
  'the gate holds the FK off while a 20-digit-labelled orphan is out of the parent');
select is((select count(*)::int from pg_constraint where conrelid = 'public.r196g'::regclass and contype = 'f'
                                    and conparentid = 0), 0,
  'and r196g has no FK yet');
drop table public.t196g_p50000000000000000000;
do $$ begin
  execute format('create table public.%I (like public.t196g)',
                 pgpm._part_name('t196g', 'id', '0.5', '9500000000000000000.5', null, 'UTC'));
end $$;
select is(pgpm.restore_incoming_fks('public.t196g'), 0,
  'the gate holds the FK off while a fraction-labelled orphan (t196g_p9500000000000000000_5) is out of the parent');
drop table public.t196g_p9500000000000000000_5;
select is(pgpm.restore_incoming_fks('public.t196g'), 1,
  'liveness: with no orphan the same call re-adds the FK');
select is(
  (select array_agg(confrelid::regclass::text) from pg_constraint
    where conrelid = 'public.r196g'::regclass and contype = 'f' and conparentid = 0),
  array['t196g'],
  'and the FK re-added is r196g''s, against t196g');

select * from finish();
