-- transmute's parent ends with exactly the table's grants, not the table's plus its creator's default
-- privileges (issue #838, review pass 7 F6-08).
--
-- The parent is a new table, created by the transmuting role, so it is born with that role's ALTER DEFAULT
-- PRIVILEGES (on Supabase, SELECT and more to anon and authenticated in public). The grant carry (7b) only
-- ever GRANTed the table's privileges onto it, so a privilege the operator had REVOKEd on the table, or
-- never granted, was held on the parent every query names. The carry now resets the parent's ACL before
-- replaying the table's (pgpm._acl_carry_ddl, shared with pgpm_hypertable's swap).
--
-- ASYMMETRIC FIXTURE. The default privileges give t235_gone SELECT and UPDATE and t235_dflt DELETE on every
-- new table here. Table acl235 is created under them and then has them taken back: t235_gone loses SELECT
-- and UPDATE but is granted SELECT on ONE column (v, not id), t235_dflt loses DELETE, t235_kept is granted
-- SELECT, t235_opt INSERT with grant option, and the owner revokes its own TRUNCATE. So the expected ACL is
-- neither empty nor the defaults, an extra privilege and a missing one cannot cancel, and every grantee's
-- set differs from every other's. Table acl235n is created BEFORE the default privileges, so its ACL is
-- NULL (the owner's implicit everything, nothing for anyone else): its parent must carry the owner's full
-- privileges and nothing else, which a reset that only revokes would get wrong. Table acl235c lives in a
-- schema with no default privileges, so its parent is born with a NULL ACL too, and its owner has revoked
-- its own TRUNCATE: a reset that revokes only from the roles a parent's ACL names finds nobody there, and
-- the first replayed GRANT would materialise the owner's implicit everything, TRUNCATE included.
-- WITNESSES: the default privileges are shown to apply to a table created now (as the parent was), each
-- source ACL is asserted before the conversion, and each conversion is asserted to have happened.
create extension if not exists pgtap;

select plan(18);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't235_gone') then create role t235_gone; end if;
  if not exists (select 1 from pg_roles where rolname = 't235_dflt') then create role t235_dflt; end if;
  if not exists (select 1 from pg_roles where rolname = 't235_kept') then create role t235_kept; end if;
  if not exists (select 1 from pg_roles where rolname = 't235_opt')  then create role t235_opt;  end if;
end $$;

-- the effective ACL of a relation (a NULL relacl read as the owner's default) and of its columns, as text
create function pg_temp.acl235(p regclass) returns text[] language sql stable as $$
  select array_agg(e order by e) from (
    select pg_get_userbyid(a.grantee) || ':' || a.privilege_type || case when a.is_grantable then '*' else '' end as e
      from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a where c.oid = p
    union all
    select att.attname || '/' || pg_get_userbyid(a.grantee) || ':' || a.privilege_type
           || case when a.is_grantable then '*' else '' end
      from pg_attribute att, aclexplode(att.attacl) a
     where att.attrelid = p and att.attnum > 0 and not att.attisdropped and att.attacl is not null) s
$$;

create table public.acl235n (id bigint primary key, v int);
insert into public.acl235n select g, g from generate_series(1, 5) g;

alter default privileges in schema public grant select, update on tables to t235_gone;
alter default privileges in schema public grant delete on tables to t235_dflt;

create table public.acl235 (id bigint primary key, v int);
insert into public.acl235 select g, g * 10 from generate_series(1, 5) g;
revoke select, update on public.acl235 from t235_gone;
revoke delete on public.acl235 from t235_dflt;
grant select (v) on public.acl235 to t235_gone;
grant select on public.acl235 to t235_kept;
grant insert on public.acl235 to t235_opt with grant option;
revoke truncate on public.acl235 from postgres;

create schema t235s;
create table t235s.acl235c (id bigint primary key, v int);
insert into t235s.acl235c select g, g from generate_series(1, 3) g;
grant select on t235s.acl235c to t235_kept;
revoke truncate on t235s.acl235c from postgres;

create table public.acl235_probe (id bigint);
select ok(has_table_privilege('t235_gone', 'public.acl235_probe', 'select')
          and has_table_privilege('t235_dflt', 'public.acl235_probe', 'delete'),
  'LIVENESS: a table this role creates now is born granting t235_gone SELECT and t235_dflt DELETE');

create table public.acl235_before as
  select 'acl235'::text as t, pg_temp.acl235('public.acl235') as acl
  union all select 'acl235n', pg_temp.acl235('public.acl235n')
  union all select 'acl235c', pg_temp.acl235('t235s.acl235c');
-- by element, not as one literal: the owner's privilege list grows with the server version (MAINTAIN, 17)
select ok((select acl from public.acl235_before where t = 'acl235')
            @> array['postgres:SELECT', 't235_kept:SELECT', 't235_opt:INSERT*', 'v/t235_gone:SELECT']
          and not (select acl from public.acl235_before where t = 'acl235')
            && array['t235_gone:SELECT', 't235_gone:UPDATE', 't235_dflt:DELETE', 'postgres:TRUNCATE'],
  'LIVENESS: acl235 holds its own grants: the defaults taken back, one column grant, no owner TRUNCATE');
select is((select relacl from pg_class where oid = 'public.acl235n'::regclass), null::aclitem[],
  'LIVENESS: acl235n, created before the default privileges, has the NULL ACL of the owner''s implicit default');

call pgpm.transmute('public.acl235', 'id', 100::bigint, p_obtain => 2);
call pgpm.transmute('public.acl235n', 'id', 100::bigint, p_obtain => 2);
call pgpm.transmute('t235s.acl235c', 'id', 100::bigint, p_obtain => 2);

select is((select relkind::text from pg_class where oid = 'public.acl235'::regclass), 'p',
  'LIVENESS: acl235 was converted into a partitioned parent');
select is((select relkind::text from pg_class where oid = 'public.acl235n'::regclass), 'p',
  'LIVENESS: acl235n was converted into a partitioned parent');

-- Part A: a table with an explicit ACL
select is(pg_temp.acl235('public.acl235'), (select acl from public.acl235_before where t = 'acl235'),
  'A: the parent holds exactly the table''s table and column grants, every grantee and grant option');
select ok(not has_table_privilege('t235_gone', 'public.acl235', 'select')
          and not has_table_privilege('t235_gone', 'public.acl235', 'update'),
  'A: t235_gone does not hold the SELECT and UPDATE revoked on the table');
select ok(has_column_privilege('t235_gone', 'public.acl235', 'v', 'select')
          and not has_column_privilege('t235_gone', 'public.acl235', 'id', 'select'),
  'A: t235_gone holds the SELECT it was granted on v, and not on id');
select ok(not has_table_privilege('t235_dflt', 'public.acl235', 'delete'),
  'A: t235_dflt does not hold the DELETE revoked on the table');
select ok(has_table_privilege('t235_kept', 'public.acl235', 'select')
          and has_table_privilege('t235_opt', 'public.acl235', 'insert with grant option'),
  'A: the grants the table had are carried, the grant option included');
select ok(not exists (select 1 from pg_class c, aclexplode(c.relacl) a
                       where c.oid = 'public.acl235'::regclass and a.grantee = c.relowner
                         and a.privilege_type = 'TRUNCATE'),
  'A: the owner does not hold the TRUNCATE it revoked from itself on the table');
set role t235_gone;
select is((select array_agg(v order by v) from public.acl235), array[10, 20, 30, 40, 50],
  'A: as t235_gone, the granted column reads through the parent');
select throws_ok('select id from public.acl235', '42501', null,
  'A: as t235_gone, the revoked table-level SELECT is refused on the parent');
reset role;

-- Part B: a table at the owner's implicit default
select is(pg_temp.acl235('public.acl235n'), (select acl from public.acl235_before where t = 'acl235n'),
  'B: the parent holds the owner''s full privileges and nothing else, as the table did');
select ok(not has_table_privilege('t235_gone', 'public.acl235n', 'select')
          and not has_table_privilege('t235_dflt', 'public.acl235n', 'delete'),
  'B: no role holds on the parent what the default privileges gave it and the table never had');

-- Part C: a parent born with a NULL ACL, from a table whose owner revoked one of its own privileges
select is((select relkind::text from pg_class where oid = 't235s.acl235c'::regclass), 'p',
  'LIVENESS: acl235c was converted into a partitioned parent');
select is(pg_temp.acl235('t235s.acl235c'), (select acl from public.acl235_before where t = 'acl235c'),
  'C: the parent holds exactly the table''s grants');
select ok(not exists (select 1 from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                       where c.oid = 't235s.acl235c'::regclass and a.grantee = c.relowner
                         and a.privilege_type = 'TRUNCATE')
          and has_table_privilege('t235_kept', 't235s.acl235c', 'select'),
  'C: the owner does not hold the TRUNCATE it revoked from itself, and t235_kept keeps its SELECT');

select * from finish();
