-- The OWNERS of the regraining partition and of the parent can write it mid-regrain (issue #906).
--
-- The capture trigger inserted into the delta with the WRITER's privileges, so every role that could write
-- the source needed INSERT on the delta (since #1073 the capture is SECURITY DEFINER and writes as its
-- owner, so the writes below no longer depend on these grants; the grants are still made, and this file
-- checks them by the delta's ACL). _regrain_capture_grant gave it to the
-- roles an ACL of the parent or the source lists (#496, #843), and _own_like_parent gives the delta the
-- parent's owner as it stood at the prepare tick. An owner writes with implicit rights that no ACL lists, so
-- a source owned by anyone else was missed: after ALTER TABLE <parent> OWNER TO <new> (which, as
-- docs/reference.md says, does not reach the partitions) the OLD owner still owns every partition, and every
-- write it made into the regraining source failed 42501 'permission denied for table <rel>_pgpm_regrain_delta'
-- from the prepare tick to the swap. A parent re-owned mid-regrain left its new owner the same way, the delta
-- being owned by the old one. The contract: the delta grants INSERT to the source's owner and the parent's
-- owner too (beside the ACL grantees, and not to the delta's own owner, whose rights are implicit), from the
-- prepare tick on and, for an owner changed mid-regrain, from the next tick; their writes are captured and
-- survive the swap; and nobody else is granted. Since #950 the delta also FOLLOWS the parent's owner (each
-- tick gives it the parent's owner as it is then), so after the parent is re-owned to g262_par it is
-- g262_par's, whose rights are implicit, and the grants go to the other owners.
--
-- Fixture, asymmetric on purpose: one monolith [0, 300) holding ids 1..200, owned by g262_old with its
-- partitions, then the parent re-owned to g262_new (the delta's owner) before auto-regrain to 50 starts:
--   g262_old  owns the source at the prepare tick, holds nothing on the parent: updates ids 10 and 120;
--   g262_src  is given the source by ALTER TABLE ... OWNER TO mid-regrain: deletes ids 20 and 30;
--   g262_par  is given the parent mid-regrain, owns no partition: updates id 40 through the parent;
--   g262_ro   column-level SELECT on the parent: must NOT be granted anything on the delta. Column-level,
--             because a table-level grant on the source or the parent would materialise its ACL with an
--             entry for the owner, which the ACL scan already found: every owner here writes by
--             ownership alone, and the fixture checks that it does.
-- Three writers, five rows touched, two of them gone, so a lost write and a resurrected one cannot cancel.
-- bench/regrain_capture_owner_grant.sh runs this file against the mutant that grants the ACL grantees only
-- again (regrain_capture_grant_acl_only), so it is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(13);

do $$ begin create role g262_old; exception when duplicate_object then null; end $$;
do $$ begin create role g262_new; exception when duplicate_object then null; end $$;
do $$ begin create role g262_src; exception when duplicate_object then null; end $$;
do $$ begin create role g262_par; exception when duplicate_object then null; end $$;
do $$ begin create role g262_ro;  exception when duplicate_object then null; end $$;
grant usage on schema public to g262_old, g262_new, g262_src, g262_par, g262_ro;

create table public.g262 (id bigint primary key, payload text);
insert into public.g262 select g, 'a' || g from generate_series(1, 200) g;
alter table public.g262 owner to g262_old;
call pgpm.transmute('public.g262', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.g262');
insert into public.g262 values (450, 'frontier');   -- the monolith freezes
alter table public.g262 owner to g262_new;           -- documented not to reach the partitions
grant select (id, payload) on public.g262 to g262_ro;

select ok((select pg_get_userbyid(relowner) = 'g262_old' from pg_class
            where oid = 'public.g262_p0000000000000000000_to_0000000000000000300'::regclass)
          and (select pg_get_userbyid(relowner) = 'g262_new' from pg_class where oid = 'public.g262'::regclass)
          and not has_table_privilege('g262_old', 'public.g262', 'UPDATE')
          and has_table_privilege('g262_old', 'public.g262_p0000000000000000000_to_0000000000000000300', 'UPDATE')
          and not exists (select 1 from pg_class c cross join lateral aclexplode(c.relacl) a
                           where c.oid = 'public.g262_p0000000000000000000_to_0000000000000000300'::regclass
                             and a.grantee = 'g262_old'::regrole),
          'LIVENESS: g262_old still owns the monolith after the parent was re-owned, and writes it by ownership alone (no ACL entry, nothing on the parent)');

select pgpm.set_regrain('public.g262', '50');
call pgpm.maintain('public.g262');   -- prepare: capture on the source, the delta minted, owned by g262_new
select ok(exists (select 1 from pg_trigger where tgname = 'pgpm_regrain_capture'
                   and tgrelid = 'public.g262_p0000000000000000000_to_0000000000000000300'::regclass)
          and (select pg_get_userbyid(relowner) = 'g262_new' from pg_class where oid = 'public.g262_pgpm_regrain_delta'::regclass),
          'LIVENESS: the prepare tick put capture on the source and gave the delta the parent''s owner, g262_new');

set role g262_old;
select lives_ok($$ update public.g262_p0000000000000000000_to_0000000000000000300 set payload = 'old-10' where id = 10 $$,
                'the source''s owner updates a row of it from the prepare tick on');
select lives_ok($$ update public.g262_p0000000000000000000_to_0000000000000000300 set payload = 'old-120' where id = 120 $$,
                'and another');
reset role;

call pgpm.maintain('public.g262');   -- copies [0, 50)
alter table public.g262_p0000000000000000000_to_0000000000000000300 owner to g262_src;   -- mid-regrain
alter table public.g262 owner to g262_par;                                              -- mid-regrain
call pgpm.maintain('public.g262');   -- reconciles id 10's capture; grants re-synced
select ok(pgpm._regrain_capture_active('public.g262', 'g262_p0000000000000000000_to_0000000000000000300')
          and (select pg_get_userbyid(relowner) = 'g262_par' from pg_class where oid = 'public.g262_pgpm_regrain_delta'::regclass)
          and not has_table_privilege('g262_src', 'public.g262', 'DELETE')
          and not has_table_privilege('g262_par', 'public.g262_p0000000000000000000_to_0000000000000000300', 'SELECT')
          and (select relacl is null from pg_class where oid = 'public.g262'::regclass)
          and (select relacl is null from pg_class where oid = 'public.g262_p0000000000000000000_to_0000000000000000300'::regclass),
          'LIVENESS: the run is still in flight past both re-owns, the delta follows the parent to g262_par (#950), g262_src holds nothing on the parent nor g262_par on the source, and neither table has an ACL naming its owner');

select is((select array_agg(pg_get_userbyid(a.grantee)::text order by pg_get_userbyid(a.grantee))
             from pg_class c cross join lateral aclexplode(c.relacl) a
            where c.oid = 'public.g262_pgpm_regrain_delta'::regclass and a.privilege_type = 'INSERT'
              and a.grantee <> c.relowner),
          array['g262_old', 'g262_src'],
          'the delta grants INSERT to exactly the two owners that do not own it (g262_src, re-owned mid-regrain, included; g262_par owns it now), not to the reader');

set role g262_src;
select lives_ok($$ delete from public.g262_p0000000000000000000_to_0000000000000000300 where id in (20, 30) $$,
                'the role the source was re-owned to mid-regrain deletes two of its rows from the next tick on');
reset role;
set role g262_par;
select lives_ok($$ update public.g262 set payload = 'par-40' where id = 40 $$,
                'the role the parent was re-owned to mid-regrain updates a row of the source through the parent');
reset role;
set role g262_ro;
select throws_ok($$ update public.g262 set payload = 'ro' where id = 50 $$,
                 '42501', 'permission denied for table g262',
                 'the reader is still refused by PostgreSQL itself, on the parent and not on the delta');
reset role;

select is((select array_agg(id order by pgpm_seq) from public.g262_pgpm_regrain_delta),
          array[120, 120, 20, 30, 40, 40]::bigint[],
          'every one of those writes not yet reconciled was captured, in order (an UPDATE records its old and new key; id 10''s, in the copied [0, 50), has been reconciled already)');

do $$ declare v_st text; begin
  for i in 1..20 loop
    call pgpm.maintain('public.g262', v_st);
    exit when v_st like '%regrain=swapped:%';
  end loop;
end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.g262'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '300'),
          'LIVENESS: the regrain swapped the monolith into fine children');
select is((select array_agg(id || ':' || payload order by id) from public.g262
            where id in (9, 10, 11, 19, 20, 21, 30, 40, 120, 199)),
          array['9:a9', '10:old-10', '11:a11', '19:a19', '21:a21', '40:par-40', '120:old-120', '199:a199'],
          'after the swap each write is in the table: the three updates hold, the two deleted rows are gone, their neighbours are untouched');
select is((select count(*)::int from public.g262), 199,
          'and the table holds the 201 rows less the two deleted');

select * from finish();
