-- A table whose reused key has a column named pgpm_seq regrains like any other (issue #1074).
--
-- THE DEFECT. _regrain_capture_install minted the delta as `create table <delta> as select <key columns>
-- from <parent>` and then added its own ordering column under the fixed name pgpm_seq. When the key already
-- put a pgpm_seq there, the prepare tick died 42701 (column already exists) on every call, so regrain(),
-- regrain_history() and auto-regrain could never make progress on that table, while transmute had accepted
-- it and no document reserved the name. And every reader of the delta told the key from the ordering column
-- by that name (the reconcile, the drift check), so a delta that could be minted would still have dropped
-- the key's own pgpm_seq from the key.
--
-- THE CONTRACT. The ordering column is minted under a name no key column holds, and every reader finds it
-- as the delta's identity column, never by its name. So the prepare lives, the capture records every change
-- by the WHOLE key, the reconcile applies those changes into the fine children, the drift check reads the
-- key it was minted for (no restart loop), and the swap completes with every change in place.
--
-- ASYMMETRIC FIXTURE. Two parents, each regrained from a frozen monolith [0, 3000) to a step of 100, with
-- sub-range [0, 100) copied BEFORE the writes, so a write there reaches the fine child only through capture
-- and reconcile.
--   ps295, key (id, pgpm_seq), 250 rows (g*10, g) plus a twin (20, 1000) sharing id 20: one UPDATE of
--          (20, 2), one INSERT (25, 77), one DELETE (30, 3) and one key change (40, 4) -> (40, 400). The twin
--          has no captured change. A reconcile deletes the fine child's rows matching a captured key and
--          rereads the source's, so one keyed on id alone ends in the same TABLE as one keyed on the whole key
--          (it deletes the twin and rereads it unchanged): the rows alone cannot tell them apart (#1174). What
--          tells them apart is whether the reconcile wrote the twin at all, so each row of id 20 in the fine
--          child is read by its xmin after the copy and again after the swap: the reconcile rewrote (20, 2),
--          the witness that it ran over id 20, and left the twin's row as the copy wrote it.
--   pq295, key (id, pgpm_seq, pgpm_seq_1), 120 rows: one DELETE (10, 1, -1) and one UPDATE of (60, 6, -6),
--          so the ordering column's name must step past a second taken name as well.
create extension if not exists pgtap;
select plan(21);

create schema pgpm_test295;

-- regrain the parent's monolith [0, 3000) to a step of 100 until its first sub-range is copied
create function pgpm_test295.to_copied(p_parent regclass) returns void language plpgsql as $f$
declare s text; n int := 0; v_cur text; v_child name;
begin
  select child_name into v_child from pgpm.part where parent_table = p_parent and lo = '0' and attached;
  loop
    select regrain_cursor into v_cur from pgpm.config where parent_table = p_parent;
    exit when v_cur is not null and v_cur::numeric >= 100;
    s := pgpm.regrain_step(p_parent, v_child, '100', 50);
    n := n + 1; if n > 20 then raise exception 'no copy (last %)', s; end if;
  end loop;
end $f$;
-- the keys the parent's recorded delta holds, rendered by p_expr over its row d, in order; 'no delta' when
-- none is recorded (so a prepare that died is reported here rather than aborting the file)
create function pgpm_test295.delta_keys(p_parent regclass, p_expr text) returns text language plpgsql as $f$
declare v regclass; r text;
begin
  select c.oid::regclass into v from pgpm.config f join pg_class c on c.oid = f.regrain_delta_oid
   where f.parent_table = p_parent;
  if v is null then return 'no delta'; end if;
  execute format('select string_agg(%1$s, '','' order by %1$s) from %2$s d', p_expr, v) into r;
  return r;
end $f$;
-- the xmin of the row (p_id, p_seq) in the parent's fine child [0, 100), the relation pgpm.part records for it
-- (detached before the swap, attached after); null when it holds no such row
create function pgpm_test295.fine_xmin(p_parent regclass, p_id bigint, p_seq bigint) returns text language plpgsql as $f$
declare v regclass; r text;
begin
  select child_oid::regclass into v from pgpm.part where parent_table = p_parent and lo = '0' and hi = '100';
  if v is null then return null; end if;
  execute format('select xmin::text from %s where id = $1 and pgpm_seq = $2', v) into r using p_id, p_seq;
  return r;
end $f$;
create function pgpm_test295.to_swap(p_parent regclass) returns text language plpgsql as $f$
declare s text; n int := 0; v_child name;
begin
  select child_name into v_child from pgpm.part where parent_table = p_parent and lo = '0' and attached;
  loop
    s := pgpm.regrain_step(p_parent, v_child, '100', 50);
    exit when s like 'swapped:%';
    n := n + 1; if n > 500 then raise exception 'no swap (last %)', s; end if;
  end loop;
  return s;
exception when others then
  return format('died: %s: %s', sqlstate, sqlerrm);   -- reported by the assertion, not an aborted file
end $f$;

-- ======================= A. key (id, pgpm_seq) =======================
create table public.ps295 (id bigint, pgpm_seq bigint, payload text, primary key (id, pgpm_seq));
insert into public.ps295 select g * 10, g, 'x' from generate_series(1, 250) g;
insert into public.ps295 values (20, 1000, 'twin');
call pgpm.transmute('public.ps295', 'id', 1000);
insert into public.ps295 values (20000, 1, 'frontier');

select ok(exists (select 1 from pgpm.part where parent_table = 'public.ps295'::regclass
                    and lo = '0' and hi = '3000' and attached),
  'setup: ps295 has the frozen monolith [0, 3000) to regrain');

select lives_ok($$ select pgpm.regrain_step('public.ps295',
                     (select child_name from pgpm.part where parent_table = 'public.ps295'::regclass and lo = '0'),
                     '100', 50) $$,
  'the prepare tick of a table whose key has a column named pgpm_seq lives');
select is(
  (select count(*)::int from pgpm.config c join pg_class d on d.oid = c.regrain_delta_oid
    where c.parent_table = 'public.ps295'::regclass),
  1, 'and it minted and recorded change capture''s delta');
select is(
  pgpm._regrain_capture_drift('public.ps295',
    (select indexrelid from pg_index where indrelid = 'public.ps295'::regclass and indisprimary)),
  null, 'the drift check reads the delta as minted for the key (id, pgpm_seq), so the next tick does not restart the run');

select lives_ok($$ select pgpm_test295.to_copied('public.ps295') $$, 'setup: sub-range [0, 100) is copied');
select is((select count(*)::int from pgpm.part where parent_table = 'public.ps295'::regclass and not attached and lo = '0' and hi = '100'),
  1, 'witness: the fine child [0, 100) exists, detached, before the writes');
-- each row of id 20 as the copy wrote it into the fine child ('' when the copy did not)
select coalesce(pgpm_test295.fine_xmin('public.ps295', 20, 1000), '') as twin_x0,
       coalesce(pgpm_test295.fine_xmin('public.ps295', 20, 2), '') as upd_x0 \gset

update public.ps295 set payload = 'edit' where id = 20 and pgpm_seq = 2;
insert into public.ps295 values (25, 77, 'ins');
delete from public.ps295 where id = 30 and pgpm_seq = 3;
update public.ps295 set pgpm_seq = 400 where id = 40 and pgpm_seq = 4;

select is(
  pgpm_test295.delta_keys('public.ps295', $$format('%s:%s', d.id, d.pgpm_seq)$$),
  '20:2,20:2,25:77,30:3,40:4,40:400',
  'the capture recorded every change by the whole key, the key''s own pgpm_seq included');

select alike(pgpm_test295.to_swap('public.ps295'), 'swapped:%', 'the regrain of ps295 runs to its swap');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.ps295'::regclass and action = 'regrain_reconcile'),
  'witness: the captured changes went through the reconcile');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.ps295'::regclass and action = 'regrain_restart'),
  'and the run was never restarted for a key drift it did not have');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.ps295'::regclass and lo = '0' and hi = '100' and attached)
          and not exists (select 1 from pgpm.part where parent_table = 'public.ps295'::regclass and lo = '0' and hi = '3000'),
  'witness: the fine child [0, 100) is attached and the monolith is gone');

select set_eq(
  $$ select id, pgpm_seq, payload from public.ps295 where id < 100 $$,
  $$ values (10::bigint, 1::bigint, 'x'::text), (20, 2, 'edit'), (20, 1000, 'twin'), (25, 77, 'ins'),
            (40, 400, 'x'), (50, 5, 'x'), (60, 6, 'x'), (70, 7, 'x'), (80, 8, 'x'), (90, 9, 'x') $$,
  'after the swap [0, 100) holds the update, the insert and the key change, not the deleted row, and the twin untouched');
select ok(:'upd_x0' <> '' and pgpm_test295.fine_xmin('public.ps295', 20, 2) is distinct from :'upd_x0',
  'LIVENESS: the reconcile rewrote (20, 2) in the fine child: its row there is no longer the one the copy wrote');
select is(pgpm_test295.fine_xmin('public.ps295', 20, 1000), coalesce(nullif(:'twin_x0', ''), 'the copy wrote no twin'),
  'and it left the twin (20, 1000) in the fine child as the copy wrote it: the reconcile keys on the whole key, never on id alone');
select is(
  (select count(*)::int from public.ps295 where id >= 100 and id < 3000), 241,
  'and the rest of the history is intact (ids 100 to 2500)');

-- ======================= B. key (id, pgpm_seq, pgpm_seq_1) =======================
create table public.pq295 (id bigint, pgpm_seq bigint, pgpm_seq_1 bigint, payload text,
                           primary key (id, pgpm_seq, pgpm_seq_1));
insert into public.pq295 select g * 10, g, -g, 'y' from generate_series(1, 120) g;
call pgpm.transmute('public.pq295', 'id', 1000);
insert into public.pq295 values (20000, 1, 1, 'frontier');

select lives_ok($$ select pgpm_test295.to_copied('public.pq295') $$,
  'the prepare and copy of a table whose key holds pgpm_seq and pgpm_seq_1 live');
update public.pq295 set payload = 'e' where id = 60;
delete from public.pq295 where id = 10;
select is(
  pgpm_test295.delta_keys('public.pq295', $$format('%s:%s:%s', d.id, d.pgpm_seq, d.pgpm_seq_1)$$),
  '10:1:-1,60:6:-6,60:6:-6',
  'the capture recorded both changes by the whole three-column key');
select alike(pgpm_test295.to_swap('public.pq295'), 'swapped:%', 'the regrain of pq295 runs to its swap');
select set_eq(
  $$ select id, pgpm_seq, pgpm_seq_1, payload from public.pq295 where id < 100 $$,
  $$ values (20::bigint, 2::bigint, -2::bigint, 'y'::text), (30, 3, -3, 'y'), (40, 4, -4, 'y'), (50, 5, -5, 'y'),
            (60, 6, -6, 'e'), (70, 7, -7, 'y'), (80, 8, -8, 'y'), (90, 9, -9, 'y') $$,
  'after the swap [0, 100) holds the update and not the deleted row');

-- ======================= C. the control =======================
-- An ordinary key regrains the same way: what the fixtures above add is only the name.
create table public.pc295 (id bigint, seq bigint, payload text, primary key (id, seq));
insert into public.pc295 select g * 10, g, 'z' from generate_series(1, 250) g;
call pgpm.transmute('public.pc295', 'id', 1000);
insert into public.pc295 values (20000, 1, 'frontier');
select lives_ok($$ select pgpm_test295.to_copied('public.pc295') $$, 'control: the twin with key (id, seq) copies');
select alike(pgpm_test295.to_swap('public.pc295'), 'swapped:%', 'control: and swaps');

drop schema pgpm_test295 cascade;
select * from finish();
