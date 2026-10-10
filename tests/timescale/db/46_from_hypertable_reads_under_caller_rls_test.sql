-- The hypertable module's half of the RLS conformance suite (issue #873; tests/241 is the core's). Every
-- phase that reads the source as the caller asks pgpm._refuse_filtered_reads of it first. The preflight
-- (so from_hypertable and from_hypertable_copy) and the cutover's up-front check are #825's
-- (tests/timescale/db/37). This file adds the online drains, which copy the source's tail or re-read the
-- rows its tracked changes name into the destination: the steps and the append drain's own residual
-- check read the source as the caller, so under row-level security that filters it a hidden row's change
-- was consumed and never applied, or a tail it hid entirely read as nothing to drain. The cutover's second
-- asking, UNDER its lock, needs a second session that commits the policy while the cutover waits; that is
-- bench/reads_under_caller_rls.sh's part H, the verifier's reproduction for #873 bullet 3.
--
-- EXHAUSTIVENESS. Part Z enumerates every public routine of this module (pgpm.from_hypertable*) from the
-- catalog and requires each to be classified, so a new phase fails this file until it is.
--
-- ASYMMETRIC FIXTURES. ha46: six rows copied (tenant a), then two rows appended past the copy's watermark,
-- both tenant b, which the owner's policy hides: the whole tail is hidden, so a drain that read through the
-- policy would find nothing to do and say so by returning. hd46: six rows, two of them (ids 2, 5) updated
-- after a tracking copy, one to tenant b (hidden) and one kept tenant a (visible), so the delta names one
-- row the owner can re-read and one it cannot.
--
-- INSTRUMENT. tests/timescale/db/37's: the refused calls run as the owner through a SECURITY DEFINER
-- function the owner owns, where a committing procedure that does NOT refuse dies at its first COMMIT
-- with 2D000; the message pins tell the refusal apart from that. The steps are functions and commit
-- nothing, so a step that does not refuse runs to its end and the state assertions after it see what it
-- did. LIVENESS: the same steps, run by the harness's BYPASSRLS role on twins of both tables (so nothing
-- the owner's calls did can bear on it), drain every row.
select plan(16);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't46_owner') then
    create role t46_owner nosuperuser nobypassrls;
  end if;
end $$;
-- Named, not CURRENT_USER: the fleet image's GRANT hook crashes the backend on that role spec (tests/33).
grant t46_owner to postgres;
grant create, usage on schema public to t46_owner;
grant usage on schema pgpm to t46_owner;
grant all on all tables in schema pgpm to t46_owner;
grant all on all sequences in schema pgpm to t46_owner;

-- Created AS t46_owner rather than handed to it, for the reason tests/33 gives.
set role t46_owner;
create table public.ha46 (id bigint not null, ts timestamptz not null, tenant text not null, primary key (id, ts));
select create_hypertable('public.ha46', 'ts', chunk_time_interval => interval '1 day');
insert into public.ha46 select g, now() - (10 - g) * interval '8 hours', 'a' from generate_series(1, 6) g;
create table public.hd46 (id bigint not null, ts timestamptz not null, tenant text not null, primary key (id, ts));
select create_hypertable('public.hd46', 'ts', chunk_time_interval => interval '1 day');
insert into public.hd46 select g, now() - (10 - g) * interval '8 hours', 'a' from generate_series(1, 6) g;
-- Their twins, for the LIVENESS half: the same shape and rows, drained by a role the lever passes, so what
-- a drain that did not refuse the owner did to ha46 and hd46 cannot bear on it.
create table public.ha46l (like public.ha46 including all);
select create_hypertable('public.ha46l', 'ts', chunk_time_interval => interval '1 day');
insert into public.ha46l select * from public.ha46;
create table public.hd46l (like public.hd46 including all);
select create_hypertable('public.hd46l', 'ts', chunk_time_interval => interval '1 day');
insert into public.hd46l select * from public.hd46;
create function public.t46_as_owner(p_sql text) returns void language plpgsql security definer as $f$
begin execute p_sql; end $f$;
reset role;

-- The copies, by the harness's role; then the online window: two appends past ha46's watermark, two
-- tracked updates of hd46.
call pgpm.from_hypertable_copy('public.ha46', 'ts', p_track_changes => false);
call pgpm.from_hypertable_copy('public.hd46', 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('public.ha46l', 'ts', p_track_changes => false);
call pgpm.from_hypertable_copy('public.hd46l', 'ts', p_track_changes => true);
insert into public.ha46 values (7, now() - interval '1 hour', 'b'), (8, now(), 'b');
insert into public.ha46l select * from public.ha46 where id > 6;
update public.hd46 set tenant = 'b' where id = 2;
update public.hd46 set tenant = 'a' where id = 5;
update public.hd46l set tenant = 'b' where id = 2;
update public.hd46l set tenant = 'a' where id = 5;
-- The copies and the delta are the harness's; the owner is given them, so that a drain which does not
-- refuse reaches its reads and writes rather than stopping at a privilege error.
grant all on public.ha46_pgpm_dest, public.hd46_pgpm_dest, public.hd46_pgpm_delta to t46_owner;
set role t46_owner;
alter table public.ha46 enable row level security;
alter table public.ha46 force row level security;
create policy ha46_a on public.ha46 using (tenant = 'a');
alter table public.hd46 enable row level security;
alter table public.hd46 force row level security;
create policy hd46_a on public.hd46 using (tenant = 'a');
alter table public.ha46l enable row level security;
alter table public.ha46l force row level security;
create policy ha46l_a on public.ha46l using (tenant = 'a');
alter table public.hd46l enable row level security;
alter table public.hd46l force row level security;
create policy hd46l_a on public.hd46l using (tenant = 'a');
select string_agg(id::text, ',' order by id) as ha, (select string_agg(id::text, ',' order by id) from public.hd46) as hd
  from public.ha46 \gset owner_sees_
reset role;
select pgpm._from_hypertable_ctl_text(max(ts)) as wm from public.ha46_pgpm_dest \gset
select pgpm._from_hypertable_ctl_text(max(ts)) as wm_l from public.ha46l_pgpm_dest \gset
select count(*) as delta_n from public.hd46_pgpm_delta \gset

-- ================= WITNESSES =================
select is((select (not rolsuper and not rolbypassrls)::text from pg_roles where rolname = 't46_owner')
          || '/' || (select rolbypassrls::text from pg_roles where rolname = current_user), 'true/true',
  'LIVENESS: t46_owner is neither a superuser nor BYPASSRLS, and the harness''s role is BYPASSRLS');
select is(:'owner_sees_ha'::text || '/' || (select string_agg(id || ':' || tenant, ',' order by id) from public.ha46),
  '1,2,3,4,5,6/1:a,2:a,3:a,4:a,5:a,6:a,7:b,8:b',
  'LIVENESS: ha46 holds rows 7 and 8 past the copy, and the owner sees neither');
select is((select string_agg(id::text, ',' order by id) from public.ha46_pgpm_dest), '1,2,3,4,5,6',
  'LIVENESS: ha46''s copy holds the six rows it was made from');
select is(:'owner_sees_hd'::text || '/' || :'delta_n'::text, '1,3,4,5,6/4',
  'LIVENESS: the owner cannot see hd46''s row 2, and the delta holds the two updates'' four entries');

-- ================= the append drain =================
select throws_like(format($$ select public.t46_as_owner('select pgpm.from_hypertable_drain_appends_step(''public.ha46'', ''ts'', 100, ''%s'')') $$,
                          :'wm'),
  'pg_partition_magician: cannot drain appends from hypertable ha46 as t46_owner -- row-level security is active on it for that role (FORCE ROW LEVEL SECURITY holds even the table''s owner to the policies, and the role has no BYPASSRLS)%the copy would be brought up to date with those rows alone. Run it as a role with BYPASSRLS (or a superuser); nothing was changed.',
  'drain_appends_step refuses the owner, whose policy hides the whole tail');
select throws_like($$ select public.t46_as_owner('call pgpm.from_hypertable_drain_appends(''public.ha46'', ''ts'')') $$,
  'pg_partition_magician: cannot drain appends from hypertable ha46 as t46_owner -- row-level security is active on it%',
  'from_hypertable_drain_appends refuses too, before its own residual check reads the tail as nothing');
select is((select string_agg(id::text, ',' order by id) from public.ha46_pgpm_dest), '1,2,3,4,5,6',
  'the copy is as it was');

-- ================= the change drain =================
select throws_like($$ select public.t46_as_owner('select pgpm.from_hypertable_drain_delta_step(''public.hd46'', ''ts'')') $$,
  'pg_partition_magician: cannot drain changes from hypertable hd46 as t46_owner -- row-level security is active on it for that role%the copy would be brought up to date with those rows alone%',
  'drain_delta_step refuses the owner, who cannot re-read row 2');
select throws_like($$ select public.t46_as_owner('call pgpm.from_hypertable_drain_delta(''public.hd46'', ''ts'')') $$,
  'pg_partition_magician: cannot drain changes from hypertable hd46 as t46_owner -- row-level security is active on it%',
  'from_hypertable_drain_delta refuses through its step');
select is((select count(*)::int from public.hd46_pgpm_delta), :'delta_n'::int,
  'no tracked change was consumed');
select is((select string_agg(id || ':' || tenant, ',' order by id) from public.hd46_pgpm_dest),
  '1:a,2:a,3:a,4:a,5:a,6:a', 'and the copy still holds what it was made from');

-- ================= LIVENESS: a role the lever passes drains every row (on the twins) =================
select is(pgpm.from_hypertable_drain_appends_step('public.ha46l', 'ts', 100, :'wm_l') is distinct from :'wm_l', true,
  'LIVENESS: the harness''s role drains ha46l''s tail');
select is((select string_agg(id::text, ',' order by id) from public.ha46l_pgpm_dest), '1,2,3,4,5,6,7,8',
  'LIVENESS: rows 7 and 8, the ones the owner''s policy hides, are in the copy');
select is(pgpm.from_hypertable_drain_delta_step('public.hd46l', 'ts'), 2::bigint,
  'LIVENESS: and drains hd46l''s two changed keys');
select is((select string_agg(id || ':' || tenant, ',' order by id) from public.hd46l_pgpm_dest),
  '1:a,2:b,3:a,4:a,5:a,6:a', 'LIVENESS: row 2''s change, the one the owner cannot read, is applied');

-- ================= Z. every phase of the module is classified =================
create temp table t46_entry (sig text primary key, verdict text not null, what text not null);
insert into t46_entry values
  ('pgpm.from_hypertable_disk_estimate(regclass)', 'no user rows', 'chunk sizes from the catalog'),
  ('pgpm.from_hypertable_time_estimate(regclass,numeric)', 'no user rows', 'the disk estimate and a setting'),
  ('pgpm.from_hypertable_preflight(regclass,name)', 'refuses', 'the hypertable it would copy (#825, tests/timescale/db/37)'),
  ('pgpm.from_hypertable_copy(regclass,name,boolean)', 'refuses', 'the hypertable, through the preflight (#825)'),
  ('pgpm.from_hypertable_drain_delta_step(regclass,name,integer)', 'refuses', 'the rows its batch of changes names (above)'),
  ('pgpm.from_hypertable_drain_delta(regclass,name,integer,bigint,integer,boolean)', 'refuses', 'through its step (above); its own loop reads only the delta'),
  ('pgpm.from_hypertable_drain_appends_step(regclass,name,integer,text)', 'refuses', 'the tail past the watermark (above)'),
  ('pgpm.from_hypertable_drain_appends(regclass,name,integer,bigint,integer,boolean)', 'refuses', 'the tail, for its residual check (above)'),
  ('pgpm.from_hypertable_cutover(regclass,name,interval,integer,interval,integer,timestamp with time zone,boolean,boolean,text,boolean)', 'refuses',
   'the hypertable, up front (#825) and again under its lock (bench/reads_under_caller_rls.sh part H)'),
  ('pgpm.from_hypertable(regclass,name,interval,integer,interval,integer,timestamp with time zone,boolean,boolean,boolean,text,boolean)', 'refuses',
   'through the preflight and the cutover (#825)');
select set_eq(
  $$ select p.oid::regprocedure::text from pg_proc p where p.pronamespace = 'pgpm'::regnamespace and p.proname like 'from\_hypertable%' $$,
  $$ select sig from t46_entry $$,
  'Z: every public routine of the hypertable module is classified here (a new one fails this until it is)');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
