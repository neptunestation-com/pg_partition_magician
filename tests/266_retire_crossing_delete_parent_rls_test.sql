-- retire()'s crossing DELETE reads the PARENT under the caller's row-level security (issue #890, the "Reads
-- under RLS" bullet; the class of #873, PR #888).
--
-- When a live row references a row in a retiring partition, retire() deletes the referenced rows of the
-- partition through the parent, so PostgreSQL applies each foreign key's declared ON DELETE, and then
-- dispatches the detach. #873 asked pgpm._refuse_filtered_reads of the REFERENCING tables, whose keys
-- _crossing_keys reads, but not of the parent the DELETE reads. On a time grid nothing else reads the parent
-- first (the frontier is now()), so a non-BYPASSRLS owner of a FORCE ROW LEVEL SECURITY parent deleted only
-- the referenced rows its policy admits: the declared CASCADE reached the referencing rows of those keys
-- alone, the hidden keys kept theirs, the call logged retain_crossing and retain_detach, and the dispatched
-- detach could never succeed (a stall, retried every tick). The contract: retire() asks the lever of the
-- parent before the DELETE, and refuses with pgpm's own message, changing nothing.
--
-- ASYMMETRIC FIXTURE. The doomed partition (the monolith, on a one-second grid) holds ids 1 to 4; the
-- owner's policy admits 1 and 2 and hides 3 and 4. The referencing table points one row at id 1 (visible)
-- and two at id 3 (hidden), so the filtered DELETE (id 1 and its one referencing row) cannot pass for the
-- whole one (ids 1 and 3 and all three referencing rows), and neither can pass for nothing at all.
--
-- WITNESSES. The refusal asserted is the parent's: the referencing table does not filter the owner, so
-- _crossing_keys' own refusal cannot stand in for it, and the partition is past the horizon, so retire()
-- reached the crossing. The positive half is witnessed on the same fixture by the same owner: once the
-- parent is set NO FORCE (row-level security then does not filter its owner, the remedy an operator without
-- BYPASSRLS has), the same retire() runs the whole crossing, so the DELETE the refusal prevented was
-- reachable with the same grants and the same pg_cron stand-in.
--
-- INSTRUMENT. The refused call runs as the owner through a SECURITY DEFINER function the owner owns
-- (tests/241's pattern: pgTAP's temp tables belong to the harness's role, so `set role` around throws_*
-- cannot work). retire() is a function, so throws_like is pinned by its message and cannot be satisfied by
-- a committing procedure's 2D000.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(12);

-- Roles are cluster-wide and the database is per-file: created only when absent, never dropped (tests/72).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't266_owner') then
    create role t266_owner nosuperuser nobypassrls;
  end if;
end $$;
grant create, usage on schema public to t266_owner;
grant usage on schema pgpm to t266_owner;
grant all on all tables in schema pgpm to t266_owner;
grant all on all sequences in schema pgpm to t266_owner;

-- pg_cron lives only in the postgres database on the harness: a stand-in for cron.job / cron.alter_job, as
-- tests/194, 204 and 229 bring, so a retire() that gets past the crossing can dispatch its detach.
create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');
grant usage on schema cron to t266_owner;
grant all on cron.job to t266_owner;

set role t266_owner;
create function public.t266_as_owner(p_sql text) returns void language plpgsql security definer as $f$
begin execute p_sql; end $f$;

-- rp266, on a one-second grid, with ids 1 to 4 ten seconds in the past, so the monolith that takes them ends
-- one cell past now() and falls behind a one-second horizon within seconds. Converted by the owner before any
-- policy exists, as an operator would; the policy goes on the parent afterwards, so only a read THROUGH the
-- parent filters (the monolith carries none).
create table public.rp266 (id bigint, ts timestamptz, tenant text not null, primary key (id, ts));
insert into public.rp266
select g, clock_timestamp() - interval '10 seconds' + make_interval(secs => g / 1000.0),
       case when g in (1, 2) then 'vis' else 'hid' end
  from generate_series(1, 4) g;
call pgpm.transmute('public.rp266', 'ts', interval '1 second', p_obtain => 4, p_retain => interval '1 second', p_paused => true);

-- One referencing row at id 1 (visible), two at id 3 (hidden), in a table row-level security does not touch.
create table public.rpr266 (id bigint primary key, p_id bigint not null, p_ts timestamptz not null,
                            foreign key (p_id, p_ts) references public.rp266 (id, ts) on delete cascade);
insert into public.rpr266 select 100, id, ts from public.rp266 where id = 1;
insert into public.rpr266 select 300 + n, id, ts from public.rp266, generate_series(0, 1) n where id = 3;

alter table public.rp266 enable row level security;
alter table public.rp266 force row level security;
create policy rp266_vis on public.rp266 using (tenant = 'vis');

select (select string_agg(id::text, ',' order by id) from public.rp266) as rp_sees,
       row_security_active('public.rp266')::text as rp_rls,
       row_security_active('public.rpr266')::text as rpr_rls
\gset owner_
reset role;

select child_name as rp_mono, hi as rp_hi from pgpm.part
 where parent_table = 'public.rp266'::regclass
   and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.rp266'::regclass) \gset

-- Until the monolith sits wholly behind the one-second horizon (its hi, plus the retention, plus a margin).
select pg_sleep(greatest(0, extract(epoch from (:'rp_hi'::timestamptz + interval '1.5 seconds' - clock_timestamp()))));

-- ================= WITNESSES =================
select is((select (not rolsuper and not rolbypassrls)::text from pg_roles where rolname = 't266_owner')
          || '/' || :'owner_rp_sees' || '/' || (select string_agg(id::text, ',' order by id) from public.rp266),
  'true/1,2/1,2,3,4',
  'LIVENESS: t266_owner is neither a superuser nor BYPASSRLS, and sees ids 1 and 2 of rp266''s 1 to 4');
select is(:'owner_rp_rls' || '/' || :'owner_rpr_rls', 'true/false',
  'LIVENESS: row-level security filters the owner on the parent and not on the referencing table, so the refusal below can only be the parent''s');
select is((select string_agg(p_id || '<-' || id, ',' order by id) from public.rpr266)
          || '/' || (select string_agg(id::text, ',' order by id) from public.rp266 where tableoid = format('public.%I', :'rp_mono')::regclass),
  '1<-100,3<-300,3<-301/1,2,3,4',
  'LIVENESS: ids 1 to 4 sit in rp266''s monolith, id 1 referenced once and id 3 twice');
select ok(not pgpm._native_gt('time', :'rp_hi', pgpm._retain_boundary((select c from pgpm.config c where parent_table = 'public.rp266'::regclass))),
  'LIVENESS: the monolith is past the retention horizon, so retire() reaches the crossing');

-- ================= THE REFUSAL =================
select throws_like(format($$ select public.t266_as_owner('select pgpm.retire(''public.rp266'', ''%s'')') $$, :'rp_mono'),
  'pg_partition_magician: cannot delete the referenced rows of a retiring partition from rp266 as t266_owner -- row-level security is active on it for that role (FORCE ROW LEVEL SECURITY holds even the table''s owner to the policies, and the role has no BYPASSRLS)%the detach would then be refused by the others. Run it as a role with BYPASSRLS (or a superuser); nothing was changed.',
  'retire() refuses the owner whose policies on the parent would filter the crossing DELETE');
select is((select string_agg(id::text, ',' order by id) from public.rp266)
          || '/' || (select string_agg(p_id || '<-' || id, ',' order by id) from public.rpr266),
  '1,2,3,4/1<-100,3<-300,3<-301',
  'every parent row and every referencing row is where it was: no filtered DELETE, no partial CASCADE');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'public.rp266'::regclass
             and action in ('retain_crossing', 'fail_retain_crossing', 'retain_detach')), null,
  'no crossing, failed crossing or detach was logged');
select is((select (retiring_at is null and attached)::text from pgpm.part where parent_table = 'public.rp266'::regclass and child_name = :'rp_mono')
          || '/' || (select command from cron.job where jobid = 1),
  'true/select 1',
  'the monolith is still attached and unmarked, and no detach was dispatched');

-- ================= LIVENESS: the DELETE the refusal prevented was reachable =================
-- The owner's own remedy without BYPASSRLS: NO FORCE, after which row-level security does not filter it.
set role t266_owner;
alter table public.rp266 no force row level security;
select row_security_active('public.rp266')::text as rp_rls_noforce \gset owner_
reset role;
select is(:'owner_rp_rls_noforce'::text, 'false', 'LIVENESS: with the parent set NO FORCE, row-level security no longer filters its owner');
select lives_ok(format($$ select public.t266_as_owner('select pgpm.retire(''public.rp266'', ''%s'')') $$, :'rp_mono'),
  'LIVENESS: the same retire(), as the same owner, is then not refused');
select is((select string_agg(id::text, ',' order by id) from public.rp266)
          || '/' || coalesce((select string_agg(id::text, ',' order by id) from public.rpr266), 'none')
          || '/' || (select method from pgpm.log where parent_table = 'public.rp266'::regclass and action = 'retain_crossing'),
  '2,4/none/2 referenced key(s), 2 row(s) deleted to honour the declared ON DELETE',
  'LIVENESS: its crossing deleted ids 1 and 3, hidden one included, and the CASCADE all three referencing rows');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'public.rp266'::regclass
             and action in ('retain_crossing', 'fail_retain_crossing', 'retain_detach')), array['retain_crossing', 'retain_detach'],
  'LIVENESS: and it logged the crossing and dispatched the detach');

select * from finish();
