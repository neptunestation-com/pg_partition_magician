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
--       Refused naming it as such; the typed rename converts it and the child stays its parent's.
--   (I) t341i, id grid step 1000: an INDEX at the first forward cell's name, attached to another table's
--       partitioned index. Refused with `alter index` as the remedy, which is typed.
--   (J) t341j, id grid step 1000: a FOREIGN TABLE partition of another table at the first forward cell's
--       name. Refused with `alter foreign table` as the remedy, which is typed.
--   (K) t341k, id grid step 1000, two forward cells: two partitions of ANOTHER table at names the conversion
--       does NOT create, a '500' regrain cell inside the monolith and the cell [4000, 5000). Converts (a table
--       renamed aside keeps names like these, #496); the later refusals fire where the names are reached:
--       regrain_step refuses the first (#631), obtain leaves the second's cell unbuilt and logs
--       fail_obtain_name naming it, and the other table keeps both partitions and both rows.
--   (L) t341l, '1 month' grid anchored at 294276-01-01, within a year of PostgreSQL's last timestamp, beside
--       the operator's t341l_p2023: the '1 year' probe overflows, which is a granularity out of reach, not an
--       error, so the conversion goes through and the table is left alone.
--   (H) t341h, '1 month' grid converted with p_incoming_fks => 'preserve' beside the operator's t341h_p2023
--       (ids 7 and 8): the cutover drops r341h_fk, and restore_incoming_fks, whose in-flight gate recognises a
--       fine child's name as the orphan guard does, must not take the table the guard let through for an
--       in-flight child. A standalone t341h_p2024_03_15 made after the conversion (a day label, in reach)
--       does hold the re-add off, which is the gate's liveness; renamed away, the key comes back with
--       t341h_p2023 still in place.
-- bench/transmute_child_holders_by_grid.sh runs this file against the mutants that drop the grid's label test
-- from the pg_class half (child_holders_any_kind_label), from the pg_type half
-- (child_holder_types_any_kind_label) and from restore_incoming_fks's gate (restore_gate_any_kind_label), and
-- narrow the exemption back to any pg_inherits parent (child_holders_any_parent_exempt), and widen the
-- hierarchy refusal past the names the conversion creates (child_holders_inherits_any_name).
create extension if not exists pgtap;

select plan(58);

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
          and not exists (select 1 from pgpm.config where parent_table = 'public.t341e'::regclass)
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t341e'::regclass)
          and not exists (select 1 from pg_constraint where conrelid = 'public.t341e'::regclass
                             and conname = 'pgpm_monolith_bound'),
          '(E) the refusal came up front: t341e is still a plain, unregistered table, with no claim and no bound');
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
-- the remedy, as the message types it
alter table public.t341f_p0000000000000002000 rename to f341_base_child;
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341f', 'id', 1000::bigint, p_obtain => 2);
\set ON_ERROR_STOP 1
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'public.t341f'::regclass),
          array['t341f_p0000000000000000000', 't341f_p0000000000000001000', 't341f_p0000000000000002000'],
          '(F) with the child renamed as the message says, t341f converts and the cell [2000, 3000) is its partition');
select is((select array_agg(inhparent::regclass::text) from pg_inherits where inhrelid = 'public.f341_base_child'::regclass),
          array['f341_base'], '(F) and the renamed child is still f341_base''s');

-- ---------------------------------------------------------------------------------------------------------
-- (I) an index at the first forward cell's name, attached to another table's partitioned index
create table public.t341i (id bigint primary key, v int);
insert into public.t341i select g, g from generate_series(1, 30) g;   -- step 1000: monolith [0, 1000)
create table public.f341_iother (id bigint) partition by range (id);
create table public.f341_iother_p0 partition of public.f341_iother for values from (0) to (10);
create index f341_iother_idx on public.f341_iother (id);
alter index public.f341_iother_p0_id_idx rename to t341i_p0000000000000001000;

select throws_like(
  $$ call pgpm.transmute('public.t341i', 'id', 1000::bigint, p_obtain => 2) $$,
  'pg_partition_magician: public.t341i_p0000000000000001000 already exists as a partition of public.f341_iother_idx matching this parent''s partition naming%alter index public.t341i_p0000000000000001000 rename to <a new name>%',
  '(I) transmute refuses an index of another table''s partitioned index at a forward cell''s name, and the remedy is alter index');
alter index public.t341i_p0000000000000001000 rename to f341_iother_p0_idx;
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341i', 'id', 1000::bigint, p_obtain => 2);
\set ON_ERROR_STOP 1
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'public.t341i'::regclass),
          array['t341i_p0000000000000000000', 't341i_p0000000000000001000', 't341i_p0000000000000002000'],
          '(I) with the index renamed as the message says, t341i converts and the cell [1000, 2000) is its partition');
select is((select array_agg(inhparent::regclass::text) from pg_inherits where inhrelid = 'public.f341_iother_p0_idx'::regclass),
          array['f341_iother_idx'], '(I) and the renamed index is still attached to f341_iother_idx');

-- ---------------------------------------------------------------------------------------------------------
-- (J) a foreign table, partition of another table, at the first forward cell's name
create table public.t341j (id bigint primary key, v int);
insert into public.t341j select g, g from generate_series(1, 20) g;   -- step 1000: monolith [0, 1000)
create foreign data wrapper fdw341;
create server srv341 foreign data wrapper fdw341;
create table public.f341_fother (id bigint) partition by range (id);
create foreign table public.t341j_p0000000000000001000 partition of public.f341_fother
  for values from (0) to (10) server srv341;

select throws_like(
  $$ call pgpm.transmute('public.t341j', 'id', 1000::bigint, p_obtain => 2) $$,
  'pg_partition_magician: public.t341j_p0000000000000001000 already exists as a partition of public.f341_fother matching this parent''s partition naming%alter foreign table public.t341j_p0000000000000001000 rename to <a new name>%',
  '(J) transmute refuses a foreign-table partition of another table at a forward cell''s name, and the remedy is alter foreign table');
alter foreign table public.t341j_p0000000000000001000 rename to f341_fother_p0;
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341j', 'id', 1000::bigint, p_obtain => 2);
\set ON_ERROR_STOP 1
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'public.t341j'::regclass),
          array['t341j_p0000000000000000000', 't341j_p0000000000000001000', 't341j_p0000000000000002000'],
          '(J) with the foreign table renamed as the message says, t341j converts and the cell [1000, 2000) is its partition');
select is((select array_agg(inhparent::regclass::text) from pg_inherits where inhrelid = 'public.f341_fother_p0'::regclass),
          array['f341_fother'], '(J) and the renamed foreign table is still f341_fother''s partition');

-- ---------------------------------------------------------------------------------------------------------
-- (K) a partition of another table at names the conversion does not create is left to the later refusals
create table public.t341k (id bigint primary key, v int);
insert into public.t341k select g, g from generate_series(1, 60) g;   -- step 1000: monolith [0, 1000)
create table public.f341_kother (id bigint) partition by range (id);
create table public.t341k_p0000000000000000500 partition of public.f341_kother for values from (0) to (10);
create table public.t341k_p0000000000000004000 partition of public.f341_kother for values from (10) to (20);
insert into public.f341_kother values (4), (14);

select is(array[pgpm._part_name('t341k', 'id', '500', '500', '1000', 'UTC')::text,
                pgpm._part_name('t341k', 'id', '1000', '4000', '5000', 'UTC')::text],
          array['t341k_p0000000000000000500', 't341k_p0000000000000004000'],
          'LIVENESS: (K) the held names are a ''500'' regrain cell inside the monolith and the cell [4000, 5000), past the two forward cells');
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341k', 'id', 1000::bigint, p_obtain => 2);
\set ON_ERROR_STOP 1
select is((select array_agg(c.relname::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'public.t341k'::regclass),
          array['t341k_p0000000000000000000', 't341k_p0000000000000001000', 't341k_p0000000000000002000'],
          '(K) t341k converts beside them: neither is a name the conversion creates');
insert into public.t341k values (2500, 0);   -- the frontier past the monolith: it is frozen
select throws_like($$ select pgpm.regrain('public.t341k', 't341k_p0000000000000000000', '500') $$,
                   '%t341k_p0000000000000000500 already exists and this regrain did not create it%',
                   '(K) the later regrain to ''500'' refuses the held name before a row moves');
select is((select array_agg(id order by id) from public.t341k where id < 1000),
          (select array_agg(g::bigint order by g) from generate_series(1, 60) g),
          '(K) and every row of the monolith is still read through t341k');
select is(pgpm.extend_to('public.t341k', '4500'), 1,
          'LIVENESS: (K) extending the grid to 4500 builds the one cell it can, [3000, 4000)');
select is((select array_agg(l.lo || '-' || l.hi || ':' || (l.method like '%t341k_p0000000000000004000%')::text)
             from pgpm.log l where l.parent_table = 'public.t341k'::regclass and l.action = 'fail_obtain_name')
          || (select array_agg(p.child_name::text) from pgpm.part p
               where p.parent_table = 'public.t341k'::regclass and p.lo = '4000'),
          array['4000-5000:true'],
          '(K) and leaves [4000, 5000) unbuilt, logging fail_obtain_name that names the holder');
select is((select array_agg(c.relname::text || '/' || i.inhparent::regclass::text order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'public.f341_kother'::regclass)
          || (select array_agg(id::text order by id) from public.f341_kother),
          array['t341k_p0000000000000000500/f341_kother', 't341k_p0000000000000004000/f341_kother', '4', '14'],
          '(K) the other table keeps both partitions and both rows');

-- ---------------------------------------------------------------------------------------------------------
-- (H) what the guard lets through, restore_incoming_fks's in-flight gate must not take for an in-flight child
create table public.t341h (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.t341h select g, '2024-03-01 00:00+00'::timestamptz + g * interval '1 day' from generate_series(0, 19) g;
create table public.r341h (hid bigint, hts timestamptz,
                           constraint r341h_fk foreign key (hid, hts) references public.t341h (id, ts));
insert into public.r341h values (3, '2024-03-04 00:00+00'), (5, '2024-03-06 00:00+00');
create table public.t341h_p2023 (id bigint not null, ts timestamptz not null);
insert into public.t341h_p2023 values (7, '2023-03-01 00:00+00'), (8, '2023-09-01 00:00+00');

\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341h', 'ts', interval '1 month', p_obtain => 2, p_incoming_fks => 'preserve');
\set ON_ERROR_STOP 1
select is((select array_agg(d.constraint_name::text || '/' || (d.restored_at is not null)::text)
             from pgpm.dropped_fk d where d.parent_table = 'public.t341h'::regclass)
          || (select array_agg(c.conname::text) from pg_constraint c
               where c.conrelid = 'public.r341h'::regclass and c.contype = 'f'),
          array['r341h_fk/false'],
          'LIVENESS: (H) the preserve conversion beside t341h_p2023 dropped r341h_fk and has it to re-add');
-- the gate's liveness: a standalone table at a label a regrain of this grid gives holds the re-add off
create table public.t341h_p2024_03_15 (note text);
select is(pgpm.restore_incoming_fks('public.t341h'), 0,
          'LIVENESS: (H) a standalone table at a day label, made after the conversion, holds the re-add off');
alter table public.t341h_p2024_03_15 rename to t341h_mine;
select is(pgpm.restore_incoming_fks('public.t341h'), 1,
          '(H) with that table renamed, the key is re-added: t341h_p2023, a label the grid cannot give, is no in-flight child');
select is((select array_agg(c.conname::text || '/' || c.confrelid::regclass::text) from pg_constraint c
            where c.conrelid = 'public.r341h'::regclass and c.contype = 'f' and c.conparentid = 0),
          array['r341h_fk/t341h'], '(H) r341h_fk is back on r341h, against the converted t341h');
select throws_ok($$ insert into public.r341h values (999, '2024-03-07 00:00+00') $$, '23503', NULL,
                 '(H) and it is enforced: a row of r341h with no parent row is refused');
select is((select relkind::text || '/' || relispartition::text || '/' || (select array_agg(id order by id)::text from public.t341h_p2023)
             from pg_class where oid = 'public.t341h_p2023'::regclass),
          'r/false/{7,8}', '(H) t341h_p2023 is still the operator''s standalone table, holding ids 7 and 8');

-- ---------------------------------------------------------------------------------------------------------
-- (L) a probe past PostgreSQL's last timestamp is a granularity out of reach, not an error
create table public.t341l (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.t341l select g, '2024-03-01 00:00+00'::timestamptz + g * interval '1 day' from generate_series(0, 19) g;
create table public.t341l_p2023 (note text);
insert into public.t341l_p2023 values ('mine');
select throws_ok($$ select pgpm._grid_next('time', '1 year', pgpm._ts_text('294276-01-01 00:00+00'), 'UTC') $$,
                 '22008', NULL,
                 'LIVENESS: (L) a year from the anchor 294276-01-01 is past PostgreSQL''s last timestamp');
\set ON_ERROR_STOP 0
call pgpm.transmute('public.t341l', 'ts', interval '1 month', p_obtain => 2, p_anchor => '294276-01-01 00:00+00');
\set ON_ERROR_STOP 1
select is((select relkind::text from pg_class where oid = 'public.t341l'::regclass), 'p',
          '(L) t341l converts on its monthly grid anchored in PostgreSQL''s last year: the year probe''s overflow refuses nothing');
select is((select relkind::text || '/' || (select array_agg(note)::text from public.t341l_p2023)
             from pg_class where oid = 'public.t341l_p2023'::regclass),
          'r/{mine}', '(L) and t341l_p2023 is still the operator''s table, with its row');

select * from finish();
