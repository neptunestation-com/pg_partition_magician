-- Issue #785: DDL on a managed parent while auto-regrain is mid-copy must not wedge the run.
--
-- THE DEFECT. regrain's fine copies are standalone tables created LIKE the parent as it stood when each
-- was made, and nothing carries later DDL to them, while every copy and reconcile statement lists the
-- parent's CURRENT columns and the swap's ATTACH requires the copy's columns to match the parent's. So an
-- `ALTER TABLE <parent> ADD COLUMN` after the first copy failed every later tick with skip_regrain
-- 'column ... does not exist', the cursor never moved, capture stayed on the source and the monolith was
-- never split. A DROP COLUMN or a column TYPE change failed the same way, at the copy or at the ATTACH.
--
-- THE FIX. Each resumed tick compares every copy's columns (name, type, collation, NOT NULL, generated)
-- with the parent's before it reconciles or copies, and when one differs it discards the copies and
-- restarts the run from the source's lo, logged regrain_restart with the drift named. The copies are
-- recreated LIKE the parent as it is now, and the source, which ALTER TABLE on the parent reaches, still
-- holds every row, so the restart costs the copying done so far and nothing else.
--
-- Why not ADD COLUMN on each copy instead: a copy's rows would take the new column's value by
-- re-evaluating its default, and only a constant default gives them the value the source's rows got. A
-- volatile one (part A's nextval) rewrote the source with one value per row, which the copy cannot
-- reproduce without rereading every row it holds from the source, which is what the restart does.
--
-- Two tables, asymmetric on purpose. rg211a takes an ADD COLUMN with a constant default and one with a
-- volatile default, then committed DML (one UPDATE, two DELETEs, one INSERT) that uses the new columns.
-- rg211b takes a DROP COLUMN and a TYPE change. Each must restart exactly once (a restart that recurred
-- would mean the recreated copies still read as drifted), swap, and hold exactly the rows its source held.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(14);

create schema s211;
create sequence s211.tag_seq start 1000;

-- ---------------------------------------------------------------------------------------------------
-- Part A: ADD COLUMN (constant and volatile defaults) mid-copy.
-- ---------------------------------------------------------------------------------------------------
create table public.rg211a (id bigint primary key, payload text);
insert into public.rg211a select g, 'a' || g from generate_series(1, 200) g;
call pgpm.transmute('public.rg211a', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);   -- monolith [0, 300)
select pgpm.obtain('public.rg211a');
insert into public.rg211a values (450, 'frontier');   -- the monolith is frozen
select pgpm.set_regrain('public.rg211a', '50');
call pgpm.maintain('public.rg211a');   -- prepare
call pgpm.maintain('public.rg211a');   -- copies [0, 50)

create table s211.copy_a as
  select child_oid from pgpm.part
   where parent_table = 'public.rg211a'::regclass and not attached and lo = '0' and hi = '50';

select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg211a'::regclass
                   and action = 'regrain_copy' and lo = '0' and hi = '50' and rows = 49)
          and (select regrain_cursor from pgpm.config where parent_table = 'public.rg211a'::regclass) = '50'
          and (select count(*) from s211.copy_a c join pg_class k on k.oid = c.child_oid) = 1,
          'LIVENESS: (A) auto-regrain is mid-flight: the copy of [0, 50) holds 49 rows and the cursor is at 50');

alter table public.rg211a add column note text default 'n';
alter table public.rg211a add column tag bigint default nextval('s211.tag_seq');   -- volatile: a rewrite
update public.rg211a set note = 'late' where id = 10;
delete from public.rg211a where id in (20, 120);
insert into public.rg211a (id, payload, note) values (250, 'ins', 'new');
create table s211.want_a as select id, payload, note, tag from public.rg211a where id < 300;

select ok((select count(distinct tag) from s211.want_a) = 199
          and not exists (select 1 from pg_attribute a join s211.copy_a c on a.attrelid = c.child_oid
                           where a.attname in ('note', 'tag')),
          'LIVENESS: (A) the source holds a distinct tag per row, and the copy made before the ALTER has neither new column');

do $$ declare v text; begin for i in 1..30 loop call pgpm.maintain('public.rg211a', v); end loop; end $$;

select is((select string_agg(distinct method, ' | ') from pgpm.log
            where parent_table = 'public.rg211a'::regclass and action = 'skip_regrain'),
          null, 'A: no auto-regrain tick fails after the ADD COLUMNs');
select is((select array_agg(rows || ' ' || (method like '%note%' and method like '%tag%')) from pgpm.log
            where parent_table = 'public.rg211a'::regclass and action = 'regrain_restart'),
          array['1 true'],
          'A: the run restarts exactly once, discarding the one copy and naming both columns the parent gained');
select ok(not exists (select 1 from s211.copy_a c join pg_class k on k.oid = c.child_oid),
          'A: the copy made before the ALTER is the one discarded');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg211a'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300')
          and (select coarse_partitions from pgpm.status() where parent = 'public.rg211a'::regclass) = 0,
          'A: the regrain swaps and no coarse partition is left');
select results_eq('select id, payload, note, tag from public.rg211a where id < 300 order by id',
                  'select id, payload, note, tag from s211.want_a order by id',
                  'A: the table holds exactly the source''s rows, each with its own value in both new columns');

-- ---------------------------------------------------------------------------------------------------
-- Part B: DROP COLUMN and a column TYPE change mid-copy.
-- ---------------------------------------------------------------------------------------------------
create table public.rg211b (id bigint primary key, payload text, extra int);
insert into public.rg211b select g, 'b' || g, g * 7 from generate_series(1, 260) g;
call pgpm.transmute('public.rg211b', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);   -- monolith [0, 300)
select pgpm.obtain('public.rg211b');
insert into public.rg211b values (450, 'frontier', 0);
select pgpm.set_regrain('public.rg211b', '50');
call pgpm.maintain('public.rg211b');   -- prepare
call pgpm.maintain('public.rg211b');   -- copies [0, 50)
call pgpm.maintain('public.rg211b');   -- copies [50, 100)

select ok((select count(*) from pgpm.log where parent_table = 'public.rg211b'::regclass and action = 'regrain_copy') = 2
          and (select regrain_cursor from pgpm.config where parent_table = 'public.rg211b'::regclass) = '100',
          'LIVENESS: (B) two sub-ranges are copied and the cursor is at 100');

alter table public.rg211b drop column extra;
alter table public.rg211b alter column payload type varchar(40);
update public.rg211b set payload = 'changed' where id = 60;
create table s211.want_b as select id, payload from public.rg211b where id < 300;

do $$ declare v text; begin for i in 1..30 loop call pgpm.maintain('public.rg211b', v); end loop; end $$;

select is((select string_agg(distinct method, ' | ') from pgpm.log
            where parent_table = 'public.rg211b'::regclass and action = 'skip_regrain'),
          null, 'B: no auto-regrain tick fails after the DROP COLUMN and the TYPE change');
select is((select array_agg(rows || ' ' || (method like '%extra%' and method like '%payload%')) from pgpm.log
            where parent_table = 'public.rg211b'::regclass and action = 'regrain_restart'),
          array['2 true'],
          'B: the run restarts exactly once, discarding both copies and naming both changed columns');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg211b'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300')
          and (select coarse_partitions from pgpm.status() where parent = 'public.rg211b'::regclass) = 0,
          'B: the regrain swaps and no coarse partition is left');
select results_eq('select id, payload::text from public.rg211b where id < 300 order by id',
                  'select id, payload::text from s211.want_b order by id',
                  'B: the table holds exactly the source''s rows, the changed one included');
select is((select format_type(atttypid, atttypmod) from pg_attribute
            where attrelid = 'public.rg211b'::regclass and attname = 'payload'),
          'character varying(40)', 'B: and the parent keeps the type it was altered to');

-- ---------------------------------------------------------------------------------------------------
-- Part C: a regrain the parent's DDL never touched does not restart (the comparison does not misfire on
-- a copy that matches, which would restart the run every tick and never let it swap).
-- ---------------------------------------------------------------------------------------------------
create table public.rg211c (id bigint primary key, payload text, n numeric(8, 2) not null default 0);
insert into public.rg211c select g, 'c' || g, g / 4.0 from generate_series(1, 230) g;
call pgpm.transmute('public.rg211c', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);   -- monolith [0, 300)
select pgpm.obtain('public.rg211c');
insert into public.rg211c values (450, 'frontier', 0);
select pgpm.set_regrain('public.rg211c', '50');
do $$ declare v text; begin for i in 1..20 loop call pgpm.maintain('public.rg211c', v); end loop; end $$;

select ok(not exists (select 1 from pgpm.log where parent_table = 'public.rg211c'::regclass and action = 'regrain_restart')
          and (select array_agg(lo || '-' || hi || ':' || rows order by id) from pgpm.log
                where parent_table = 'public.rg211c'::regclass and action = 'regrain_copy')
              = array['0-50:49', '50-100:50', '100-150:50', '150-200:50', '200-250:31']
          and exists (select 1 from pgpm.log where parent_table = 'public.rg211c'::regclass
                       and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          'C: with no DDL on the parent the run copies each populated sub-range once, swaps, and never restarts');

select * from finish();
