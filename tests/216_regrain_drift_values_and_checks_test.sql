-- Issues #824 and #817 (F3-03, F7-03, F10-02): a regrain in flight must notice DDL on its parent that
-- leaves the column signature alone.
--
-- THE DEFECT. #785's drift check compared each copy's columns with the parent's by name, type, collation,
-- NOT NULL and generated, and nothing else. Two kinds of ALTER TABLE get past that.
--   1. DDL that changes VALUES without changing the signature (#824): a column dropped and added back under
--      the same name and type, or ALTER COLUMN ... TYPE <same type> USING <expression>, which rewrites every
--      row of the source. No row trigger fires for either, so capture sees nothing, the copies made before
--      the ALTER still read as current, and the swap attached them: the regrained range served the dropped
--      column's values, or the pre-rewrite ones. Silently wrong data.
--   2. A CHECK constraint added to the parent (#817): the copies, made LIKE the parent before it, lack it,
--      and the swap's ATTACH PARTITION requires it, so every swap tick failed 'child table is missing
--      constraint' (skip_regrain forever, capture left on the source).
--
-- THE FIX. The prepare tick records a mark of the source (its relfilenode, which a table rewrite replaces,
-- and each column's attnum, which a drop-and-add replaces) in config.regrain_source_mark, and every resumed
-- tick compares it with the source as it is now; the parent's CHECK constraints join the columns in the
-- copy comparison. Either difference restarts the run from the source (regrain_restart), as #785 does for a
-- column difference, so the range is copied again from rows that hold the values the ALTER gave them.
--
-- Fixtures asymmetric on purpose: rg216a takes a drop-and-add AND a later UPDATE of one row, so a swap of
-- stale copies and a swap that lost the UPDATE fail differently; rg216b's rewrite touches every row; rg216c
-- starts with a CHECK (so a comparison that forgot the copy's own bound CHECK, or that misread a CHECK the
-- copy inherited, would restart a run nothing touched) and mid-flight drops it and adds another. rg216d is
-- the control: a parent with a CHECK from the start and no DDL never restarts.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(17);

create schema s216;

create function s216.mk(p_rel text, p_n int) returns void language plpgsql as $f$
begin
  execute format('create table public.%I (id bigint primary key, payload text, note text)', p_rel);
  execute format('insert into public.%I select g, %L || g, ''old'' || g from generate_series(1, %s) g', p_rel, p_rel, p_n);
end $f$;
-- freeze the monolith ([0, 300) for 200 rows or more, [0, 200) below) and aim it at 50
create function s216.start(p_rel text) returns void language plpgsql as $f$
begin
  execute format('insert into public.%I (id, payload) values (450, %L)', p_rel, 'frontier');
  perform pgpm.set_regrain(('public.' || p_rel)::regclass, '50');
end $f$;
create function s216.mid(p_rel text) returns boolean language sql as $f$
  select exists (select 1 from pgpm.log where parent_table = ('public.' || p_rel)::regclass
                  and action = 'regrain_copy' and lo = '0' and hi = '50' and rows = 49)
     and (select regrain_cursor from pgpm.config where parent_table = ('public.' || p_rel)::regclass) = '50'
$f$;
create function s216.swapped(p_rel text, p_hi text) returns boolean language sql as $f$
  select exists (select 1 from pgpm.log where parent_table = ('public.' || p_rel)::regclass
                  and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = p_hi)
     and (select coarse_partitions from pgpm.status() where parent = ('public.' || p_rel)::regclass) = 0
$f$;
create function s216.restarts(p_rel text) returns text[] language sql as $f$
  select array_agg(rows || ':' || method order by id) from pgpm.log
   where parent_table = ('public.' || p_rel)::regclass and action = 'regrain_restart'
$f$;

select s216.mk('rg216a', 200); select s216.mk('rg216b', 230);
create table public.rg216c (id bigint primary key, payload text, note text,
                            constraint rg216c_old check (length(payload) < 50));
insert into public.rg216c select g, 'c' || g, 'old' || g from generate_series(1, 170) g;
create table public.rg216d (id bigint primary key, payload text, note text,
                            constraint rg216d_ck2 check (id <> 77777));
insert into public.rg216d select g, 'd' || g, 'old' || g from generate_series(1, 140) g;
call pgpm.transmute('public.rg216a', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
call pgpm.transmute('public.rg216b', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
call pgpm.transmute('public.rg216c', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
call pgpm.transmute('public.rg216d', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rg216a'), pgpm.obtain('public.rg216b'), pgpm.obtain('public.rg216c'), pgpm.obtain('public.rg216d');
select s216.start('rg216a'), s216.start('rg216b'), s216.start('rg216c'), s216.start('rg216d');
call pgpm.maintain('public.rg216a'); call pgpm.maintain('public.rg216a');   -- prepare, copy [0, 50)
call pgpm.maintain('public.rg216b'); call pgpm.maintain('public.rg216b');
call pgpm.maintain('public.rg216c'); call pgpm.maintain('public.rg216c');

create table s216.copies as
  select parent_table, child_oid from pgpm.part
   where parent_table in ('public.rg216a'::regclass, 'public.rg216b'::regclass, 'public.rg216c'::regclass)
     and not attached and lo = '0' and hi = '50';
create function s216.copy_note(p_rel text, p_id bigint) returns text language plpgsql as $f$
declare r text; begin
  execute format('select note from %s where id = $1',
                 (select child_oid::regclass from s216.copies where parent_table = ('public.' || p_rel)::regclass))
    into r using p_id;
  return r;
end $f$;

select ok(s216.mid('rg216a') and s216.mid('rg216b') and s216.mid('rg216c')
          and (select count(*) from s216.copies c join pg_class k on k.oid = c.child_oid) = 3,
          'LIVENESS: all three runs are mid-flight: each copy of [0, 50) holds 49 rows and each cursor is at 50');

-- ---------------------------------------------------------------------------------------------------
-- The DDL, between ticks.
-- ---------------------------------------------------------------------------------------------------
alter table public.rg216a drop column note;
alter table public.rg216a add column note text default 'new';
update public.rg216a set note = 'late' where id = 30;                    -- captured, below the cursor
alter table public.rg216b alter column note type text using upper(note); -- same type: a rewrite only
alter table public.rg216c drop constraint rg216c_old;
alter table public.rg216c add constraint rg216c_new check (length(payload) < 40);
create table s216.want_a as select id, payload, note from public.rg216a where id < 300;
create table s216.want_b as select id, payload, note from public.rg216b where id < 300;
create table s216.want_c as select id, payload, note from public.rg216c where id < 300;

select ok((select array_agg(note order by id) from s216.want_a where id in (10, 30, 120)) = array['new', 'late', 'new']
          and s216.copy_note('rg216a', 10) = 'old10'
          and (select format_type(atttypid, atttypmod) from pg_attribute
                where attrelid = 'public.rg216a'::regclass and attname = 'note') = 'text',
          'LIVENESS A: the source reads note = new (late for id 30) and the copy made before the ALTERs still holds old10, under an unchanged signature');
select ok((select note from s216.want_b where id = 10) = 'OLD10' and s216.copy_note('rg216b', 10) = 'old10',
          'LIVENESS B: the rewrite gave the source OLD10 and the copy made before it still holds old10');
select ok(exists (select 1 from pg_constraint where conrelid = 'public.rg216c'::regclass and conname = 'rg216c_new')
          and not exists (select 1 from pg_constraint where conrelid = 'public.rg216c'::regclass and conname = 'rg216c_old')
          and exists (select 1 from pg_constraint k join s216.copies c on k.conrelid = c.child_oid
                       where c.parent_table = 'public.rg216c'::regclass and k.conname = 'rg216c_old')
          and not exists (select 1 from pg_constraint k join s216.copies c on k.conrelid = c.child_oid
                           where c.parent_table = 'public.rg216c'::regclass and k.conname = 'rg216c_new'),
          'LIVENESS C: the parent swapped CHECK rg216c_old for rg216c_new and the copy made before still has only the old one');

do $$ declare v text; begin for i in 1..30 loop
  call pgpm.maintain('public.rg216a', v); call pgpm.maintain('public.rg216b', v);
  call pgpm.maintain('public.rg216c', v); call pgpm.maintain('public.rg216d', v);
end loop; end $$;

-- ---------------------------------------------------------------------------------------------------
-- A: a column dropped and added back under the same name and type.
-- ---------------------------------------------------------------------------------------------------
select is((select array_agg(left(r, 2) || (r like '%column(s) note were replaced%')::text) from unnest(s216.restarts('rg216a')) r),
          array['1:true'],
          'A: the run restarts exactly once, discarding the one copy, because the source had a column replaced');
select ok(s216.swapped('rg216a', '300') and not exists (select 1 from s216.copies c join pg_class k on k.oid = c.child_oid
                                                   where c.parent_table = 'public.rg216a'::regclass),
          'A: the stale copy is discarded and the regrain swaps, leaving no coarse partition');
select results_eq('select id, payload, note from public.rg216a where id < 300 order by id',
                  'select id, payload, note from s216.want_a order by id',
                  'A: the regrained range holds exactly the source''s rows (note = new, late for id 30), not the dropped column''s');

-- ---------------------------------------------------------------------------------------------------
-- B: ALTER COLUMN ... TYPE <same type> USING <expression>.
-- ---------------------------------------------------------------------------------------------------
select is((select array_agg(left(r, 2) || (r like '%the source was rewritten%')::text) from unnest(s216.restarts('rg216b')) r),
          array['1:true'],
          'B: the run restarts exactly once, discarding the one copy, because the source was rewritten');
select ok(s216.swapped('rg216b', '300'), 'B: the regrain swaps');
select results_eq('select id, payload, note from public.rg216b where id < 300 order by id',
                  'select id, payload, note from s216.want_b order by id',
                  'B: the regrained range holds the rewritten values (OLD1 .. OLD230), not the pre-rewrite ones');

-- ---------------------------------------------------------------------------------------------------
-- C: a CHECK dropped and another added.
-- ---------------------------------------------------------------------------------------------------
select is((select string_agg(distinct method, ' | ') from pgpm.log
            where parent_table = 'public.rg216c'::regclass and action = 'skip_regrain'),
          null, 'C: no auto-regrain tick fails after the CHECK constraints change');
select is((select array_agg(left(r, 2) || (r like '%check rg216c_new%' and r like '%check rg216c_old%')::text) from unnest(s216.restarts('rg216c')) r),
          array['1:true'],
          'C: the run restarts exactly once, discarding the one copy and naming both CHECKs that differ');
select ok(s216.swapped('rg216c', '200'), 'C: the regrain swaps');
select is((select array_agg(p.lo || '-' || p.hi || ':' || coalesce(k.checks, '') order by p.lo::numeric)
             from pgpm.part p
             left join lateral (select string_agg(conname::text, ',' order by conname) as checks from pg_constraint
                                 where conrelid = p.child_oid and contype = 'c' and conname in ('rg216c_new', 'rg216c_old')) k on true
            where p.parent_table = 'public.rg216c'::regclass and p.attached and p.lo::numeric < 200),
          array['0-50:rg216c_new', '50-100:rg216c_new', '100-150:rg216c_new', '150-200:rg216c_new'],
          'C: each fine child the swap attached carries the CHECK the parent has now, and none the one it dropped');
select results_eq('select id, payload, note from public.rg216c where id < 300 order by id',
                  'select id, payload, note from s216.want_c order by id',
                  'C: the table holds exactly the source''s rows');

-- ---------------------------------------------------------------------------------------------------
-- D (control): a parent with a CHECK from the start and no DDL. The copies carry that CHECK and their
-- own bound CHECK; neither may read as drift.
-- ---------------------------------------------------------------------------------------------------
select ok(s216.restarts('rg216d') is null and s216.swapped('rg216d', '200')
          and (select array_agg(lo || '-' || hi || ':' || rows order by id) from pgpm.log
                where parent_table = 'public.rg216d'::regclass and action = 'regrain_copy')
              = array['0-50:49', '50-100:50', '100-150:41'],
          'D: with no DDL the run copies each populated sub-range once, swaps, and never restarts');
select is((select count(*)::int from pg_inherits i join pg_constraint k on k.conrelid = i.inhrelid
            where i.inhparent = 'public.rg216d'::regclass and k.conname = 'rg216d_ck2'),
          (select count(*)::int from pg_inherits where inhparent = 'public.rg216d'::regclass),
          'D: and every partition carries the parent''s CHECK');

select * from finish();
