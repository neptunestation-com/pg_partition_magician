-- untransmute hands the table back with the PARENT's privileges and row security, not the monolith's
-- conversion-time copy of them (issue #667).
--
-- After a transmute the parent is the table: the application reads and writes it by name, and it is where
-- an operator's GRANT, REVOKE, ENABLE ROW LEVEL SECURITY and CREATE POLICY land. None of those recurse to
-- partitions, so the monolith keeps the ACL, RLS flags and policies the table had at conversion time.
-- untransmute used to detach the monolith, drop the parent and rename the monolith back, replaying only the
-- parent's triggers onto it: every privilege or row-security change made since the conversion was silently
-- undone, so a revoked role could read the table again and row security came off.
--
-- Now untransmute captures the parent's table and column grants, its ENABLE / FORCE flags and its policies
-- under the ACCESS EXCLUSIVE it already takes, and after the rename resets the restored table's own copy
-- (every grantee's privileges revoked, every policy dropped) and replays the parent's in its place.
--
-- Fixtures are asymmetric so that no pair of mistakes can cancel: one grantee revoked after the conversion,
-- one kept, one added (with two privileges), one column-level grant added; one conversion-time policy
-- dropped and two new ones created; three rows of which the new policy lets exactly one through. Section B
-- is the other direction: RLS on at the conversion and off since, and a grant made on the monolith
-- partition itself, which is not the table's and must not survive. Every "no longer" assertion is paired
-- with a LIVENESS witness that the monolith really carried the stale state into the reverse.
create extension if not exists pgtap;
select plan(28);

-- Roles are cluster-wide and the database is per-file, so they are created only when absent and never
-- dropped (see tests/72 for why a DROP ROLE here would be the worse choice).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't176_gone')  then create role t176_gone;  end if;
  if not exists (select 1 from pg_roles where rolname = 't176_keep')  then create role t176_keep;  end if;
  if not exists (select 1 from pg_roles where rolname = 't176_new')   then create role t176_new;   end if;
  if not exists (select 1 from pg_roles where rolname = 't176_col')   then create role t176_col;   end if;
  if not exists (select 1 from pg_roles where rolname = 't176_owner') then create role t176_owner; end if;
end $$;

-- the ids a role can see through the table's name, or {-1} when it may not read it at all (a permission
-- error is a failed assertion here, not an aborted file with the session still SET ROLE)
create function public.t176_ids(p_role name, p_rel regclass) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  execute format('set local role %I', p_role);
  execute format('select coalesce(array_agg(id order by id), ''{}'') from %s', p_rel) into v;
  reset role;
  return v;
exception when insufficient_privilege then
  reset role;
  return array[-1]::bigint[];
end $$;

-- ======================================================================================================
-- (A) revoked, kept, added and column grants; RLS turned on and FORCEd; one policy dropped, two created
-- ======================================================================================================
create table public.sec176 (id bigint primary key, owner_name text, secret text);
insert into public.sec176 values (1, 'alice', 's1'), (2, 'bob', 's2'), (3, 'carol', 's3');
grant select on public.sec176 to t176_gone, t176_keep;
create policy sec176_old on public.sec176 for select using (true);   -- conversion-time; RLS still off
create temp table orig176 as select 'public.sec176'::regclass::oid as oid;

call pgpm.transmute('public.sec176', 'id', 100::bigint, p_obtain => 2);
select child_name as mon176 from pgpm.part
 where parent_table = 'public.sec176'::regclass and child_oid = (select oid from orig176) \gset

-- the operator's changes, all on the managed table (the parent) after the conversion
revoke select on public.sec176 from t176_gone;
grant select, insert on public.sec176 to t176_new;
grant select (id) on public.sec176 to t176_col;
alter table public.sec176 enable row level security;
alter table public.sec176 force row level security;
drop policy sec176_old on public.sec176;
create policy sec176_alice on public.sec176 for select to t176_new using (owner_name = 'alice');
create policy sec176_ins on public.sec176 as restrictive for insert to t176_new with check (owner_name = 'alice');

select is(public.t176_ids('t176_new', 'public.sec176'), array[1]::bigint[],
  'LIVENESS: (A) before the reverse, the new policy lets t176_new see exactly the alice row');
select is(public.t176_ids('t176_gone', 'public.sec176'), array[-1]::bigint[],
  'LIVENESS: (A) before the reverse, the revoked role cannot read the table');
select ok(has_table_privilege('t176_gone', format('public.%I', :'mon176'), 'select'),
  'LIVENESS: (A) the monolith still grants the revoked role SELECT, the stale state the reverse must not keep');
select ok(not (select relrowsecurity from pg_class where oid = (select oid from orig176)),
  'LIVENESS: (A) the monolith still has row security off');
select is((select array_agg(polname::text order by polname) from pg_policy where polrelid = (select oid from orig176)),
  array['sec176_old'],
  'LIVENESS: (A) the monolith still carries the dropped conversion-time policy and none of the new ones');

select is(pgpm.untransmute('public.sec176')::oid, (select oid from orig176),
  'LIVENESS: (A) untransmute goes through and hands back the original relation');
select is((select relkind::text from pg_class where oid = 'public.sec176'::regclass), 'r',
  'LIVENESS: (A) the table is an ordinary table again');

select is(
  (select array_agg(pg_get_userbyid(a.grantee) || ':' || a.privilege_type order by 1)
     from pg_class c, aclexplode(c.relacl) a
    where c.oid = 'public.sec176'::regclass and a.grantee <> c.relowner),
  array['t176_keep:SELECT', 't176_new:INSERT', 't176_new:SELECT'],
  '(A) the restored table carries exactly the parent''s table grants: kept, added, and not the revoked one');
select ok(not has_table_privilege('t176_gone', 'public.sec176', 'select'),
  '(A) the REVOKE issued after the conversion still holds');
select ok(has_column_privilege('t176_col', 'public.sec176', 'id', 'select'),
  '(A) the column grant made after the conversion is carried back');
select ok(not has_column_privilege('t176_col', 'public.sec176', 'secret', 'select'),
  '(A) and it is a column grant still, not widened to the table');
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.sec176'::regclass),
  '(A) row security is ENABLEd and FORCEd on the restored table');
select is((select array_agg(polname::text order by polname) from pg_policy where polrelid = 'public.sec176'::regclass),
  array['sec176_alice', 'sec176_ins'],
  '(A) the restored table carries exactly the parent''s policies: the two new ones, not the dropped one');
select is(
  (select array_agg(format('%s/%s/%s/%s/%s', policyname, permissive, cmd, roles, coalesce(qual, with_check)) order by policyname)
     from pg_policies where schemaname = 'public' and tablename = 'sec176'),
  array['sec176_alice/PERMISSIVE/SELECT/{t176_new}/(owner_name = ''alice''::text)',
        'sec176_ins/RESTRICTIVE/INSERT/{t176_new}/(owner_name = ''alice''::text)'],
  '(A) each policy comes back with its own command, roles, kind and expression');
select is(public.t176_ids('t176_new', 'public.sec176'), array[1]::bigint[],
  '(A) behaviourally: t176_new sees exactly the alice row through the restored table');
select is(public.t176_ids('t176_gone', 'public.sec176'), array[-1]::bigint[],
  '(A) behaviourally: the revoked role still cannot read the restored table');
select is(public.t176_ids('t176_keep', 'public.sec176'), '{}'::bigint[],
  '(A) behaviourally: the kept role reads it, and FORCEd row security with no policy for it shows it nothing');

-- ======================================================================================================
-- (B) the other direction: RLS on at the conversion and off since; a grant on the monolith partition
--     itself (not the table's); the parent's ACL never touched, so it is the owner's default
-- ======================================================================================================
create table public.sec176b (id bigint primary key, owner_name text);
insert into public.sec176b values (1, 'alice'), (2, 'bob');
alter table public.sec176b owner to t176_owner;
alter table public.sec176b enable row level security;
alter table public.sec176b force row level security;
create policy sec176b_none on public.sec176b for select using (false);
create temp table orig176b as select 'public.sec176b'::regclass::oid as oid;

call pgpm.transmute('public.sec176b', 'id', 100::bigint, p_obtain => 2);
select child_name as mon176b from pgpm.part
 where parent_table = 'public.sec176b'::regclass and child_oid = (select oid from orig176b) \gset

alter table public.sec176b no force row level security;
alter table public.sec176b disable row level security;
drop policy sec176b_none on public.sec176b;
grant select on table :"mon176b" to t176_gone;   -- on the partition, which is not the table

select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = (select oid from orig176b)),
  'LIVENESS: (B) the monolith still has row security ENABLEd and FORCEd');
select ok(has_table_privilege('t176_gone', (select oid from orig176b), 'select'),
  'LIVENESS: (B) the monolith grants t176_gone SELECT');
select ok((select relacl is null from pg_class where oid = 'public.sec176b'::regclass),
  'LIVENESS: (B) the parent''s ACL is the owner''s default, never granted or revoked');

select is(pgpm.untransmute('public.sec176b')::oid, (select oid from orig176b),
  'LIVENESS: (B) untransmute goes through and hands back the original relation');

select ok((select not relrowsecurity and not relforcerowsecurity from pg_class where oid = 'public.sec176b'::regclass),
  '(B) row security is off on the restored table, as it was on the parent');
select is((select count(*)::int from pg_policy where polrelid = 'public.sec176b'::regclass), 0,
  '(B) the conversion-time policy the parent dropped does not come back');
select ok(not has_table_privilege('t176_gone', 'public.sec176b', 'select'),
  '(B) the grant made on the monolith partition does not become a grant on the table');
select is(
  (select count(*)::int from pg_class c, aclexplode(c.relacl) a
    where c.oid = 'public.sec176b'::regclass and a.grantee <> c.relowner),
  0, '(B) no role but the owner holds any privilege on the restored table');
select ok(has_table_privilege('t176_owner', 'public.sec176b', 'select, insert, update, delete, truncate, references, trigger'),
  '(B) the owner keeps every privilege it holds by default');
select is(public.t176_ids('t176_owner', 'public.sec176b'), array[1, 2]::bigint[],
  '(B) behaviourally: the owner reads every row, with no row security in the way');
select is((select pg_get_userbyid(relowner)::text from pg_class where oid = 'public.sec176b'::regclass), 't176_owner',
  'LIVENESS: (B) the owner is still t176_owner, so the privilege checks above are not a superuser''s');

select * from finish();
