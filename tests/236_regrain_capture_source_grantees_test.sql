-- A role granted DML on the regraining partition itself can write it mid-regrain (issue #843).
--
-- The capture trigger inserts into the delta with the WRITER's privileges (pgpm has no SECURITY DEFINER),
-- so every role that can write the source needs INSERT on the delta. _regrain_capture_grant gave it to the
-- grantees of DML on the PARENT only. PostgreSQL lets a role granted UPDATE or DELETE directly on a
-- partition write it with no grant on the parent, and such a role got 42501 'permission denied for table
-- <rel>_pgpm_regrain_delta' on every write into the source for the life of the regrain. The contract: the
-- delta is granted INSERT to every grantee of INSERT, UPDATE or DELETE on the parent or on the source,
-- table- or column-level, from the prepare tick on and, for a grant made mid-regrain, from the next tick;
-- their writes are captured and survive the swap; and nobody else is granted.
--
-- Fixture, asymmetric on purpose: one monolith [0, 300) holding ids 1..200, auto-regrained to 50, with
--   g236_upd  UPDATE on the partition (granted before the prepare tick): updates ids 10 (already copied)
--             and 120 (not yet copied);
--   g236_col  column-level UPDATE (payload) on the partition, before the prepare: updates id 40;
--   g236_del  DELETE on the partition, granted AFTER the prepare tick: deletes ids 20 and 30;
--   g236_ro   SELECT only on the partition: must NOT be granted anything on the delta.
-- Three writers, five rows touched, two of them gone, so a lost write and a resurrected one cannot cancel.
-- bench/regrain_capture_source_grantees.sh runs this file against the mutant that grants the parent's
-- grantees only again (regrain_capture_grant_parent_only), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(11);

do $$ begin
  create role g236_upd; exception when duplicate_object then null; end $$;
do $$ begin
  create role g236_col; exception when duplicate_object then null; end $$;
do $$ begin
  create role g236_del; exception when duplicate_object then null; end $$;
do $$ begin
  create role g236_ro; exception when duplicate_object then null; end $$;
grant usage on schema public to g236_upd, g236_col, g236_del, g236_ro;

create table public.g236 (id bigint primary key, payload text);
insert into public.g236 select g, 'a' || g from generate_series(1, 200) g;
call pgpm.transmute('public.g236', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.g236');
insert into public.g236 values (450, 'frontier');   -- the monolith freezes
grant select, update on public.g236_p0000000000000000000_to_0000000000000000300 to g236_upd;
grant select (id, payload), update (payload) on public.g236_p0000000000000000000_to_0000000000000000300 to g236_col;
grant select on public.g236_p0000000000000000000_to_0000000000000000300 to g236_ro;
select pgpm.set_regrain('public.g236', '50');
call pgpm.maintain('public.g236');   -- prepare: capture on the source, the delta minted and granted
grant select, delete on public.g236_p0000000000000000000_to_0000000000000000300 to g236_del;   -- mid-regrain
call pgpm.maintain('public.g236');   -- copies [0, 50); grants re-synced

select ok(exists (select 1 from pg_trigger where tgname = 'pgpm_regrain_capture'
                   and tgrelid = 'public.g236_p0000000000000000000_to_0000000000000000300'::regclass)
          and exists (select 1 from pgpm.log where parent_table = 'public.g236'::regclass
                       and action = 'regrain_copy' and lo = '0' and hi = '50' and rows = 49),
          'LIVENESS: auto-regrain is mid-flight, capture on the source and [0, 50) already copied');
select ok(not has_table_privilege('g236_upd', 'public.g236', 'UPDATE')
          and not has_table_privilege('g236_del', 'public.g236', 'DELETE')
          and not has_column_privilege('g236_col', 'public.g236', 'payload', 'UPDATE'),
          'LIVENESS: none of the writers holds any privilege on the parent, only on the partition');

select is((select array_agg(pg_get_userbyid(a.grantee)::text order by pg_get_userbyid(a.grantee))
             from pg_class c cross join lateral aclexplode(c.relacl) a
            where c.oid = 'public.g236_pgpm_regrain_delta'::regclass and a.privilege_type = 'INSERT'
              and a.grantee <> c.relowner),
          array['g236_col', 'g236_del', 'g236_upd'],
          'the delta grants INSERT to exactly the source''s three writers (the one granted mid-regrain included), and not to its reader');

set role g236_upd;
select lives_ok($$ update public.g236_p0000000000000000000_to_0000000000000000300 set payload = 'upd-10' where id = 10 $$,
                'a role granted UPDATE on the partition updates an already-copied row mid-regrain');
select lives_ok($$ update public.g236_p0000000000000000000_to_0000000000000000300 set payload = 'upd-120' where id = 120 $$,
                'and a not-yet-copied one');
reset role;
set role g236_col;
select lives_ok($$ update public.g236_p0000000000000000000_to_0000000000000000300 set payload = 'col-40' where id = 40 $$,
                'a role granted column-level UPDATE on the partition updates a row mid-regrain');
reset role;
set role g236_del;
select lives_ok($$ delete from public.g236_p0000000000000000000_to_0000000000000000300 where id in (20, 30) $$,
                'a role granted DELETE on the partition after the prepare tick deletes two rows mid-regrain');
reset role;
set role g236_ro;
select throws_ok($$ update public.g236_p0000000000000000000_to_0000000000000000300 set payload = 'ro' where id = 50 $$,
                 '42501', 'permission denied for table g236_p0000000000000000000_to_0000000000000000300',
                 'the reader is still refused by PostgreSQL itself, on the partition and not on the delta');
reset role;

select is((select array_agg(id order by pgpm_seq) from public.g236_pgpm_regrain_delta),
          array[10, 10, 120, 120, 40, 40, 20, 30]::bigint[],
          'every one of those writes was captured, in order (an UPDATE records its old and new key)');

do $$ declare v_st text; begin
  for i in 1..20 loop
    call pgpm.maintain('public.g236', v_st);
    exit when v_st like '%regrain=swapped:%';
  end loop;
end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.g236'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          'LIVENESS: the regrain swapped the monolith into fine children');
select is((select array_agg(id || ':' || payload order by id) from public.g236
            where id in (9, 10, 11, 19, 20, 21, 30, 40, 120, 199) or id < 0),
          array['9:a9', '10:upd-10', '11:a11', '19:a19', '21:a21', '40:col-40', '120:upd-120', '199:a199'],
          'after the swap each write is in the table: the three updates hold, the two deleted rows are gone, their neighbours are untouched');

select * from finish();
