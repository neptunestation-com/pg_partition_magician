-- Issue #817 (F3-02, F3-08): a regrain's change capture must follow its parent's key when the key is renamed
-- or retyped mid-regrain.
--
-- THE DEFECT. The prepare tick mints the capture apparatus from the reused key as it stands then: the delta's
-- columns are the key's names and types, and the trigger function inserts `new.<name>` / `old.<name>` into
-- them. #785's drift restart re-copied the range but kept both, so after a key column was renamed every
-- UPDATE or DELETE into the regraining range failed 42703 (record "old" has no field) until the swap, and a
-- change captured before the rename made every reconcile fail ('column d.k does not exist', skip_regrain
-- forever: the run never swapped). After a key column was widened (int to bigint) the delta kept the int
-- column, so every write of a key past 2^31 failed 22003 from the capture trigger until the swap, though the
-- parent accepted it.
--
-- THE FIX. Every resumed tick compares the delta's columns with the parent's key as it is now, and when they
-- differ it restarts the run (regrain_restart) and mints the capture apparatus again from the current key:
-- the trigger is dropped and recreated (which waits for every writer in flight on the source), and the delta
-- and the function are re-minted. Dropping the captured rows with the old delta loses nothing, because the
-- restart discards every copy and the range is copied again from the source, which holds every change
-- committed before it. pgpm has no hook into ALTER TABLE itself, so between the ALTER and that tick a write
-- the old trigger cannot record is REFUSED (the write raises and nothing lands), never lost: parts A and B
-- assert that window as well, so a later change that makes it silent instead of loud cannot pass.
--
-- Fixtures asymmetric on purpose: part A carries one change captured before the rename and an UPDATE, a
-- DELETE and an INSERT after it; part B one wide INSERT per side of the restart's sub-ranges and a DELETE.
-- Part C is the control: a composite key whose order differs from the table's column order, no DDL, and the
-- capture must not be re-minted (a comparison by column order instead of key order would restart every tick).
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(19);

create schema s217;
create function s217.swapped(p_rel text, p_hi text) returns boolean language sql as $f$
  select exists (select 1 from pgpm.log where parent_table = ('public.' || p_rel)::regclass
                  and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = p_hi)
     and (select coarse_partitions from pgpm.status() where parent = ('public.' || p_rel)::regclass) = 0
$f$;
-- the delta's key columns, as the capture apparatus records them now
create function s217.delta_cols(p_rel text) returns text language sql as $f$
  select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' order by a.attnum)
    from pgpm.config c join pg_attribute a on a.attrelid = c.regrain_delta_oid
   where c.parent_table = ('public.' || p_rel)::regclass and a.attnum > 0 and not a.attisdropped
     and a.attname <> 'pgpm_seq'
$f$;

-- ---------------------------------------------------------------------------------------------------
-- Part A: a key column (not the control column) renamed mid-regrain.
-- ---------------------------------------------------------------------------------------------------
create table public.rg217a (k bigint, n bigint, payload text, primary key (k, n));
insert into public.rg217a select g + 1000, g, 'a' || g from generate_series(1, 200) g;
call pgpm.transmute('public.rg217a', 'n', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rg217a');
insert into public.rg217a values (1450, 450, 'frontier');
select pgpm.set_regrain('public.rg217a', '50');
call pgpm.maintain('public.rg217a');   -- prepare
call pgpm.maintain('public.rg217a');   -- copies [0, 50)
update public.rg217a set payload = 'early' where n = 10;   -- captured under the old key names
create table s217.delta_a as select regrain_delta_oid as oid from pgpm.config where parent_table = 'public.rg217a'::regclass;

select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg217a'::regclass
                   and action = 'regrain_copy' and lo = '0' and hi = '50' and rows = 49)
          and pgpm._regrain_delta_count('public.rg217a'::regclass) = 2
          and s217.delta_cols('rg217a') = 'k bigint, n bigint',
          'LIVENESS: (A) the run is mid-flight and the UPDATE of n = 10 is captured (old + new key) under the key k, n');

alter table public.rg217a rename column k to kk;

select throws_ok($$update public.rg217a set payload = 'window' where n = 40$$, '42703', null,
                 'A: until the next tick, a write the capture minted for k cannot record is refused (it raises)');
select is((select payload from public.rg217a where n = 40), 'a40',
          'A: and the refused write left the row as it was (refused, not half-applied)');

call pgpm.maintain('public.rg217a');   -- the tick that meets the rename

select is((select array_agg(rows || ':' || (method like '%change capture%kk bigint, n bigint%')::text) from pgpm.log
            where parent_table = 'public.rg217a'::regclass and action = 'regrain_restart'),
          array['1:true'],
          'A: that tick restarts the run, discarding the one copy and naming the key capture is re-minted for');
select ok(s217.delta_cols('rg217a') = 'kk bigint, n bigint'
          and (select regrain_delta_oid from pgpm.config where parent_table = 'public.rg217a'::regclass)
              is distinct from (select oid from s217.delta_a)
          and not exists (select 1 from pg_class c join s217.delta_a d on c.oid = d.oid),
          'A: the delta is re-minted with the key as it is now (kk, n), and the one minted for k is gone');
select is((select array_agg(t.tgname::text order by t.tgname) from pg_trigger t join pg_inherits i on i.inhrelid = t.tgrelid
            where i.inhparent = 'public.rg217a'::regclass and t.tgname like 'pgpm\_regrain\_%'),
          array['pgpm_regrain_capture', 'pgpm_regrain_truncate_guard'],
          'A: the source carries the capture trigger and the TRUNCATE refusal again, and no other child does');

select lives_ok($$update public.rg217a set payload = 'late' where n = 20$$,
                'A: after that tick an UPDATE into the regraining range succeeds');
select lives_ok($$delete from public.rg217a where n = 120$$,
                'A: and so does a DELETE');
select lives_ok($$insert into public.rg217a values (5000, 130, 'ins')$$,
                'A: and an INSERT');

do $$ declare v text; begin for i in 1..30 loop call pgpm.maintain('public.rg217a', v); end loop; end $$;

select is((select string_agg(distinct method, ' | ') from pgpm.log
            where parent_table = 'public.rg217a'::regclass and action = 'skip_regrain'),
          null, 'A: no auto-regrain tick fails after the key-column rename');
select ok(s217.swapped('rg217a', '300'), 'A: the regrain swaps and no coarse partition is left');
select results_eq($$select kk, n, payload from public.rg217a where n < 300 order by n, kk$$,
                  $$select * from (select g::bigint + 1000, g::bigint,
                                          case g when 10 then 'early' when 20 then 'late' else 'a' || g end
                                     from generate_series(1, 200) g where g <> 120
                                   union all select 5000, 130, 'ins') x order by 2, 1$$,
                  'A: the table holds the source''s rows with both UPDATEs, the DELETE and the INSERT honoured');

-- ---------------------------------------------------------------------------------------------------
-- Part B: a key column widened mid-regrain (int to bigint).
-- ---------------------------------------------------------------------------------------------------
create table public.rg217b (k int, n bigint, payload text, primary key (k, n));
insert into public.rg217b select g + 1000, g, 'b' || g from generate_series(1, 230) g;
call pgpm.transmute('public.rg217b', 'n', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rg217b');
insert into public.rg217b values (1450, 450, 'frontier');
select pgpm.set_regrain('public.rg217b', '50');
call pgpm.maintain('public.rg217b');   -- prepare
call pgpm.maintain('public.rg217b');   -- copies [0, 50)

alter table public.rg217b alter column k type bigint;
select ok(s217.delta_cols('rg217b') = 'k integer, n bigint'
          and (select format_type(atttypid, atttypmod) from pg_attribute
                where attrelid = 'public.rg217b'::regclass and attname = 'k') = 'bigint',
          'LIVENESS: (B) the parent''s key column k is bigint now and the delta minted at prepare still holds it as integer');
select throws_ok($$insert into public.rg217b values (3000000000, 20, 'early wide')$$, '22003', null,
                 'B: until the next tick, a key the delta minted as integer cannot hold is refused (it raises)');

call pgpm.maintain('public.rg217b');   -- the tick that meets the widening

select ok(s217.delta_cols('rg217b') = 'k bigint, n bigint'
          and (select count(*) from pgpm.log where parent_table = 'public.rg217b'::regclass and action = 'regrain_restart') = 1,
          'B: that tick restarts the run once and re-mints the delta with k as bigint');
select lives_ok($$insert into public.rg217b values (3000000000, 20, 'wide'), (3000000001, 160, 'wide2')$$,
                'B: after it, an INSERT of keys past 2^31 into the regraining range succeeds');
delete from public.rg217b where k = 1030 and n = 30;

do $$ declare v text; begin for i in 1..30 loop call pgpm.maintain('public.rg217b', v); end loop; end $$;

select ok(s217.swapped('rg217b', '300'), 'B: the regrain swaps and no coarse partition is left');
select results_eq($$select k, n, payload from public.rg217b where n < 300 order by n, k$$,
                  $$select * from (select g::bigint + 1000, g::bigint, 'b' || g from generate_series(1, 230) g where g <> 30
                                   union all values (3000000000::bigint, 20::bigint, 'wide'), (3000000001, 160, 'wide2')) x
                    order by 2, 1$$,
                  'B: the table holds the source''s rows, both wide keys included and the DELETE honoured');

-- ---------------------------------------------------------------------------------------------------
-- Part C (control): a composite key in an order other than the columns', no DDL.
-- ---------------------------------------------------------------------------------------------------
create table public.rg217c (n bigint, payload text, k int, primary key (k, n));
insert into public.rg217c select g, 'c' || g, g + 1000 from generate_series(1, 210) g;
call pgpm.transmute('public.rg217c', 'n', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.rg217c');
insert into public.rg217c values (450, 'frontier', 1450);
select pgpm.set_regrain('public.rg217c', '50');
call pgpm.maintain('public.rg217c');   -- prepare
call pgpm.maintain('public.rg217c');   -- copies [0, 50)
update public.rg217c set payload = 'moved' where n = 15;   -- captured, below the cursor
create table s217.delta_c as select regrain_delta_oid as oid from pgpm.config where parent_table = 'public.rg217c'::regclass;
do $$ declare v text; begin for i in 1..30 loop call pgpm.maintain('public.rg217c', v); end loop; end $$;

select ok(not exists (select 1 from pgpm.log where parent_table = 'public.rg217c'::regclass and action = 'regrain_restart')
          and exists (select 1 from pgpm.log where parent_table = 'public.rg217c'::regclass and action = 'regrain_reconcile')
          and (select regrain_delta_oid from pgpm.config where parent_table = 'public.rg217c'::regclass) = (select oid from s217.delta_c)
          and s217.swapped('rg217c', '300')
          and (select payload from public.rg217c where n = 15) = 'moved',
          'C: with no DDL the run reconciles the captured UPDATE, swaps, never restarts and never re-mints the delta');

select * from finish();
