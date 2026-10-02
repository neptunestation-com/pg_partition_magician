-- transmute read the table under the CALLER's row-level security (issue #825, the transmute half). Its
-- bound reads (min and max of the control column) are ordinary queries, so on a table with FORCE ROW LEVEL
-- SECURITY a non-superuser owner without BYPASSRLS saw only the rows its policies admit: phase 1 committed
-- a NOT VALID pgpm_monolith_bound whose lo sat above the hidden rows, phase 2's VALIDATE (which checks every
-- row) died with a raw 23514, and the bound stayed on the table rejecting every write below lo, a backfill
-- of the hidden tenant included, until an abort. transmute now refuses such a caller up front, before
-- anything is read or committed (pgpm._refuse_filtered_reads, shared with from_hypertable).
--
-- ASYMMETRIC FIXTURE. Seven daily rows, ids 1..7; the three oldest (5, 6, 7: tenant 'old') are hidden from
-- the owner by a FORCE'd policy and the four newest are visible, so a conversion that kept the visible rows
-- and lost the hidden ones, or the reverse, cannot read as the right one.
--
-- INSTRUMENT. The refused conversion runs through dblink, as tests/189 explains: a committing procedure
-- inside throws_* dies at its first COMMIT with 2D000, and the pre-fix code fails LATE, so it must really
-- commit phase 1 for the state assertions (no claim, no bound, a backfill below lo accepted) to
-- discriminate instead of being satisfied by a wrapper's rollback. The refusal is pinned by its message,
-- paired with witnesses that the policy really filters the owner, and with two conversions of the same
-- shape that must still succeed, so a transmute that refused every FORCE'd table, or every table with
-- row-level security, could not pass this file:
--   B. the same owner on a table with row-level security ENABLEd but not FORCEd (the owner bypasses it);
--   C. a superuser (BYPASSRLS) on a FORCE'd table its owner could not fully read, FORCE carried across.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(25);

-- Roles are cluster-wide and the database is per-file, so the role is created only when absent and never
-- dropped (see tests/72 for why a DROP ROLE here would be the worse choice).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't218_owner') then
    create role t218_owner nosuperuser nobypassrls;
  end if;
end $$;
grant create, usage on schema public to t218_owner;
grant usage on schema pgpm to t218_owner;
grant all on all tables in schema pgpm to t218_owner;
grant all on all sequences in schema pgpm to t218_owner;

-- Three tables of the same shape, all owned by t218_owner, all with the same policy: fa218 and fc218 FORCE
-- it, nb218 only ENABLEs it.
set role t218_owner;
create table public.fa218 (id bigint not null, ts timestamptz not null, tenant text not null, primary key (id, ts));
create table public.nb218 (like public.fa218 including all);
create table public.fc218 (like public.fa218 including all);
insert into public.fa218 select g, now() - g * interval '1 day', case when g > 4 then 'old' else 'new' end
  from generate_series(1, 7) g;
insert into public.nb218 select * from public.fa218;
insert into public.fc218 select * from public.fa218;
alter table public.fa218 enable row level security;
alter table public.fa218 force row level security;
create policy fa218_new on public.fa218 using (tenant = 'new');
alter table public.nb218 enable row level security;
create policy nb218_new on public.nb218 using (tenant = 'new');
alter table public.fc218 enable row level security;
alter table public.fc218 force row level security;
create policy fc218_new on public.fc218 using (tenant = 'new');
select string_agg(id::text, ',' order by id) as fa,
       (select string_agg(id::text, ',' order by id) from public.nb218) as nb
  from public.fa218 \gset owner_sees_
reset role;

-- ================= WITNESSES =================
select is((select (not rolsuper and not rolbypassrls)::text from pg_roles where rolname = 't218_owner'), 'true',
  'WITNESS: t218_owner is neither a superuser nor BYPASSRLS');
select is((select string_agg(relname || ':' || pg_get_userbyid(relowner) || ':' || relrowsecurity || '/' || relforcerowsecurity,
                             ',' order by relname)
             from pg_class where oid in ('public.fa218'::regclass, 'public.nb218'::regclass, 'public.fc218'::regclass)),
  'fa218:t218_owner:true/true,fc218:t218_owner:true/true,nb218:t218_owner:true/false',
  'WITNESS: all three are t218_owner''s; fa218 and fc218 FORCE row-level security, nb218 only ENABLEs it');
select is(:'owner_sees_fa'::text, '1,2,3,4',
  'WITNESS: under FORCE the owner sees only the four new rows of fa218, none of the three old ones');
select is(:'owner_sees_nb'::text, '1,2,3,4,5,6,7',
  'WITNESS: without FORCE the owner sees every row of nb218');
select is((select string_agg(id::text, ',' order by id) from public.fa218), '1,2,3,4,5,6,7',
  'WITNESS: fa218 holds all seven rows (read by the harness''s superuser)');

-- ================= A. the owner on a FORCE'd table: refused up front =================
select dblink_connect('t218a', 'dbname=' || current_database());
select dblink_exec('t218a', 'set role t218_owner');
select throws_like(
  $$ select dblink_exec('t218a', $c$ call pgpm.transmute('public.fa218', 'ts', interval '1 day', p_paused => true) $c$) $$,
  'pg_partition_magician: cannot transmute fa218 as t218_owner -- row-level security is active on it for that role (FORCE ROW LEVEL SECURITY holds even the table''s owner to the policies, and the role has no BYPASSRLS)%Run it as a role with BYPASSRLS (or a superuser); nothing was changed.',
  'A: transmute refuses the owner of a FORCE''d table whose reads its policies filter, naming the cause and the remedy');
select dblink_disconnect('t218a');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.fa218'::regclass),
  'A: the refusal left no claim on fa218');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.fa218'::regclass and conname = 'pgpm_monolith_bound'),
  'A: the refusal left no pgpm_monolith_bound CHECK on fa218');
select is((select relkind::text || '/' || (select count(*) from pgpm.config where parent_table = 'public.fa218'::regclass)
             from pg_class where oid = 'public.fa218'::regclass), 'r/0',
  'A: fa218 is still a plain table, and pgpm does not manage it');
select is((select string_agg(id || ':' || tenant, ',' order by id) from public.fa218),
  '1:new,2:new,3:new,4:new,5:old,6:old,7:old', 'A: fa218 holds every row it held, by identity');
select lives_ok($$ insert into public.fa218 values (100, now() - interval '6 days 1 hour', 'old') $$,
  'A: a backfill row for the hidden tenant, below every row the owner can see, is still accepted');
select is((select relrowsecurity::text || '/' || relforcerowsecurity from pg_class where oid = 'public.fa218'::regclass),
  'true/true', 'A: and fa218 keeps its row-level security, FORCE included');
select is((select count(*)::int from pgpm.log where parent_table = 'public.fa218'::regclass), 0,
  'A: the refused conversion wrote nothing to pgpm.log');

-- ================= B. the same owner, row-level security ENABLEd but not FORCEd: converts =================
set role t218_owner;
call pgpm.transmute('public.nb218', 'ts', interval '1 day', p_paused => true);
reset role;
select is((select relkind::text || '/' || (select count(*) from pgpm.config where parent_table = 'public.nb218'::regclass)
             from pg_class where oid = 'public.nb218'::regclass), 'p/1',
  'B LIVENESS: the owner converted nb218, whose policy does not apply to it');
select is((select string_agg(id || ':' || tenant, ',' order by id) from public.nb218),
  '1:new,2:new,3:new,4:new,5:old,6:old,7:old', 'B: nb218 holds every row by identity, the old tenant''s included');
select is((select relrowsecurity::text || '/' || relforcerowsecurity from pg_class where oid = 'public.nb218'::regclass),
  'true/false', 'B: and its row-level security came across as it was');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.nb218'::regclass and conname = 'pgpm_monolith_bound'),
  'B: the conversion completed: no pgpm_monolith_bound CHECK is left on the parent');

-- ================= C. a superuser on a FORCE'd table: converts, FORCE carried =================
select is((select (rolsuper or rolbypassrls)::text from pg_roles where rolname = current_user), 'true',
  'C WITNESS: the converting role (the harness''s) bypasses row-level security');
call pgpm.transmute('public.fc218', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text || '/' || (select count(*) from pgpm.config where parent_table = 'public.fc218'::regclass)
             from pg_class where oid = 'public.fc218'::regclass), 'p/1',
  'C LIVENESS: a role that bypasses row-level security converted the FORCE''d fc218');
select is((select string_agg(id || ':' || tenant, ',' order by id) from public.fc218),
  '1:new,2:new,3:new,4:new,5:old,6:old,7:old', 'C: fc218 holds every row by identity, the three its owner cannot see included');
select is((select relrowsecurity::text || '/' || relforcerowsecurity from pg_class where oid = 'public.fc218'::regclass),
  'true/true', 'C: and FORCE came across with it');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.fc218'::regclass and conname = 'pgpm_monolith_bound'),
  'C: the conversion completed: no pgpm_monolith_bound CHECK is left on the parent');
set role t218_owner;
select string_agg(id::text, ',' order by id) as fc from public.fc218 \gset owner_after_
reset role;
select is(:'owner_after_fc'::text, '1,2,3,4', 'C: the converted fc218 still holds its owner to the policy');
select lives_ok($$ insert into public.fc218 values (100, now() - interval '6 days 1 hour', 'old') $$,
  'C: and a backfill below the owner''s visible rows lands in the converted table');
select is((select string_agg(tableoid::regclass::text, ',') from public.fc218 where id = 100),
  (select string_agg(tableoid::regclass::text, ',') from public.fc218 where id = 7),
  'C: in the monolith partition, beside the oldest row the owner could not see');

select * from finish();
