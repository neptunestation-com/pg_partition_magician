-- from_hypertable read the hypertable under the CALLER's row-level security (issue #825, the hypertable
-- half). The chunk copy, the cutover's catch-up and its conservation check are ordinary queries of the
-- source, so on a hypertable with FORCE ROW LEVEL SECURITY a non-superuser owner without BYPASSRLS (pgpm
-- promises no superuser requirement) copied only the rows its policies admit, the conservation check read
-- the source through the same policies and agreed with the copy, and the swap dropped the hidden rows with
-- the hypertable. Every phase now refuses such a caller up front, before it reads or commits anything
-- (pgpm._refuse_filtered_reads, shared with transmute): the preflight (so from_hypertable and
-- from_hypertable_copy), and the cutover.
--
-- ASYMMETRIC FIXTURE. Nine rows, ids 1..9, eight hours apart across four daily chunks; tenant 'b' (ids 3,
-- 6, 9) is hidden from the owner by a FORCE'd policy and the other six are visible, so a migration that
-- kept the visible rows and lost the hidden ones, or the reverse, cannot read as the right one.
--
-- WHAT THE HARNESS ALLOWS. The refused calls run as the owner through a SECURITY DEFINER function the owner
-- owns, which is how a pgTAP file run as postgres makes a call as another role (pgTAP's own temp tables
-- belong to postgres). The function context, like throws_*'s, cannot COMMIT, so a phase that wrongly does
-- NOT refuse dies at its first COMMIT with 2D000 and rolls back into the state a refusal leaves: the pinned
-- messages are the discriminating assertions, and the state checks after them are invariants, marked so.
-- The preflight is a function and commits nothing, so its refusal discriminates on its own.
-- WITNESSES: the policy filters the owner and not the harness's BYPASSRLS role; and the same hypertable
-- migrates, every row by identity and FORCE carried, once a role the check passes runs each phase, while
-- the owner migrates a second hypertable whose row-level security is ENABLEd but not FORCEd. So a module
-- that refused every FORCE'd hypertable, or every one with row-level security, could not pass this file.
select plan(20);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't37_owner') then
    create role t37_owner nosuperuser nobypassrls;
  end if;
end $$;
-- Named, not CURRENT_USER: the fleet image's GRANT hook crashes the backend on that role spec (tests/33).
grant t37_owner to postgres;
grant create, usage on schema public to t37_owner;
grant usage on schema pgpm to t37_owner;
grant all on all tables in schema pgpm to t37_owner;
grant all on all sequences in schema pgpm to t37_owner;

-- Created AS t37_owner rather than handed to it, for the reason tests/33 gives (ALTER ... OWNER on a
-- hypertable re-owns its chunks, which needs CREATE on _timescaledb_internal).
set role t37_owner;
create table public.hf37 (id bigint not null, ts timestamptz not null, tenant text not null, primary key (id, ts));
select create_hypertable('public.hf37', 'ts', chunk_time_interval => interval '1 day');
insert into public.hf37 select g, now() - g * interval '8 hours', case when g % 3 = 0 then 'b' else 'a' end
  from generate_series(1, 9) g;
alter table public.hf37 enable row level security;
alter table public.hf37 force row level security;
create policy hf37_tenant_a on public.hf37 using (tenant = 'a');
create table public.hn37 (id bigint not null, ts timestamptz not null, tenant text not null, primary key (id, ts));
select create_hypertable('public.hn37', 'ts', chunk_time_interval => interval '1 day');
insert into public.hn37 select * from public.hf37;   -- the owner's view of hf37: tenant a alone
insert into public.hn37 select g, now() - g * interval '8 hours', 'b' from generate_series(3, 9, 3) g;
alter table public.hn37 enable row level security;
create policy hn37_tenant_a on public.hn37 using (tenant = 'a');
create function public.t37_as_owner(p_sql text) returns void language plpgsql security definer as $f$
begin execute p_sql; end $f$;
select string_agg(id::text, ',' order by id) as hf, (select string_agg(id::text, ',' order by id) from public.hn37) as hn
  from public.hf37 \gset owner_sees_
reset role;

-- ================= WITNESSES =================
select is((select (not rolsuper and not rolbypassrls)::text from pg_roles where rolname = 't37_owner')
          || '/' || (select rolbypassrls::text from pg_roles where rolname = current_user), 'true/true',
  'LIVENESS: t37_owner is neither a superuser nor BYPASSRLS, and the harness''s role is BYPASSRLS');
select is((select string_agg(relname || ':' || pg_get_userbyid(relowner) || ':' || relrowsecurity || '/' || relforcerowsecurity,
                             ',' order by relname)
             from pg_class where oid in ('public.hf37'::regclass, 'public.hn37'::regclass)),
  'hf37:t37_owner:true/true,hn37:t37_owner:true/false',
  'LIVENESS: both are t37_owner''s; hf37 FORCEs row-level security, hn37 only ENABLEs it');
select is(:'owner_sees_hf'::text, '1,2,4,5,7,8',
  'LIVENESS: under FORCE the owner sees tenant a''s six rows of hf37 and none of tenant b''s three');
select is(:'owner_sees_hn'::text, '1,2,3,4,5,6,7,8,9', 'LIVENESS: without FORCE the owner sees every row of hn37');
select is((select string_agg(id || ':' || tenant, ',' order by id) from public.hf37),
  '1:a,2:a,3:b,4:a,5:a,6:b,7:a,8:a,9:b', 'LIVENESS: hf37 holds all nine rows (read by the BYPASSRLS harness role)');
select ok((select count(*) from timescaledb_information.chunks where hypertable_name = 'hf37') >= 3,
  'LIVENESS: hf37''s rows span several chunks, so the copy is chunk by chunk');

-- ================= A. the owner migrating: refused before the copy =================
select throws_like(
  $$ select public.t37_as_owner($c$ select pgpm.from_hypertable_preflight('public.hf37', 'ts') $c$) $$,
  'pg_partition_magician: cannot migrate hypertable hf37 as t37_owner -- row-level security is active on it for that role (FORCE ROW LEVEL SECURITY holds even the table''s owner to the policies, and the role has no BYPASSRLS)%Run it as a role with BYPASSRLS (or a superuser); nothing was changed.',
  'A: the preflight refuses the owner of a FORCE''d hypertable whose reads its policies filter');
select throws_like(
  $$ select public.t37_as_owner($c$ call pgpm.from_hypertable('public.hf37', 'ts', interval '1 day', p_paused => true) $c$) $$,
  'pg_partition_magician: cannot migrate hypertable hf37 as t37_owner -- row-level security is active on it for that role%the swap would drop the others with the hypertable%',
  'A: from_hypertable refuses the same caller, before the copy commits anything');
select throws_like(
  $$ select public.t37_as_owner($c$ call pgpm.from_hypertable_copy('public.hf37', 'ts') $c$) $$,
  'pg_partition_magician: cannot migrate hypertable hf37 as t37_owner -- row-level security is active on it for that role%',
  'A: and so does from_hypertable_copy called on its own');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hf37')
          || '/' || coalesce(to_regclass('public.hf37_pgpm_dest')::text, 'no copy'), '1/no copy',
  'A (invariant): hf37 is still a hypertable, and no copy was left behind');

-- ================= B. the owner cutting over a copy a BYPASSRLS role made: refused =================
call pgpm.from_hypertable_copy('public.hf37', 'ts');
select is((select string_agg(id || ':' || tenant, ',' order by id) from public.hf37_pgpm_dest),
  '1:a,2:a,3:b,4:a,5:a,6:b,7:a,8:a,9:b', 'LIVENESS: (B) the harness role''s copy holds all nine rows, tenant b''s included');
select throws_like(
  $$ select public.t37_as_owner($c$ call pgpm.from_hypertable_cutover('public.hf37', 'ts', interval '1 day', p_paused => true) $c$) $$,
  'pg_partition_magician: cannot cut over hypertable hf37 as t37_owner -- row-level security is active on it for that role (FORCE ROW LEVEL SECURITY holds even the table''s owner to the policies, and the role has no BYPASSRLS)%the conservation check would read only those rows%',
  'B: the cutover refuses the owner too, before the pre-drain commits anything');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hf37')
          || '/' || (select string_agg(id::text, ',' order by id) from public.hf37), '1/1,2,3,4,5,6,7,8,9',
  'B (invariant): hf37 is still the hypertable, holding all nine rows');

-- ================= C. a role the check passes cuts over: every row, FORCE carried =================
call pgpm.from_hypertable_cutover('public.hf37', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.hf37'::regclass)
          || '/' || (select count(*) from pgpm.config where parent_table = 'public.hf37'::regclass)
          || '/' || (select count(*) from timescaledb_information.hypertables where hypertable_name = 'hf37'), 'p/1/0',
  'LIVENESS: (C) the harness role''s cutover converted hf37 into a pgpm-managed partitioned table');
select is((select string_agg(id || ':' || tenant, ',' order by id) from public.hf37),
  '1:a,2:a,3:b,4:a,5:a,6:b,7:a,8:a,9:b', 'C: hf37 holds every row by identity, tenant b''s three included');
select is((select pg_get_userbyid(relowner) || ':' || relrowsecurity || '/' || relforcerowsecurity
             from pg_class where oid = 'public.hf37'::regclass), 't37_owner:true/true',
  'C: and it is still t37_owner''s, with row-level security FORCEd');
set role t37_owner;
select string_agg(id::text, ',' order by id) as hf from public.hf37 \gset owner_after_
reset role;
select is(:'owner_after_hf'::text, '1,2,4,5,7,8', 'C: the policy still holds the owner to tenant a''s rows');

-- ================= D. the owner, row-level security ENABLEd but not FORCEd: migrates =================
set role t37_owner;
call pgpm.from_hypertable('public.hn37', 'ts', interval '1 day', p_paused => true);
reset role;
select is((select relkind::text from pg_class where oid = 'public.hn37'::regclass)
          || '/' || (select count(*) from pgpm.config where parent_table = 'public.hn37'::regclass), 'p/1',
  'LIVENESS: (D) the owner migrated hn37, whose policy does not apply to it');
select is((select string_agg(id || ':' || tenant, ',' order by id) from public.hn37),
  '1:a,2:a,3:b,4:a,5:a,6:b,7:a,8:a,9:b', 'D: hn37 holds every row by identity, tenant b''s included');
select is((select relrowsecurity::text || '/' || relforcerowsecurity from pg_class where oid = 'public.hn37'::regclass),
  'true/false', 'D: and its row-level security came across as it was');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
