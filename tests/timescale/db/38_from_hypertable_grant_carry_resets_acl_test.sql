-- from_hypertable's migrated table ends with exactly the hypertable's grants, not the hypertable's plus the
-- migrating role's default privileges (issue #838, review pass 7 F6-02, the verifier's rebuilt reproduction).
--
-- from_hypertable_copy builds the copy with CREATE TABLE ... LIKE, as the migrating role, so the copy is
-- born with that role's ALTER DEFAULT PRIVILEGES. The swap's grant carry (#787) only ever GRANTed the
-- hypertable's privileges onto it, so a privilege REVOKEd on the hypertable was held by the swapped copy,
-- and transmute, whose parent is born the same way and was carried the same additive way, held it on the
-- partitioned parent every reader queries. Both carries now reset the new table's ACL before replaying
-- the source's (pgpm._acl_carry_ddl, in pgpm_core). Both tables are asserted: a fix to the copy alone still
-- lets the revoked role read the parent.
--
-- ASYMMETRIC FIXTURE. The default privileges give t38_gone SELECT and UPDATE and t38_dflt DELETE on every
-- new table in public. ha38 is created under them and has them taken back: t38_gone loses SELECT and UPDATE
-- but is granted UPDATE on ONE column (note, not v), t38_dflt loses DELETE, and t38_kept is granted SELECT
-- with grant option, and its owner (the migrating role) revokes its own TRUNCATE: since #949 the copy is minted
-- at the owner's full privileges, so only the swap's reset keeps that privilege from coming back (as the reset,
-- not the mint, is what drops the default privileges of a copy made before #949). hb38 is created BEFORE the
-- default privileges, so its ACL is NULL, the owner's
-- implicit everything and nothing for anyone else. ha38 goes through the two-phase flow (copy, then
-- cutover), so the copy can be found by its oid after the swap; hb38 through the one-shot from_hypertable.
-- The grants are compared by (grantee, privilege, grant option), not grantor, as tests/timescale/db/33
-- explains. Every role is named, never CURRENT_USER: the fleet image's GRANT hook crashes the backend on it.
-- WITNESSES: the default privileges are shown to apply to a table created now, each source ACL is
-- asserted before the migration, and each migration is asserted to have completed with its rows.
select plan(13);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't38_gone') then create role t38_gone; end if;
  if not exists (select 1 from pg_roles where rolname = 't38_dflt') then create role t38_dflt; end if;
  if not exists (select 1 from pg_roles where rolname = 't38_kept') then create role t38_kept; end if;
end $$;
-- membership only so the file can read as t38_gone below (SET ROLE needs it on the fleet image, where the
-- migrating role is not a superuser); t38_gone holds no grant option, so it cannot become a grantor
grant t38_gone to postgres;

-- the effective ACL (a NULL relacl read as the owner's default) and the column grants, as sorted text
create function pg_temp.acl38(p regclass) returns text[] language sql stable as $$
  select array_agg(e order by e) from (
    select distinct pg_get_userbyid(a.grantee) || ':' || a.privilege_type
                    || case when a.is_grantable then '*' else '' end as e
      from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a where c.oid = p
    union
    select att.attname || '/' || pg_get_userbyid(a.grantee) || ':' || a.privilege_type
           || case when a.is_grantable then '*' else '' end
      from pg_attribute att, aclexplode(att.attacl) a
     where att.attrelid = p and att.attnum > 0 and not att.attisdropped and att.attacl is not null) s
$$;

create table public.hb38 (ts timestamptz not null, v int);
select create_hypertable('public.hb38', 'ts', chunk_time_interval => interval '1 day');
insert into public.hb38 select now() - g * interval '5 hours', g from generate_series(1, 7) g;

alter default privileges in schema public grant select, update on tables to t38_gone;
alter default privileges in schema public grant delete on tables to t38_dflt;

create table public.ha38 (ts timestamptz not null, v int, note text);
select create_hypertable('public.ha38', 'ts', chunk_time_interval => interval '1 day');
insert into public.ha38 select now() - g * interval '3 hours', g, 'n' || g from generate_series(1, 20) g;
revoke select, update on public.ha38 from t38_gone;
revoke delete on public.ha38 from t38_dflt;
grant update (note) on public.ha38 to t38_gone;
grant select on public.ha38 to t38_kept with grant option;
revoke truncate on public.ha38 from postgres;

create table public.hp38 (id bigint);
select ok(has_table_privilege('t38_gone', 'public.hp38', 'select')
          and has_table_privilege('t38_dflt', 'public.hp38', 'delete'),
  'LIVENESS: a table the migrating role creates now is born granting t38_gone SELECT and t38_dflt DELETE');

create temp table before38 as
  select 'ha38'::text as t, pg_temp.acl38('public.ha38') as acl
  union all select 'hb38', pg_temp.acl38('public.hb38');
select ok((select acl from before38 where t = 'ha38') @> array['t38_kept:SELECT*', 'note/t38_gone:UPDATE', 'postgres:SELECT']
          and not (select acl from before38 where t = 'ha38')
                  && array['t38_gone:SELECT', 't38_gone:UPDATE', 't38_dflt:DELETE', 'postgres:TRUNCATE'],
  'LIVENESS: ha38 holds its own grants: the defaults taken back, one column grant, a grant option, the owner without TRUNCATE');
select is((select relacl from pg_class where oid = 'public.hb38'::regclass), null::aclitem[],
  'LIVENESS: hb38, created before the default privileges, has the NULL ACL of the owner''s implicit default');

-- ================= the migrations =================
call pgpm.from_hypertable_copy('public.ha38', 'ts');
select oid as copy_oid from pg_class where oid = to_regclass('public.ha38_pgpm_dest') \gset
call pgpm.from_hypertable_cutover('public.ha38', 'ts', interval '1 day', p_paused => true);
call pgpm.from_hypertable('public.hb38', 'ts', interval '1 day', p_paused => true);

select is((select relkind::text from pg_class where oid = 'public.ha38'::regclass)
          || '/' || (select relispartition from pg_class where oid = :copy_oid)
          || '/' || (select string_agg(v::text, ',' order by v) from public.ha38),
  'p/true/' || (select string_agg(g::text, ',' order by g) from generate_series(1, 20) g),
  'LIVENESS: ha38 is a partitioned table, its copy the monolith partition, holding its 20 rows');
select is((select relkind::text from pg_class where oid = 'public.hb38'::regclass)
          || '/' || (select string_agg(v::text, ',' order by v) from public.hb38),
  'p/1,2,3,4,5,6,7', 'LIVENESS: hb38 is a partitioned table holding its 7 rows');

-- ================= Part A: a hypertable with an explicit ACL =================
select is(pg_temp.acl38(:copy_oid::oid::regclass), (select acl from before38 where t = 'ha38'),
  'A: the swapped copy holds exactly the hypertable''s table and column grants');
select is(pg_temp.acl38('public.ha38'), (select acl from before38 where t = 'ha38'),
  'A: the partitioned parent readers query holds exactly the hypertable''s table and column grants');
select ok(not has_table_privilege('t38_gone', :copy_oid::oid, 'select')
          and not has_table_privilege('t38_gone', 'public.ha38', 'select'),
  'A: t38_gone does not hold the SELECT revoked on the hypertable, on the copy or on the parent');
select ok(has_column_privilege('t38_gone', 'public.ha38', 'note', 'update')
          and not has_column_privilege('t38_gone', 'public.ha38', 'v', 'update'),
  'A: t38_gone holds the UPDATE it was granted on note, and not on v');
select ok(not has_table_privilege('t38_dflt', 'public.ha38', 'delete')
          and has_table_privilege('t38_kept', 'public.ha38', 'select with grant option'),
  'A: t38_dflt does not hold the revoked DELETE, and t38_kept keeps its SELECT with grant option');
set role t38_gone;
select throws_ok('select v from public.ha38', '42501', null,
  'A: as t38_gone, a read of the parent is refused');
reset role;

-- ================= Part B: a hypertable at the owner's implicit default =================
select is(pg_temp.acl38('public.hb38'), (select acl from before38 where t = 'hb38'),
  'B: the partitioned parent holds the owner''s full privileges and nothing else, as the hypertable did');
select ok(not has_table_privilege('t38_gone', 'public.hb38', 'select')
          and not has_table_privilege('t38_dflt', 'public.hb38', 'delete'),
  'B: no role holds on the parent what the default privileges gave it and the hypertable never had');

select * from finish();
