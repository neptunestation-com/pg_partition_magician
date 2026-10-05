-- A partition pgpm mints grants nothing to anyone but its owner (issue #875 bullet 1, review pass 8 F10-02 and
-- the pre-pin verifier's A875-1).
--
-- Every partition pgpm mints after a conversion (transmute's forward grid, obtain, extend_to, a regrain's fine
-- children) is created by whatever role runs maintenance, so it was born with that role's ALTER DEFAULT
-- PRIVILEGES, and _own_like_parent changed only its owner. A role those name (on Supabase, anon and
-- authenticated in public) read every row of the partition by naming it: past a REVOKE on the table, and past
-- the parent's row security, which does not apply to a partition read directly. reference.md: "reaching a
-- partition directly needs grants that live on the parent anyway". Every minted partition is now reset to its
-- owner's default (pgpm._acl_reset), after it is given the parent's owner: a read or write routed through the
-- parent is checked against the parent alone, so no role needs a grant on a partition.
--
-- ASYMMETRIC FIXTURE. The default privileges of postgres, the role running maintenance here, give t256_anon
-- SELECT and t256_dflt DELETE on every table it creates in public. Table p256 is owned by t256_owner, has
-- t256_anon's SELECT revoked, keeps t256_dflt's DELETE and grants it INSERT, and grants t256_reader SELECT
-- under a row-security policy that shows the reader only rows marked 'reader'. One row marked 'other' is
-- written into a partition of every minting path. So a partition that carried the defaults leaks to t256_anon, one that carried the
-- parent's grants leaks to t256_reader (no policy there), and one stripped of the owner's privileges is caught
-- by the owner's own read. WITNESSES: the default privileges are shown to apply to a table created now, every
-- path is shown to have minted the partition its row lands in, and the parent's grants and policy are shown
-- to hold.
create extension if not exists pgtap;
select plan(15);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't256_owner')  then create role t256_owner;  end if;
  if not exists (select 1 from pg_roles where rolname = 't256_anon')   then create role t256_anon;   end if;
  if not exists (select 1 from pg_roles where rolname = 't256_dflt')   then create role t256_dflt;   end if;
  if not exists (select 1 from pg_roles where rolname = 't256_reader') then create role t256_reader; end if;
end $$;
grant usage on schema public to t256_anon, t256_dflt, t256_reader;

-- what a role reads by naming a relation directly, or 'denied'
create function public.t256_read(p_role name, p_rel regclass) returns text language plpgsql as $$
declare v text;
begin
  execute format('set local role %I', p_role);
  execute format('select coalesce(string_agg(secret, '','' order by secret), ''(none)'') from %s', p_rel) into v;
  reset role;
  return v;
exception when insufficient_privilege then
  reset role;
  return 'denied';
end $$;
grant execute on function public.t256_read(name, regclass) to public;

alter default privileges for role postgres in schema public grant select on tables to t256_anon;
alter default privileges for role postgres in schema public grant delete on tables to t256_dflt;

create table public.p256 (id bigint primary key, who text not null, secret text not null);
insert into public.p256 select g, case when g % 2 = 0 then 'reader' else 'other' end, 'm' || g
  from generate_series(1, 60) g;
alter table public.p256 owner to t256_owner;
revoke select on public.p256 from t256_anon;
grant select on public.p256 to t256_reader;
grant insert on public.p256 to t256_dflt;
alter table public.p256 enable row level security;
create policy only_reader on public.p256 for select using (who = 'reader');
create policy any_insert on public.p256 for insert with check (true);

create table public.probe256 (id bigint);
select ok(has_table_privilege('t256_anon', 'public.probe256', 'select')
          and has_table_privilege('t256_dflt', 'public.probe256', 'delete'),
  'LIVENESS: a table postgres creates now is born granting t256_anon SELECT and t256_dflt DELETE');

call pgpm.transmute('public.p256', 'id', 100::bigint, p_obtain => 2);
create temp table mon256 as select monolith_oid::regclass as rel from pgpm.config where parent_table = 'public.p256'::regclass;
create temp table minted256 (path text, child regclass);
insert into minted256 select 'transmute', p.child_oid::regclass from pgpm.part p
 where p.parent_table = 'public.p256'::regclass and p.child_oid <> (select rel from mon256);
select pgpm.set_obtain('public.p256', 4);
select pgpm.obtain('public.p256');
insert into minted256 select 'obtain', p.child_oid::regclass from pgpm.part p
 where p.parent_table = 'public.p256'::regclass and p.child_oid <> (select rel from mon256)
   and p.child_oid not in (select child from minted256);
select pgpm.extend_to('public.p256', '750');
insert into minted256 select 'extend_to', p.child_oid::regclass from pgpm.part p
 where p.parent_table = 'public.p256'::regclass and p.child_oid <> (select rel from mon256)
   and p.child_oid not in (select child from minted256);
-- a row past the monolith freezes it, so the regrain can split it
insert into public.p256 values (150, 'other', 'o-transmute'), (350, 'other', 'o-obtain'), (650, 'other', 'o-extend');
select pgpm.regrain('public.p256', (select relname from pg_class where oid = (select rel from mon256)), '50');
insert into minted256 select 'regrain', p.child_oid::regclass from pgpm.part p
 where p.parent_table = 'public.p256'::regclass and p.attached
   and p.child_oid not in (select child from minted256);
create temp table home256 as select secret, tableoid::regclass as child from public.p256 where who = 'other';

select is((select array_agg(m.path || ':' || h.secret order by m.path, h.secret) from home256 h join minted256 m using (child)
            where h.secret in ('o-transmute', 'o-obtain', 'o-extend', 'm1', 'm59')),
  array['extend_to:o-extend', 'obtain:o-obtain', 'regrain:m1', 'regrain:m59', 'transmute:o-transmute'],
  'LIVENESS: a hidden row lives in a partition of every minting path (the regrain''s two fine children)');
select is((select array_agg(distinct m.path order by m.path) from minted256 m), array['extend_to', 'obtain', 'regrain', 'transmute'],
  'LIVENESS: every path minted at least one partition, and the monolith is gone into the regrain''s');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.p256'::regclass and child_oid = (select rel::oid from mon256)),
  'LIVENESS: the regrain replaced the monolith');
select is((select count(*)::int from minted256 m join pg_class c on c.oid = m.child
            where pg_get_userbyid(c.relowner) <> 't256_owner'), 0,
  'GUARD: every minted partition has the parent''s owner');

-- the parent's own grants and policy, which the partitions must not undercut
select is(public.t256_read('t256_reader', 'public.p256'),
          (select string_agg(secret, ',' order by secret) from public.p256 where who = 'reader'),
  'LIVENESS: through the parent the policy shows t256_reader exactly the rows marked reader');
select ok(not has_table_privilege('t256_anon', 'public.p256', 'select')
          and has_table_privilege('t256_dflt', 'public.p256', 'delete')
          and has_table_privilege('t256_dflt', 'public.p256', 'insert'),
  'LIVENESS: the parent holds the table''s grants: no SELECT for t256_anon, DELETE and INSERT for t256_dflt');

-- the contract
select is((select array_agg(m.path || ' ' || c.relname order by c.relname) from minted256 m join pg_class c on c.oid = m.child
            where coalesce(c.relacl, acldefault('r', c.relowner)) <> acldefault('r', c.relowner)
               or exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attacl is not null)),
  null::text[],
  'every minted partition holds its owner''s default privileges and nothing else');
select is((select array_agg(m.path || ':' || public.t256_read('t256_anon', m.child) order by m.path, m.child::text)
             filter (where public.t256_read('t256_anon', m.child) <> 'denied') from minted256 m),
  null::text[], 't256_anon, revoked on the table, reads no minted partition by naming it');
select is((select array_agg(m.path || ':' || public.t256_read('t256_reader', m.child) order by m.path, m.child::text)
             filter (where public.t256_read('t256_reader', m.child) <> 'denied') from minted256 m),
  null::text[], 't256_reader reads no minted partition directly, past the parent''s policy');
select ok(not exists (select 1 from minted256 m where has_table_privilege('t256_dflt', m.child, 'delete')
                                                  or has_table_privilege('t256_dflt', m.child, 'insert')),
  't256_dflt holds no DELETE or INSERT on any minted partition (they live on the parent)');
select is((select array_agg(distinct public.t256_read('t256_owner', h.child) like '%' || h.secret || '%') from home256 h
            where h.secret in ('o-transmute', 'o-obtain', 'o-extend', 'm1', 'm59')),
  array[true], 'the owner keeps its own privileges: it reads each hidden row in its partition');
-- the routed paths the grants on the parent cover
set role t256_dflt;
insert into public.p256 values (700, 'reader', 'r-routed');
reset role;
select is((select tableoid::regclass::text from public.p256 where id = 700), 'p256_p0000000000000000700',
  't256_dflt''s INSERT on the parent is routed into a partition extend_to minted');
select is(public.t256_read('t256_reader', 'public.p256') like '%r-routed%', true,
  'and t256_reader reads the routed row through the parent, under its policy');
select is((select array_agg(secret order by secret) from public.p256 where id in (150, 350, 650)),
  array['o-extend', 'o-obtain', 'o-transmute'], 'and the other rows are where they were');

select * from finish();
