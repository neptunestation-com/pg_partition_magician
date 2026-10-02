-- transmute's orphan guard (both halves) and restore_incoming_fks's in-flight gate recognise a time-grid
-- fine child's label in a BC year and in a five-digit year (issue #769, its label bullet: pass-6 F2-04,
-- pass-7 F2-02).
--
-- All three sites ask pgpm._is_fine_child_label whether a standalone relation's suffix (its name with
-- "<rel>_p" cut off) is the label of one of this parent's fine children (#726, #794). The time branch
-- matched '^[0-9]{4}(_[0-9]+)*$', but _part_name marks a BC year with a `_bc` suffix (#710) and to_char's
-- YYYY prints a year past 9999 in five digits or more (a uuidv7 grid reaches 10889). So an orphan table
-- or a domain under such a child's name passed the guard and the conversion went ahead, where the
-- reference promises refusal for any name pgpm could give a fine child, and the gate re-added a suspended
-- FK while such a child was still out of the parent. The fix widens that one pattern: a four-digit year,
-- or five or more digits without a leading zero, then the groups, then an optional `_bc`.
--
-- Every name here is _part_name's own output (the first assertion is the witness, the second that the
-- old pattern misses each). Each refusal is paired with a control that already refused (an AD orphan)
-- and with liveness (the same conversion runs once the holder is gone); the gate's zeros are paired with
-- the 1 it returns, re-adding that very FK, once the orphans are gone. The false-positive side is pinned
-- too: suffixes that are not a label (`_to_` forms, a padded five-digit year) are not recognised.
-- bench/fine_child_label_bc_wide_year.sh runs this file against the mutant fine_child_label_time_four_digit
-- (the pre-fix pattern), so it is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(20);

-- ============================ the labels, and the witness that the old pattern misses each ============================
create temp table l234 as
  select * from (values
    ('1 year',          '0100-01-01 00:00:00+00 BC',        '0100_bc'),
    ('1 mon',           '0100-06-01 00:00:00+00 BC',        '0100_06_bc'),
    ('1 day',           '0100-06-15 00:00:00+00 BC',        '0100_06_15_bc'),
    ('1 hour',          '0100-06-15 07:00:00+00 BC',        '0100_06_15_07_bc'),
    ('1 minute',        '0100-06-15 07:30:00+00 BC',        '0100_06_15_0730_bc'),
    ('1 second',        '0100-06-15 07:30:15+00 BC',        '0100_06_15_073015_bc'),
    ('0.5 seconds',     '0100-06-15 07:30:15.5+00 BC',      '0100_06_15_073015_500000_bc'),
    ('1 year',          '10001-01-01 00:00:00+00',          '10001'),
    ('1 mon',           '10001-03-01 00:00:00+00',          '10001_03'),
    ('1 day',           '10889-12-31 00:00:00+00',          '10889_12_31'),
    ('1 minute',        '123456-02-03 04:05:00+00',         '123456_02_03_0405')
  ) v(step, lo, label);
select is(
  (select array_agg(pgpm._part_name('t234', 'time', step, lo, null, 'UTC')::text order by label) from l234),
  (select array_agg('t234_p' || label order by label) from l234),
  'fixture: each label is the one _part_name gives that cell (seven BC granularities, four years past 9999)');
select is((select array_agg(label order by label) from l234 where label ~ '^[0-9]{4}(_[0-9]+)*$'), null,
  'witness: none of the eleven labels has the pre-fix shape, so each is a name the old guard let through');
select is((select array_agg(label order by label) from l234 where not pgpm._is_fine_child_label('time', label)), null,
  'the helper recognises every one of them as a fine child''s label');
select ok(pgpm._is_fine_child_label('uuidv7', '10889_12') and pgpm._is_fine_child_label('text_time', '0100_06_bc'),
  'and does so for the other time-like kinds, which share the branch');
select ok(pgpm._is_fine_child_label('time', '2020_01') and pgpm._is_fine_child_label('time', '2020_01_01_05'),
  'LIVENESS: AD four-digit labels are recognised as before');
select is(
  (select array_agg(s order by s) from unnest(array['0100_bc_to_0099_bc', '2020_01_to_2020_03', '01000_03', 'bc',
                                                     '0100bc', '100_06', '0100_06_bc_x']) s
    where pgpm._is_fine_child_label('time', s)),
  null,
  'no false positive: coarse `_to_` names, a zero-padded five-digit year, a bare or glued bc, a short year');

-- ============================ transmute's orphan guard, pg_class half ============================
create table public.ad234 (id bigint not null, at timestamptz not null, primary key (id, at));
insert into public.ad234 values (1, '0100-06-15 00:00:00+00'), (2, now() - interval '1 day');
create table public.ad234_p0100_06 (like public.ad234);
select throws_like(
  $$ call pgpm.transmute('public.ad234', 'at', interval '1 month', p_obtain => 1) $$,
  '%ad234_p0100_06 already exists as a standalone table%',
  'LIVENESS: transmute refuses an orphan under an AD monthly child''s name (the guard exists and fires)');
create table public.bc234 (id bigint not null, at timestamptz not null, primary key (id, at));
insert into public.bc234 values (1, '0100-06-15 00:00:00+00 BC'), (2, '0100-08-15 00:00:00+00 BC'), (3, now() - interval '1 day');
create table public.bc234_p0100_06_bc (like public.bc234);
insert into public.bc234_p0100_06_bc values (1, '0100-06-15 00:00:00+00 BC');
select throws_like(
  $$ call pgpm.transmute('public.bc234', 'at', interval '1 month', p_obtain => 1) $$,
  '%bc234_p0100_06_bc already exists as a standalone table%',
  'transmute refuses an orphan under a BC monthly child''s name (bc234_p0100_06_bc)');
select is((select relkind::text from pg_class where oid = 'public.bc234'::regclass), 'r',
  'the refusal converted nothing: bc234 is still a plain table');
drop table public.bc234_p0100_06_bc;
call pgpm.transmute('public.bc234', 'at', interval '1 month', p_obtain => 1);
select is((select relkind::text from pg_class where oid = 'public.bc234'::regclass), 'p',
  'LIVENESS: with the orphan gone the same conversion runs');
select is((select array_agg(id order by id) from public.bc234), array[1, 2, 3]::bigint[],
  'and bc234 holds rows 1, 2 and 3');

-- ============================ transmute's orphan guard, pg_type half ============================
create table public.wd234 (id bigint not null, at timestamptz not null, primary key (id, at));
insert into public.wd234 values (1, '0100-06-15 00:00:00+00 BC'), (2, now() - interval '1 day');
create domain public.wd234_p10001_03 as int;
select throws_like(
  $$ call pgpm.transmute('public.wd234', 'at', interval '1 month', p_obtain => 1) $$,
  '%wd234_p10001_03 already exists as a domain matching this parent''s partition naming%',
  'transmute refuses a domain under a five-digit-year monthly child''s name (wd234_p10001_03)');
drop domain public.wd234_p10001_03;
create domain public.wd234_p0100_06_bc as int;
select throws_like(
  $$ call pgpm.transmute('public.wd234', 'at', interval '1 month', p_obtain => 1) $$,
  '%wd234_p0100_06_bc already exists as a domain matching this parent''s partition naming%',
  'transmute refuses a domain under a BC monthly child''s name (wd234_p0100_06_bc)');
drop domain public.wd234_p0100_06_bc;
call pgpm.transmute('public.wd234', 'at', interval '1 month', p_obtain => 1);
select is((select relkind::text from pg_class where oid = 'public.wd234'::regclass), 'p',
  'LIVENESS: with both domains gone the same conversion runs');

-- ============================ restore_incoming_fks's in-flight gate ============================
create table public.g234 (id bigint not null, at timestamptz not null, primary key (id, at));
insert into public.g234 values (1, '0100-06-15 00:00:00+00 BC'), (2, now() - interval '1 day');
create table public.r234 (id int primary key, g_id bigint, g_at timestamptz,
                          foreign key (g_id, g_at) references public.g234 (id, at));
insert into public.r234 select 1, id, at from public.g234 where id = 2;
call pgpm.transmute('public.g234', 'at', interval '1 month', p_obtain => 1, p_incoming_fks => 'preserve');
select is(
  (select array_agg(referencing_table::text) from pgpm.dropped_fk
    where parent_table = 'public.g234'::regclass and restored_at is null),
  array['r234'],
  'precondition: r234''s FK is suspended and not yet restored');
create table public.g234_p0100_06_bc (like public.g234);
select is(pgpm.restore_incoming_fks('public.g234'), 0,
  'the gate holds the FK off while a BC-labelled orphan (g234_p0100_06_bc) is out of the parent');
drop table public.g234_p0100_06_bc;
-- the next zero means "held" only while the FK is still suspended, so say so first: a gate that let the
-- BC orphan through restored it above, and a zero below would then be a gate with nothing left to do
select is(
  (select array_agg(referencing_table::text) from pgpm.dropped_fk
    where parent_table = 'public.g234'::regclass and restored_at is null),
  array['r234'],
  'precondition: r234''s FK is still suspended after the BC orphan''s call');
create table public.g234_p10001_03 (like public.g234);
select is(pgpm.restore_incoming_fks('public.g234'), 0,
  'the gate holds the FK off while a five-digit-year orphan (g234_p10001_03) is out of the parent');
drop table public.g234_p10001_03;
select is(pgpm.restore_incoming_fks('public.g234'), 1,
  'LIVENESS: with no orphan the same call re-adds the FK');
select is(
  (select array_agg(confrelid::regclass::text) from pg_constraint
    where conrelid = 'public.r234'::regclass and contype = 'f' and conparentid = 0),
  array['g234'],
  'and the FK re-added is r234''s, against g234');

select * from finish();
