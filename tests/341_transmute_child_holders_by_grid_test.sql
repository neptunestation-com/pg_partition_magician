-- Issues #1274 and #1216: transmute's orphan-child guard (_transmute_refuse_child_holders) refuses a holder of a
-- name THIS grid can give one of THIS table's partitions, and only that.
--
-- #1274: the label test was the control KIND's (_is_fine_child_label: any time label, a year's to a
-- microsecond's), so a monthly grid, whose cells are <rel>_pYYYY_MM and whose auto-regrain targets are never
-- coarser than a month (#341), was refused by the operator's own standalone <rel>_p2023 (a hand-made archive),
-- in words that called it a regrain orphan and told the operator to drop it, rows and all. The label must be
-- one the grid can give (_grid_can_label): its step's granularity, or a finer one, or the coarser one a
-- regrain target the step allows reaches (a '1 year' target on an '18 months' grid). And a standalone table
-- that IS in reach is refused with a remedy that renames it rather than dropping it, which this file types.
--
-- #1216: the exemption was "any relation in pg_inherits", so a partition (or inheritance child) of ANOTHER
-- table at a forward cell's name was no holder: obtain stepped over the held name and the conversion completed
-- with that cell unbuilt and every write into it refused. Only a partition of THIS parent is exempt now.
--
-- Fixtures, asymmetric on purpose:
--   (A) t341a, '1 month' grid: a standalone table t341a_p2023 holding ids 7 and 8, and a domain t341a_p2022.
--       Neither label is the grid's. Converts; both are left exactly as they were.
--   (B) t341b, '1 month' grid: a standalone t341b_p2024_03_15, a DAY label a '1 day' regrain of the monolith
--       gives. Refused (a finer label is in reach); the typed remedy (rename) lets it convert.
--   (C) t341c, '1 year' grid: the same shape of holder as (A), t341c_p2023 holding ids 7 and 8, but on a grid
--       whose own label it is. Refused; the typed rename converts it, and the rows are still in the renamed one.
--   (D) t341d, '18 months' grid: a DOMAIN t341d_p2025, a year label, which the '1 year' regrain target the
--       step allows gives. Refused by the type half; renamed, it converts, and set_regrain accepts '1 year'.
--   (G) t341g, '30 days' grid at the default anchor: a standalone t341g_p2023_05, a month label, which
--       set_regrain's '1 month' would reach but refuses there (31 days from the anchor). Converts.
--   (E) t341e, id grid step 1000 (monolith [0, 1000)): a partition of ANOTHER table, f341_other, at the first
--       forward cell's name. Refused naming the table it belongs to; the typed rename converts, the cell
--       [1000, 2000) is built as t341e's partition and takes a write, and the other table's partition stays.
--   (F) t341f, id grid step 1000: an INHERITANCE child of another table at the second forward cell's name.
--       Refused naming it as such.
-- bench/transmute_child_holders_by_grid.sh runs this file against the mutants that drop the grid's label test
-- from the pg_class half (child_holders_any_kind_label), from the pg_type half
-- (child_holder_types_any_kind_label), and narrow the exemption back to any pg_inherits parent
-- (child_holders_any_parent_exempt).
create extension if not exists pgtap;

select plan(34);

set timezone = 'UTC';

-- ---------------------------------------------------------------------------------------------------------
-- (A) a monthly grid is not refused by labels it can never give
create table public.t341a (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.t341a select g, '2024-03-01 00:00+00'::timestamptz + g * interval '1 day' from generate_series(0, 19) g;
create table public.t341a_p2023 (id bigint not null, ts timestamptz not null);
insert into public.t341a_p2023 values (7, '2023-03-01 00:00+00'), (8, '2023-09-01 00:00+00');
create domain public.t341a_p2022 as int;

select is(array[pgpm._part_name('t341a', 'time', '1 mon', pgpm._ts_text('2023-01-01 00:00+00'), null, 'UTC')::text,
                pgpm._part_name('t341a', 'time', '1 day', pgpm._ts_text('2023-01-01 00:00+00'), null, 'UTC')::text],
          array['t341a_p2023_01', 't341a_p2023_01_01'],
          'LIVENESS: (A) the monthly grid''s cell and a finer regrain cell in 2023 take YYYY_MM and longer labels, never t341a_p2023');

\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341a', 'ts', interval '1 month', p_obtain => 2);
\set ON_ERROR_STOP 1

select is((select relkind::text from pg_class where oid = 'public.t341a'::regclass), 'p',
          '(A) t341a is converted on its monthly grid: t341a_p2023 and the domain t341a_p2022 are no names it can give');
-- the monolith reaches up to the present, so its upper label is today's month: read the names' shapes
select is((select array_agg(left(c.relname, 7) || regexp_replace(substr(c.relname, 8), '[0-9]', 'N', 'g') order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'public.t341a'::regclass),
          array['t341a_pNNNN_NN_to_NNNN_NN', 't341a_pNNNN_NN', 't341a_pNNNN_NN'],
          'LIVENESS: (A) the conversion built the monolith and both forward cells, by their monthly names');
select is((select relkind::text || '/' || relispartition::text from pg_class where oid = 'public.t341a_p2023'::regclass),
          'r/false', '(A) the operator''s t341a_p2023 is still a standalone table');
select is((select array_agg(id order by id) from public.t341a_p2023), array[7, 8]::bigint[],
          '(A) and it still holds ids 7 and 8');
select is((select typtype::text from pg_type where typname = 't341a_p2022' and typnamespace = 'public'::regnamespace), 'd',
          '(A) the domain t341a_p2022 is still there');

-- ---------------------------------------------------------------------------------------------------------
-- (B) a finer label is still in reach of a monthly grid: a '1 day' regrain of the monolith gives it
create table public.t341b (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.t341b select g, '2024-03-01 00:00+00'::timestamptz + g * interval '1 day' from generate_series(0, 19) g;
create table public.t341b_p2024_03_15 (note text);
insert into public.t341b_p2024_03_15 values ('mine');

select is(pgpm._part_name('t341b', 'time', '1 day', pgpm._ts_text('2024-03-15 00:00+00'), null, 'UTC')::text,
          't341b_p2024_03_15', 'LIVENESS: (B) a ''1 day'' regrain of the March monolith names a cell t341b_p2024_03_15');
select throws_like(
  $$ call pgpm.transmute('public.t341b', 'ts', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician: public.t341b_p2024_03_15 already exists as a standalone table matching this parent''s partition naming%Rename it out of the way (alter table public.t341b_p2024_03_15 rename to <a new name>)%',
  '(B) transmute refuses a standalone table at a label its own regrain can give, and the remedy renames it');
select is((select relkind::text from pg_class where oid = 'public.t341b'::regclass), 'r',
          '(B) the refusal left t341b a plain table');
-- the remedy, as the message types it
alter table public.t341b_p2024_03_15 rename to t341b_mine;
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341b', 'ts', interval '1 month', p_obtain => 2);
\set ON_ERROR_STOP 1
select is((select relkind::text from pg_class where oid = 'public.t341b'::regclass), 'p',
          '(B) with the table renamed as the message says, t341b converts');
select is((select array_agg(note) from public.t341b_mine), array['mine'],
          '(B) and the renamed table still holds its row');

-- ---------------------------------------------------------------------------------------------------------
-- (C) the same shape of holder as (A), on a grid whose own label it is
create table public.t341c (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.t341c select g, '2024-03-01 00:00+00'::timestamptz + g * interval '1 day' from generate_series(0, 19) g;
create table public.t341c_p2023 (id bigint not null, ts timestamptz not null);
insert into public.t341c_p2023 values (7, '2023-03-01 00:00+00'), (8, '2023-09-01 00:00+00');

select is(pgpm._part_name('t341c', 'time', '1 year', pgpm._ts_text('2023-01-01 00:00+00'), null, 'UTC')::text,
          't341c_p2023', 'LIVENESS: (C) the yearly grid names its 2023 cell t341c_p2023');
select throws_like(
  $$ call pgpm.transmute('public.t341c', 'ts', interval '1 year', p_obtain => 2) $$,
  'pg_partition_magician: public.t341c_p2023 already exists as a standalone table matching this parent''s partition naming%Rename it out of the way (alter table public.t341c_p2023 rename to <a new name>)%',
  '(C) a yearly grid refuses the table at its own label t341c_p2023');
select is((select relkind::text from pg_class where oid = 'public.t341c'::regclass), 'r',
          '(C) the refusal left t341c a plain table');
alter table public.t341c_p2023 rename to t341c_archive_2023;
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341c', 'ts', interval '1 year', p_obtain => 2);
\set ON_ERROR_STOP 1
select is((select relkind::text from pg_class where oid = 'public.t341c'::regclass), 'p',
          '(C) with the table renamed as the message says, t341c converts');
select is((select array_agg(id order by id) from public.t341c_archive_2023), array[7, 8]::bigint[],
          '(C) and the renamed table still holds ids 7 and 8: the remedy kept the operator''s rows');

-- ---------------------------------------------------------------------------------------------------------
-- (D) a year label is in reach of an '18 months' grid (a '1 year' regrain target is no wider than the step)
create table public.t341d (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.t341d select g, '2024-03-01 00:00+00'::timestamptz + g * interval '1 day' from generate_series(0, 19) g;
create domain public.t341d_p2025 as int;

select throws_like(
  $$ call pgpm.transmute('public.t341d', 'ts', interval '18 months', p_obtain => 2) $$,
  'pg_partition_magician: public.t341d_p2025 already exists as a domain matching this parent''s partition naming%',
  '(D) an ''18 months'' grid refuses a domain at a year label, which its ''1 year'' regrain target gives');
alter domain public.t341d_p2025 rename to t341d_mine;
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341d', 'ts', interval '18 months', p_obtain => 2);
\set ON_ERROR_STOP 1
select is((select relkind::text from pg_class where oid = 'public.t341d'::regclass), 'p',
          '(D) with the domain renamed, t341d converts');
select lives_ok($$ select pgpm.set_regrain('public.t341d', '1 year') $$,
                'LIVENESS: (D) set_regrain accepts ''1 year'' on the ''18 months'' grid');
select is(pgpm._part_name('t341d', 'time', '1 year', pgpm._ts_text('2025-01-01 00:00+00'), null, 'UTC')::text,
          't341d_p2025', 'LIVENESS: (D) and a ''1 year'' cell of 2025 is named t341d_p2025, the name the domain held');

-- ---------------------------------------------------------------------------------------------------------
-- (G) a month label is out of reach of a '30 days' grid anchored at 2000-01-01 (the default): set_regrain
-- measures '1 month' from the anchor, 31 days, wider than the step, so no target of a month's label is accepted
create table public.t341g (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.t341g select g, '2024-03-01 00:00+00'::timestamptz + g * interval '1 day' from generate_series(0, 19) g;
create table public.t341g_p2023_05 (note text);
insert into public.t341g_p2023_05 values ('mine');

select is(pgpm._part_name('t341g', 'time', '30 days', pgpm._ts_text('2023-05-01 00:00+00'), null, 'UTC')::text,
          't341g_p2023_05_01', 'LIVENESS: (G) the ''30 days'' grid labels its cells by the day');
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341g', 'ts', interval '30 days', p_obtain => 2);
\set ON_ERROR_STOP 1
select is((select relkind::text from pg_class where oid = 'public.t341g'::regclass), 'p',
          '(G) t341g converts on its ''30 days'' grid: t341g_p2023_05 is a month label it cannot give');
select throws_like($$ select pgpm.set_regrain('public.t341g', '1 month') $$,
                   '%regrain target step 1 month is coarser than partition_step%',
                   'LIVENESS: (G) set_regrain refuses ''1 month'' on it, the only way to a month label');
select is((select relkind::text || '/' || (select array_agg(note)::text from public.t341g_p2023_05)
             from pg_class where oid = 'public.t341g_p2023_05'::regclass),
          'r/{mine}', '(G) and t341g_p2023_05 is still the operator''s table, with its row');

-- ---------------------------------------------------------------------------------------------------------
-- (E) a partition of ANOTHER table at the first forward cell's name
create table public.t341e (id bigint primary key, v int);
insert into public.t341e select g, g from generate_series(1, 50) g;   -- step 1000: monolith [0, 1000)
create table public.f341_other (id bigint) partition by range (id);
create table public.t341e_p0000000000000001000 partition of public.f341_other for values from (0) to (10);
insert into public.f341_other values (3);

select is(pgpm._part_name('t341e', 'id', '1000', '1000', '2000', 'UTC')::text, 't341e_p0000000000000001000',
          'LIVENESS: (E) the held name is the first forward cell''s, [1000, 2000)');
select throws_like(
  $$ call pgpm.transmute('public.t341e', 'id', 1000::bigint, p_obtain => 2) $$,
  'pg_partition_magician: public.t341e_p0000000000000001000 already exists as a partition of public.f341_other matching this parent''s partition naming%alter table public.t341e_p0000000000000001000 rename to <a new name>%',
  '(E) transmute refuses a partition of another table at a forward cell''s name, naming the table it belongs to');
select ok((select relkind::text from pg_class where oid = 'public.t341e'::regclass) = 'r'
          and not exists (select 1 from pgpm.config where parent_table = 'public.t341e'::regclass),
          '(E) the refusal came up front: t341e is still a plain, unregistered table');
alter table public.t341e_p0000000000000001000 rename to f341_other_p0;
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341e', 'id', 1000::bigint, p_obtain => 2);
\set ON_ERROR_STOP 1
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'public.t341e'::regclass),
          array['t341e_p0000000000000000000', 't341e_p0000000000000001000', 't341e_p0000000000000002000'],
          '(E) with the partition renamed as the message says, t341e converts and the cell [1000, 2000) is its partition');
insert into public.t341e values (1500, 1);
select is((select tableoid::regclass::text from public.t341e where id = 1500), 't341e_p0000000000000001000',
          'LIVENESS: (E) a write into [1000, 2000) lands in that cell');
select is((select i.inhparent::regclass::text || '/' || (select array_agg(id)::text from public.f341_other_p0)
             from pg_inherits i where i.inhrelid = 'public.f341_other_p0'::regclass),
          'f341_other/{3}', '(E) and the renamed partition is still f341_other''s, with its row');

-- ---------------------------------------------------------------------------------------------------------
-- (F) an inheritance child of another table at the second forward cell's name
create table public.t341f (id bigint primary key, v int);
insert into public.t341f select g, g from generate_series(1, 40) g;   -- step 1000: monolith [0, 1000)
create table public.f341_base (id bigint);
create table public.t341f_p0000000000000002000 () inherits (public.f341_base);

select is(pgpm._part_name('t341f', 'id', '1000', '2000', '3000', 'UTC')::text, 't341f_p0000000000000002000',
          'LIVENESS: (F) the held name is the second forward cell''s, [2000, 3000)');
select throws_like(
  $$ call pgpm.transmute('public.t341f', 'id', 1000::bigint, p_obtain => 2) $$,
  'pg_partition_magician: public.t341f_p0000000000000002000 already exists as an inheritance child of public.f341_base matching this parent''s partition naming%',
  '(F) transmute refuses an inheritance child of another table at a forward cell''s name');
select ok((select relkind::text from pg_class where oid = 'public.t341f'::regclass) = 'r'
          and not exists (select 1 from pgpm.config where parent_table = 'public.t341f'::regclass),
          '(F) the refusal came up front: t341f is still a plain, unregistered table');
select is((select array_agg(inhparent::regclass::text) from pg_inherits
            where inhrelid = 'public.t341f_p0000000000000002000'::regclass),
          array['f341_base'], '(F) and the holder is still f341_base''s child');

select * from finish();
