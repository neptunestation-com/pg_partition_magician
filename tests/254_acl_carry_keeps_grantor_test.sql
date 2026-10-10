-- Every grant the conversions carry keeps its GRANTOR (issue #903, review pass 8 F1-10).
--
-- _acl_carry_ddl read grantee, privilege and grant option off aclexplode and dropped the grantor, so every
-- grant was replayed by the converting role and recorded as the owner's. A grant a role made through its
-- grant option then belonged to nobody who knew about it: its maker's REVOKE on the converted table found no
-- grant of its own and the grantee kept the privilege. transmute's parent, pgpm_hypertable's swapped copy and
-- untransmute's restored table all carry through it. Each grant another role made is now replayed AS that
-- role (pgpm._acl_grant_as), after the grant that gave it the option; a session that may not become the
-- grantor is refused, up front in transmute (before anything commits) and inside untransmute (which rolls
-- back whole), rather than recording the grant under the owner.
--
-- ASYMMETRIC FIXTURE. t254_owner owns every table. It grants t254_bob SELECT and UPDATE (note) with grant
-- option and t254_plain INSERT. Through his options bob grants t254_carol SELECT and UPDATE (note), t254_dave
-- SELECT with grant option and t254_erin SELECT on ONE column (v); through his, dave grants erin SELECT on
-- the table. So the ACL has grants by three grantors, two levels deep (dave's needs bob's first), at table
-- and column level, and erin holds SELECT on v from two grantors: revoking one of them must leave the other.
-- (A) is transmute run by the owner through SET ROLE from a superuser session, (B) untransmute, (C) a
-- session that cannot become bob, refused and then let through by membership, (D) the same for untransmute.
-- WITNESSES: each source ACL, grantors included, is asserted before the conversion, and each conversion or
-- reversal is asserted to have happened.
create extension if not exists pgtap;
select plan(24);

-- Roles are cluster-wide and the database is per-file, so they are created only when absent, never dropped.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't254_owner')  then create role t254_owner;  end if;
  if not exists (select 1 from pg_roles where rolname = 't254_owner2') then create role t254_owner2; end if;
  if not exists (select 1 from pg_roles where rolname = 't254_bob')    then create role t254_bob;    end if;
  if not exists (select 1 from pg_roles where rolname = 't254_carol')  then create role t254_carol;  end if;
  if not exists (select 1 from pg_roles where rolname = 't254_dave')   then create role t254_dave;   end if;
  if not exists (select 1 from pg_roles where rolname = 't254_erin')   then create role t254_erin;   end if;
  if not exists (select 1 from pg_roles where rolname = 't254_plain')  then create role t254_plain;  end if;
end $$;
-- a role that ran (C) before in this cluster is a member of bob already: (C) starts from none
do $$ begin
  if pg_has_role('t254_owner', 't254_bob', 'member') then revoke t254_bob, t254_dave from t254_owner; end if;
end $$;
grant usage, create on schema public to t254_owner, t254_owner2;
grant usage on schema public to t254_bob, t254_carol, t254_dave, t254_erin, t254_plain;
grant usage on schema pgpm to t254_owner, t254_owner2;
grant all on all tables in schema pgpm to t254_owner, t254_owner2;
grant all on all sequences in schema pgpm to t254_owner, t254_owner2;

-- the ACL of a relation and its columns as text, GRANTOR included (a NULL relacl read as the owner's default)
create function pg_temp.acl254(p regclass) returns text[] language sql stable as $$
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

-- the fixture's grants on one table, each made by the role that holds the option
create function pg_temp.grants254(p_rel text) returns void language plpgsql as $$
begin
  execute format('alter table %s owner to t254_owner', p_rel);
  set local role t254_owner;
  execute format('grant select on %s to t254_bob with grant option', p_rel);
  execute format('grant update (note) on %s to t254_bob with grant option', p_rel);
  execute format('grant insert on %s to t254_plain', p_rel);
  set local role t254_bob;
  execute format('grant select on %s to t254_carol', p_rel);
  execute format('grant update (note) on %s to t254_carol', p_rel);
  execute format('grant select on %s to t254_dave with grant option', p_rel);
  execute format('grant select (v) on %s to t254_erin', p_rel);
  set local role t254_dave;
  execute format('grant select on %s to t254_erin', p_rel);
  reset role;
end $$;

create table public.gr254  (id bigint primary key, v int, note text);
create table public.gr254u (id bigint primary key, v int, note text);
create table public.gr254r (id bigint primary key, v int, note text);
create table public.gr254d (id bigint primary key, v int, note text);
insert into public.gr254  select g, g * 10, 'n' || g from generate_series(1, 7) g;
insert into public.gr254u select g, g, 'u' || g from generate_series(1, 5) g;
insert into public.gr254r select g, g, 'r' || g from generate_series(1, 3) g;
insert into public.gr254d select g, g, 'd' || g from generate_series(1, 4) g;
select pg_temp.grants254('public.gr254');
select pg_temp.grants254('public.gr254u');
select pg_temp.grants254('public.gr254r');
select pg_temp.grants254('public.gr254d');
alter table public.gr254d owner to t254_owner2;   -- (D): an owner that is no member of bob

create temp table before254 as select pg_temp.acl254('public.gr254') as acl;
select ok((select acl from before254) @> array['t254_carol:SELECT/t254_bob', 't254_dave:SELECT*/t254_bob',
                                               't254_erin:SELECT/t254_dave', 'v/t254_erin:SELECT/t254_bob',
                                               'note/t254_carol:UPDATE/t254_bob', 't254_bob:SELECT*/t254_owner',
                                               't254_plain:INSERT/t254_owner'],
  'LIVENESS: gr254''s grants were made by three grantors, two levels deep, at table and column level');

-- ================= (A) transmute, run by the owner =================
set role t254_owner;
call pgpm.transmute('public.gr254', 'id', 100::bigint, p_obtain => 2);
select is(current_user::text, 't254_owner',
  'A: transmute puts the caller''s role back as it was, after replaying grants as other roles');
reset role;
select is((select relkind::text from pg_class where oid = 'public.gr254'::regclass), 'p',
  'LIVENESS: (A) gr254 was converted into a partitioned parent');
select is(pg_temp.acl254('public.gr254'), (select acl from before254),
  'A: the parent holds exactly the table''s grants, each under the grantor that made it');
set role t254_bob;
revoke select on public.gr254 from t254_carol;
reset role;
set role t254_dave;
revoke select on public.gr254 from t254_erin;
reset role;
select ok(not has_table_privilege('t254_carol', 'public.gr254', 'select')
          and has_column_privilege('t254_carol', 'public.gr254', 'note', 'update'),
  'A: bob''s REVOKE takes carol''s SELECT away on the parent, and leaves the UPDATE (note) he did not revoke');
select ok(not has_table_privilege('t254_erin', 'public.gr254', 'select'),
  'A: dave''s REVOKE takes erin''s table-level SELECT away on the parent');
select ok(has_column_privilege('t254_erin', 'public.gr254', 'v', 'select')
          and not has_column_privilege('t254_erin', 'public.gr254', 'id', 'select'),
  'A: erin keeps the SELECT on v bob granted her, and nothing on id');
select ok(has_table_privilege('t254_dave', 'public.gr254', 'select with grant option')
          and has_table_privilege('t254_plain', 'public.gr254', 'insert'),
  'LIVENESS: (A) the grants nobody revoked are still held');

-- ================= (B) untransmute hands the grants back under their grantors =================
call pgpm.transmute('public.gr254u', 'id', 100::bigint, p_obtain => 2);
create temp table parent254u as select pg_temp.acl254('public.gr254u') as acl;
select ok((select acl from parent254u) @> array['t254_carol:SELECT/t254_bob', 't254_erin:SELECT/t254_dave'],
  'LIVENESS: (B) the managed gr254u holds carol''s grant from bob and erin''s from dave');
select is(pgpm.untransmute('public.gr254u')::text, 'gr254u', 'LIVENESS: (B) untransmute restored gr254u');
select is((select relkind::text from pg_class where oid = 'public.gr254u'::regclass), 'r',
  'LIVENESS: (B) gr254u is an ordinary table again');
select is(pg_temp.acl254('public.gr254u'), (select acl from parent254u),
  'B: the restored table holds exactly the parent''s grants, each under the grantor that made it');
set role t254_bob;
revoke select on public.gr254u from t254_carol;
reset role;
select ok(not has_table_privilege('t254_carol', 'public.gr254u', 'select')
          and has_table_privilege('t254_erin', 'public.gr254u', 'select'),
  'B: bob''s REVOKE takes carol''s SELECT away on the restored table, and erin keeps dave''s');

-- ================= (C) a session that cannot become bob =================
create temp table before254r as select pg_temp.acl254('public.gr254r') as acl;
select ok(not pg_has_role('t254_owner', 't254_bob', 'member'),
  'LIVENESS: (C) t254_owner is no member of t254_bob, so a session it authenticates cannot SET ROLE to him');
set session authorization t254_owner;
select throws_like(
  $$ call pgpm.transmute('public.gr254r', 'id', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: cannot transmute gr254r as t254_owner -- grants on it were made by t254_bob, t254_dave through a grant option,%',
  'C: transmute refuses up front, naming the grantors the session cannot replay grants as');
reset session authorization;
select is((select relkind::text || ' ' || (select string_agg(id::text, ',' order by id) from public.gr254r)
                  || ' ' || exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.gr254r'::regclass)::text
                  || ' ' || exists (select 1 from pg_constraint where conrelid = 'public.gr254r'::regclass and conname = 'pgpm_monolith_bound')::text
             from pg_class where oid = 'public.gr254r'::regclass),
  'r 1,2,3 false false',
  'C: the table is left as it was, a plain table holding rows 1, 2 and 3, with no claim and no bound');
select is(pg_temp.acl254('public.gr254r'), (select acl from before254r), 'C: with its grants as they were');
grant t254_bob, t254_dave to t254_owner;
set session authorization t254_owner;
call pgpm.transmute('public.gr254r', 'id', 100::bigint, p_obtain => 2);
select is(current_user::text, 't254_owner', 'C: the role is put back after the replay');
reset session authorization;
select is((select relkind::text from pg_class where oid = 'public.gr254r'::regclass), 'p',
  'LIVENESS: (C) as a member of bob and dave the same session converts gr254r');
select is(pg_temp.acl254('public.gr254r'), (select acl from before254r),
  'C: and the parent holds exactly the table''s grants, each under its grantor');
revoke t254_bob, t254_dave from t254_owner;

-- ================= (D) untransmute in a session that cannot become bob =================
call pgpm.transmute('public.gr254d', 'id', 100::bigint, p_obtain => 2);
create temp table parent254d as select pg_temp.acl254('public.gr254d') as acl;
select ok((select acl from parent254d) @> array['t254_carol:SELECT/t254_bob', 't254_erin:SELECT/t254_dave']
          and not pg_has_role('t254_owner2', 't254_bob', 'member'),
  'LIVENESS: (D) the managed gr254d holds grants by bob and dave, and its owner t254_owner2 is no member of bob');
set session authorization t254_owner2;
select throws_like(
  $$ select pgpm.untransmute('public.gr254d') $$,
  'pg_partition_magician: cannot replay the grant "grant % on public.gr254d to %" as its grantor t254_%',
  'D: untransmute refuses to record a grant under another grantor');
reset session authorization;
select is((select relkind::text from pg_class where oid = 'public.gr254d'::regclass), 'p',
  'D: and rolls back whole: gr254d is still the managed partitioned table');
select is(pg_temp.acl254('public.gr254d'), (select acl from parent254d), 'D: with its grants as they were');

select * from finish();
