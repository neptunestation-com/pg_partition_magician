-- untransmute hands back exactly the parent's privileges, the OWNER's included (issue #875 bullet 2, review
-- pass 8 F1-01 and F9-01).
--
-- untransmute resets the restored table's ACL (the monolith's conversion-time copy) before replaying the
-- parent's grants. Its own reset revoked from the grantees that ACL names and never from the owner, so on a
-- monolith with the NULL ACL of a table no grant was ever made on it revoked nobody, and the first replayed
-- GRANT materialised the owner's implicit everything: a privilege the owner had revoked from itself on the
-- managed table came back on the restored one. untransmute now resets through pgpm._acl_reset, the reset
-- transmute's carry uses (#838), which takes the owner's own privileges too.
--
-- ASYMMETRIC FIXTURE. Both tables are owned by t255_owner, a role that is not a superuser, so
-- has_table_privilege reads its ACL. (A) t255s.na has the NULL ACL at the conversion (its schema has no
-- default privileges), and on the managed table the owner revokes its own TRUNCATE and DELETE, keeps the rest,
-- and t255_kept is granted SELECT. (B) t255s.ex has an explicit ACL at the conversion (t255_kept holds INSERT
-- and UPDATE), and on the managed table the owner revokes its own UPDATE, t255_kept loses INSERT and gains
-- SELECT (v). So each restored ACL differs from its monolith's, and an extra privilege and a missing one
-- cannot cancel. WITNESSES: each monolith's ACL is asserted before the reverse, the parent's state is
-- asserted, and each reverse is asserted to have restored the table with its rows.
create extension if not exists pgtap;
select plan(14);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't255_owner') then create role t255_owner; end if;
  if not exists (select 1 from pg_roles where rolname = 't255_kept')  then create role t255_kept;  end if;
end $$;

-- the effective ACL of a relation and its columns as text (a NULL relacl read as the owner's default)
create function pg_temp.acl255(p regclass) returns text[] language sql stable as $$
  select array_agg(e order by e) from (
    select pg_get_userbyid(a.grantee) || ':' || a.privilege_type || case when a.is_grantable then '*' else '' end
           || '/' || pg_get_userbyid(a.grantor) as e
      from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a where c.oid = p
    union all
    select att.attname || '/' || pg_get_userbyid(a.grantee) || ':' || a.privilege_type
           || case when a.is_grantable then '*' else '' end || '/' || pg_get_userbyid(a.grantor)
      from pg_attribute att, aclexplode(att.attacl) a
     where att.attrelid = p and att.attnum > 0 and not att.attisdropped and att.attacl is not null) s
$$;
create function pg_temp.monolith255(p regclass) returns regclass language sql stable as $$
  select monolith_oid::regclass from pgpm.config where parent_table = p $$;

create schema t255s;   -- no default privileges here, so a table is born with the NULL ACL
create table t255s.na (id bigint primary key, v int);
create table t255s.ex (id bigint primary key, v int);
insert into t255s.na select g, g from generate_series(1, 7) g;
insert into t255s.ex select g, g * 2 from generate_series(1, 4) g;
alter table t255s.na owner to t255_owner;
alter table t255s.ex owner to t255_owner;
grant insert, update on t255s.ex to t255_kept;

call pgpm.transmute('t255s.na', 'id', 100::bigint, p_obtain => 2);
call pgpm.transmute('t255s.ex', 'id', 100::bigint, p_obtain => 2);

-- ================= (A) a monolith at the NULL default =================
select ok((select relacl is null from pg_class where oid = pg_temp.monolith255('t255s.na')),
  'A LIVENESS: the monolith untransmute will restore has the NULL (owner-implicit) ACL');
revoke truncate, delete on t255s.na from t255_owner;
grant select on t255s.na to t255_kept;
create temp table parent255na as select pg_temp.acl255('t255s.na') as acl;
select ok(not has_table_privilege('t255_owner', 't255s.na', 'truncate')
          and not has_table_privilege('t255_owner', 't255s.na', 'delete')
          and has_table_privilege('t255_owner', 't255s.na', 'select')
          and has_table_privilege('t255_kept', 't255s.na', 'select'),
  'A LIVENESS: on the managed table the owner holds no TRUNCATE or DELETE, keeps SELECT, and t255_kept holds SELECT');
select is(pgpm.untransmute('t255s.na')::text, 't255s.na', 'A LIVENESS: untransmute restored t255s.na');
select is((select relkind::text || ' ' || (select string_agg(id::text, ',' order by id) from t255s.na)
             from pg_class where oid = 't255s.na'::regclass),
  'r 1,2,3,4,5,6,7', 'A LIVENESS: t255s.na is an ordinary table again, holding rows 1 to 7');
select is(pg_temp.acl255('t255s.na'), (select acl from parent255na),
  'A: the restored table holds exactly the parent''s privileges, the owner''s included');
select ok(not has_table_privilege('t255_owner', 't255s.na', 'truncate')
          and not has_table_privilege('t255_owner', 't255s.na', 'delete'),
  'A: the owner does not get back the TRUNCATE and DELETE it revoked from itself on the managed table');
select ok(has_table_privilege('t255_owner', 't255s.na', 'insert')
          and has_table_privilege('t255_kept', 't255s.na', 'select'),
  'A: the owner keeps the privileges it did not revoke, and t255_kept its SELECT');

-- ================= (B) a monolith with an explicit ACL =================
select ok((select acl from (select pg_temp.acl255(pg_temp.monolith255('t255s.ex')) as acl) m)
            @> array['t255_kept:INSERT/t255_owner', 't255_kept:UPDATE/t255_owner', 't255_owner:UPDATE/t255_owner'],
  'B LIVENESS: the monolith carries the conversion-time grants: t255_kept INSERT and UPDATE, the owner UPDATE');
revoke update on t255s.ex from t255_owner;
revoke insert on t255s.ex from t255_kept;
grant select (v) on t255s.ex to t255_kept;
create temp table parent255ex as select pg_temp.acl255('t255s.ex') as acl;
select ok(not has_table_privilege('t255_owner', 't255s.ex', 'update')
          and has_column_privilege('t255_kept', 't255s.ex', 'v', 'select'),
  'B LIVENESS: on the managed table the owner holds no UPDATE, and t255_kept holds SELECT (v)');
select is(pgpm.untransmute('t255s.ex')::text, 't255s.ex', 'B LIVENESS: untransmute restored t255s.ex');
select is((select relkind::text || ' ' || (select string_agg(id::text, ',' order by id) from t255s.ex)
             from pg_class where oid = 't255s.ex'::regclass),
  'r 1,2,3,4', 'B LIVENESS: t255s.ex is an ordinary table again, holding rows 1 to 4');
select is(pg_temp.acl255('t255s.ex'), (select acl from parent255ex),
  'B: the restored table holds exactly the parent''s privileges');
select ok(not has_table_privilege('t255_owner', 't255s.ex', 'update')
          and not has_table_privilege('t255_kept', 't255s.ex', 'insert'),
  'B: neither the owner''s UPDATE nor t255_kept''s INSERT, both revoked on the managed table, comes back');
select ok(has_table_privilege('t255_kept', 't255s.ex', 'update')
          and has_column_privilege('t255_kept', 't255s.ex', 'v', 'select')
          and not has_column_privilege('t255_kept', 't255s.ex', 'id', 'select'),
  'B: t255_kept keeps UPDATE and SELECT on v, and has none on id');

select * from finish();
