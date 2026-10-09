-- A transmute claim records its owner's identity whatever role the session is running as (issue #771
-- bullet 3, reproduced on #1139 bullet 2).
--
-- THE BUG. The claim's owner is (owner_pid, owner_backend_start), and the claim insert read
-- backend_start from pg_stat_activity for its own pid. pg_stat_activity masks backend_start for a backend
-- whose session user the CURRENT role has no privileges of, and under SET ROLE that includes the
-- session's own backend, so a claim taken under SET ROLE recorded owner_backend_start NULL. Every reader
-- then misjudged it: the same session's re-run (#509's arm, owner_backend_start = excluded...) compared
-- NULL with NULL and was refused as "already in progress in another session" until it disconnected, while
-- a reaper with the privileges to see backend_start read the still-connected owner as DEAD and undid its
-- bound out from under it.
--
-- THE CONTRACT pinned here, asymmetrically (four tables, four row counts, four different outcomes):
--   A. control, no SET ROLE (t310s, 170 rows): the claim records the session's real backend_start and
--      the owning session resumes after a cutover failure;
--   B. under SET ROLE (t310r, 150 rows): the claim records the session's real backend_start, not NULL;
--      a privileged reaper leaves it alone while it reaps a dead owner's claim (t310x) in the same sweep;
--      the owning session, still under SET ROLE, resumes;
--   C. the identity still discriminates (t310d, 130 rows): a claim naming THIS session's pid with
--      another backend_start (a dead owner whose pid this session reused) reads as dead from the session
--      itself under SET ROLE and from a privileged one, and the session takes it over; a claim with a
--      NULL start reads as dead from both, so no reader treats an unidentified owner as alive;
--   D. a claim is never taken without an identity (t310n, 110 rows): when backend_start is hidden from
--      the current role AND from pgpm's own identity helper, transmute refuses up front and changes
--      nothing; the same call from the same session goes through once the helper can see it again.
--
-- INSTRUMENT. Every conversion runs in ONE dblink session ('k310', connected as postgres), so "the same
-- session" is literal and the committing procedure commits for real (a CALL inside throws_* would die at
-- its first COMMIT with 2D000). The cutover failure is deterministic: an event trigger commits a table at
-- the staging name on the first attempt's ADD of the bound, the shape of the issue's reproduction.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(38);

-- roles are cluster-wide: create only when absent, drop at the end
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'r310') then create role r310; end if;
  if not exists (select 1 from pg_roles where rolname = 'r310_blind') then create role r310_blind; end if;
end $$;
grant create, usage on schema public to r310;
grant usage on schema pgpm to r310;
grant all on all tables in schema pgpm to r310;
grant all on all sequences in schema pgpm to r310;

create table public.t310s (id bigint primary key, v text not null);
insert into public.t310s select g, 's' || g from generate_series(1, 170) g;
create table public.t310r (id bigint primary key, v text not null);
insert into public.t310r select g, 'r' || g from generate_series(1, 150) g;
alter table public.t310r owner to r310;
create table public.t310d (id bigint primary key, v text not null);
insert into public.t310d select g, 'd' || g from generate_series(1, 130) g;
alter table public.t310d owner to r310;
create table public.t310n (id bigint primary key, v text not null);
insert into public.t310n select g, 'n' || g from generate_series(1, 110) g;
alter table public.t310n owner to r310;
create table public.t310x (id bigint primary key);
alter table public.t310x add constraint pgpm_monolith_bound check (id >= 0 and id < 100) not valid;
create sequence public.w310s_seq;
create sequence public.w310r_seq;
grant all on public.w310s_seq, public.w310r_seq to r310;

create function public.t310_inject() returns event_trigger language plpgsql as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    if r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t310s'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w310s_seq) then
      perform nextval('public.w310s_seq');
      create table public.t310s_pgpm_new (x int);
    elsif r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t310r'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w310r_seq) then
      perform nextval('public.w310r_seq');
      create table public.t310r_pgpm_new (x int);
    end if;
  end loop;
end $$;
create event trigger t310_inject on ddl_command_end execute function public.t310_inject();

select dblink_connect('k310', 'dbname=' || current_database() || ' user=postgres');
select x as k_pid from dblink('k310', 'select pg_backend_pid()') as t(x int) \gset
-- the session's real backend_start, read by this privileged session, which sees every backend's
select backend_start as k_start from pg_stat_activity where pid = :k_pid \gset

-- ===================================== A. control, no SET ROLE =====================================
select throws_like($$select dblink_exec('k310', 'call pgpm.transmute(''public.t310s''::regclass, ''id'', 100::bigint)')$$,
  '%t310s_pgpm_new%', 'GUARD: A: the first attempt on t310s is stopped in its cutover');
select is((select owner_pid::text || ' ' || owner_backend_start::text from pgpm.transmute_inflight
            where parent_table = 'public.t310s'::regclass),
  :k_pid::text || ' ' || :'k_start'::timestamptz::text,
  'A: the claim on t310s records the owning session''s pid and its real backend_start');
drop table public.t310s_pgpm_new;
select lives_ok($$select dblink_exec('k310', 'call pgpm.transmute(''public.t310s''::regclass, ''id'', 100::bigint)')$$,
  'A: the owning session resumes its own claim (#509)');
select is((select relkind::text from pg_class where oid = 'public.t310s'::regclass), 'p',
  'A: t310s is partitioned after the resume');
select is((select array_agg(id order by id) from public.t310s where v = 's' || id),
  (select array_agg(g::bigint order by g) from generate_series(1, 170) g),
  'A: t310s holds ids 1..170 with their own payloads, by identity');

-- ===================================== B. under SET ROLE =====================================
select dblink_exec('k310', 'set role r310');
select is((select x from dblink('k310', 'select current_user::text') as t(x text)), 'r310',
  'LIVENESS: B: the transmuting session runs as r310 via SET ROLE');
select ok((select x from dblink('k310',
            'select backend_start is null from pg_stat_activity where pid = pg_backend_pid()') as t(x boolean)),
  'LIVENESS: B: under SET ROLE pg_stat_activity hides the session''s own backend_start from it (the premise)');
select throws_like($$select dblink_exec('k310', 'call pgpm.transmute(''public.t310r''::regclass, ''id'', 100::bigint)')$$,
  '%t310r_pgpm_new%', 'GUARD: B: the first attempt on t310r is stopped in its cutover');
select is((select owner_pid from pgpm.transmute_inflight where parent_table = 'public.t310r'::regclass), :k_pid,
  'LIVENESS: B: the claim on t310r survived the failure and names the transmuting session''s pid');
select is((select owner_backend_start from pgpm.transmute_inflight where parent_table = 'public.t310r'::regclass),
  :'k_start'::timestamptz,
  'B: the claim taken under SET ROLE records the owning session''s real backend_start, not NULL');

-- the reaper, from this privileged session, sweeps a live claim (t310r) and a dead one (t310x) together:
-- t310x names the same pid with another start, a dead owner whose pid was reused by k310
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, owner_pid, owner_backend_start)
values ('public.t310x'::regclass, 'public', 't310x', 'id', '0', '100', :k_pid, :'k_start'::timestamptz - interval '1 day');
select is((select string_agg(conrelid::regclass::text, ',' order by conrelid::regclass::text) from pg_constraint
            where conname = 'pgpm_monolith_bound' and conrelid in ('public.t310r'::regclass, 'public.t310x'::regclass)),
  't310r,t310x', 'LIVENESS: B: both t310r and t310x carry a bound for the reaper to undo');
select is(pgpm._transmute_reap(), 1, 'B: the reaper undid exactly one claim');
select is((select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.log
            where action = 'transmute_reap'),
  't310x', 'B: it reaped the dead owner''s claim on t310x, by name, and not the live one on t310r');
select is((select string_agg(c.conrelid::regclass::text, ',') from pg_constraint c
            where c.conname = 'pgpm_monolith_bound' and c.conrelid in ('public.t310r'::regclass, 'public.t310x'::regclass)),
  't310r', 'B: the live owner''s bound on t310r is still in place, the dead owner''s on t310x is gone');
select is((select string_agg(parent_table::text, ',' order by parent_table::text) from pgpm.transmute_inflight),
  't310r', 'B: the live owner''s claim on t310r is still there');

drop table public.t310r_pgpm_new;
select lives_ok($$select dblink_exec('k310', 'call pgpm.transmute(''public.t310r''::regclass, ''id'', 100::bigint)')$$,
  'B: the owning session, still under SET ROLE, resumes its own claim (#509)');
select is((select relkind::text from pg_class where oid = 'public.t310r'::regclass), 'p',
  'B: t310r is partitioned after the resume');
select is((select count(*)::int from pgpm.log where parent_table = 'public.t310r'::regclass and action = 'transmute_resume'), 1,
  'B: it RESUMED on the recorded claim');
select is((select array_agg(id order by id) from public.t310r where v = 'r' || id),
  (select array_agg(g::bigint order by g) from generate_series(1, 150) g),
  'B: t310r holds ids 1..150 with their own payloads, by identity');

-- ===================================== C. the identity still discriminates =====================================
create function pg_temp.k_alive(p_start text) returns boolean language sql as $$
  select x from dblink('k310', format('select pgpm._session_alive(pg_backend_pid(), %s)', p_start)) as t(x boolean)
$$;
select ok(pg_temp.k_alive(quote_literal(:'k_start') || '::timestamptz'),
  'LIVENESS: C: under SET ROLE the session reads its own real identity as alive');
select ok(not pg_temp.k_alive(quote_literal(:'k_start') || '::timestamptz - interval ''1 day'''),
  'C: under SET ROLE the session reads its own pid with another backend_start (a reused pid) as dead');
select ok(not pg_temp.k_alive('null'),
  'C: under SET ROLE a claim with a NULL backend_start does not read as alive');
select ok(pgpm._session_alive(:k_pid, :'k_start'::timestamptz),
  'LIVENESS: C: a privileged session reads k310''s real identity as alive');
select ok(not pgpm._session_alive(:k_pid, :'k_start'::timestamptz - interval '1 day'),
  'C: a privileged session reads k310''s pid with another backend_start as dead');
select ok(not pgpm._session_alive(:k_pid, null),
  'C: a privileged session does not read a NULL backend_start as alive');

-- a claim left by a dead owner whose pid k310 now has: the session takes it over rather than being refused
alter table public.t310d add constraint pgpm_monolith_bound check (id >= '0' and id < '200') not valid;
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz, control_attnum,
                                     owner_pid, owner_backend_start)
values ('public.t310d'::regclass, 'public', 't310d', 'id', '0', '200', 'UTC',
        (select attnum from pg_attribute where attrelid = 'public.t310d'::regclass and attname = 'id'),
        :k_pid, :'k_start'::timestamptz - interval '1 day');
select lives_ok($$select dblink_exec('k310', 'call pgpm.transmute(''public.t310d''::regclass, ''id'', 100::bigint)')$$,
  'C: the session under SET ROLE takes over a dead owner''s claim that names its reused pid');
select is((select count(*)::int from pgpm.log where parent_table = 'public.t310d'::regclass and action = 'transmute_resume'), 1,
  'C: it RESUMED on the dead owner''s recorded bound');
select is((select array_agg(id order by id) from public.t310d where v = 'd' || id),
  (select array_agg(g::bigint order by g) from generate_series(1, 130) g),
  'C: t310d holds ids 1..130 with their own payloads, by identity');
select is((select relkind::text from pg_class where oid = 'public.t310d'::regclass), 'p',
  'C: t310d is partitioned');

-- ===================================== D. no claim without an identity =====================================
-- pgpm's identity helper blinded too: owned by a role with no privileges of the session user
select pg_get_userbyid(proowner) as helper_owner from pg_proc where oid = 'pgpm._own_backend_start_definer()'::regprocedure \gset
alter function pgpm._own_backend_start_definer() owner to r310_blind;
select ok((select x is null from dblink('k310', 'select pgpm._own_backend_start()') as t(x timestamptz)),
  'LIVENESS: D: with the helper blinded, the session under SET ROLE cannot obtain its own backend_start');
select throws_like($$select dblink_exec('k310', 'call pgpm.transmute(''public.t310n''::regclass, ''id'', 100::bigint)')$$,
  '%cannot claim the transmute of t310n%backend_start%',
  'D: transmute refuses up front rather than take a claim with no owner identity');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.t310n'::regclass), 0,
  'D: no claim was taken on t310n');
select is((select count(*)::int from pg_constraint where conrelid = 'public.t310n'::regclass and conname = 'pgpm_monolith_bound'), 0,
  'D: no bound was added to t310n');
select is((select relkind::text from pg_class where oid = 'public.t310n'::regclass), 'r',
  'D: t310n is still the plain table it was');
alter function pgpm._own_backend_start_definer() owner to :"helper_owner";
select lives_ok($$select dblink_exec('k310', 'call pgpm.transmute(''public.t310n''::regclass, ''id'', 100::bigint)')$$,
  'LIVENESS: D: with the helper restored, the same call from the same session under SET ROLE converts t310n');
select is((select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.t310n'::regclass), 0,
  'D: and the cutover released the claim it took');
select is((select array_agg(id order by id) from public.t310n where v = 'n' || id),
  (select array_agg(g::bigint order by g) from generate_series(1, 110) g),
  'D: t310n is converted with ids 1..110 and their own payloads, by identity');
select is((select relkind::text from pg_class where oid = 'public.t310n'::regclass), 'p',
  'D: t310n is partitioned');

select dblink_disconnect('k310');
drop event trigger t310_inject;
drop function public.t310_inject();
reassign owned by r310, r310_blind to current_user;
drop owned by r310, r310_blind;
drop role r310;
drop role r310_blind;
select * from finish();
