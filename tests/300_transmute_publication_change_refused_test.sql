-- Issues #766 (bullet 4) and #1105 (bullet 2): the publication refusals, a row filter or a column list in a
-- publication with publish_via_partition_root = false (#566) and a publication the caller does not own
-- (#710), are asked again by the cutover's step 7c from its own failure, so a publication change committed
-- after the preflight is refused in pgpm's words whenever it lands.
--
-- They were asked in the preflight only. A publication change committed after it reached step 7c, whose
-- ALTER PUBLICATION ... ADD TABLE of the new parent died raw ("cannot use publication WHERE clause for
-- relation", or "must be owner of publication"), after phases 1 and 2 had committed the write-rejecting bound
-- and the claim, naming neither pgpm nor the remedy. No lock the cutover holds excludes every such change:
-- its ACCESS EXCLUSIVE keeps a new membership out (that takes SHARE UPDATE EXCLUSIVE on the table), but ALTER
-- PUBLICATION ... SET (publish_via_partition_root = false) and OWNER TO take no lock on the table, and one can
-- commit while the cutover waits in step 7a for a lock on a referenced table. So 7c's failure is what asks
-- again; the refusal rolls the cutover back to the resumable phase-2 state.
--
-- Two kinds of window. (A) and (B) are opened the way tests/283 opens its own: an event trigger on phase 1's
-- ADD of pgpm_monolith_bound (after the preflight, in the transaction that commits the bound) creates the
-- publication, in the transmuting session, so it commits with phase 1. The trigger function is SECURITY
-- DEFINER, so the publication it creates is the superuser's even when the transmuting session is not. (C) is
-- opened INSIDE the cutover: a second dblink session (k300) holds a writer's ROW EXCLUSIVE on the table t300c
-- references, waits server-side until the cutover, holding t300c's ACCESS EXCLUSIVE, queues behind it in step
-- 7a, then turns publish_via_partition_root off on t300c's filtered publication and commits. The transmute
-- runs over dblink, as a top-level CALL whose phases can commit. Fixtures, asymmetric on purpose:
--   (A) t300a, converted by the superuser: in pub300_plain (no filter) from the start; pub300_rf, a row
--       filter, arrives; refused naming pub300_rf and only it; with publish_via_partition_root set on it, the
--       re-run converts and the parent is in both, the filter kept;
--   (B) t300b, owned and converted by t300_converter: in pub300_mine (the converter's) from the start;
--       pub300_admin (the superuser's) arrives; refused naming pub300_admin and only it; handed to the
--       converter, the re-run converts and the parent is in both;
--   (C) t300c: in pub300_vr with a row filter and publish_via_partition_root = true from the start, which
--       both the preflight and any earlier asking accept; the flag turned off inside the cutover; refused
--       naming pub300_vr; with the flag back on, the re-run converts and the parent keeps the filter.
-- Every refusal is pinned by its message (throws_like), and each is paired with witnesses that the window
-- opened (once), that its change committed, and that phases 1 and 2 had committed before the refusal.
-- bench/transmute_publication_change_refused.sh runs this file against the mutant that drops step 7c's second
-- asking (transmute_publication_preflight_only).
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(32);

set timezone = 'UTC';
set client_min_messages = warning;   -- CREATE PUBLICATION warns under wal_level = replica

-- Roles are cluster-wide: created only when absent, dropped at the end with what they own.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't300_converter') then create role t300_converter; end if;
end $$;

create table public.t300a (id bigint primary key, v text not null);
insert into public.t300a select g, 'a' || g from generate_series(1, 150) g;   -- step 100: monolith [0, 200)
create publication pub300_plain for table public.t300a;

create table public.t300b (id bigint primary key, v text not null);
insert into public.t300b select g, 'b' || g from generate_series(1, 250) g;   -- step 100: monolith [0, 300)
alter table public.t300b owner to t300_converter;
create publication pub300_mine for table public.t300b;
alter publication pub300_mine owner to t300_converter;
grant usage, create on schema public to t300_converter;
grant usage on schema pgpm to t300_converter;
grant all on all tables in schema pgpm to t300_converter;
grant all on all sequences in schema pgpm to t300_converter;

-- (C): t300c references r300, so the cutover's step 7a re-adds that key under SHARE ROW EXCLUSIVE on r300,
-- which waits behind any writer there while the cutover holds t300c
create table public.r300 (id bigint primary key);
insert into public.r300 select g from generate_series(1, 10) g;
create table public.t300c (id bigint primary key, r bigint not null references public.r300 (id), v text not null);
insert into public.t300c select g, 1 + g % 10, 'c' || g from generate_series(1, 130) g;   -- step 100: [0, 200)
create publication pub300_vr for table public.t300c where (id > 0) with (publish_via_partition_root = true);

-- The flip inside the cutover, run by k300 as ONE statement (its transaction, and the writer's lock on r300,
-- last until it returns): wait until a backend holding p_rel's ACCESS EXCLUSIVE queues for SHARE ROW
-- EXCLUSIVE on r300, turn the flag off, record whether the wait was seen, and return, which commits both.
create table public.w300_seen (tag text primary key, saw boolean not null);
create function public.t300_flip_in_cutover(p_rel regclass) returns void language plpgsql as $$
declare v_saw boolean := false;
begin
  lock table public.r300 in row exclusive mode;
  for i in 1 .. 1200 loop
    v_saw := exists (select 1 from pg_locks w join pg_locks h on h.pid = w.pid
                      where w.relation = 'public.r300'::regclass and not w.granted and w.mode = 'ShareRowExclusiveLock'
                        and h.relation = p_rel and h.granted and h.mode = 'AccessExclusiveLock');
    exit when v_saw;
    perform pg_sleep(0.05);
  end loop;
  alter publication pub300_vr set (publish_via_partition_root = false);
  insert into public.w300_seen values ('C', v_saw);
end $$;
create function public.t300_await_hold(p_pid int) returns boolean language plpgsql as $$
begin
  for i in 1 .. 400 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = p_pid and wait_event = 'PgSleep') then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

-- a refusal rolls the cutover back but not a nextval, so each window witnesses on its own sequence
create sequence public.w300a_seq;
create sequence public.w300b_seq;

create function public.t300_inject() returns event_trigger language plpgsql security definer as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    -- phase 1's ADD of the bound: after the preflight, committed with the bound. Once each. By objid, not
    -- by a name cast: the cutover's rename is an ALTER TABLE too, and the name is gone by its end.
    if r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t300a'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w300a_seq) then
      perform nextval('public.w300a_seq');
      create publication pub300_rf for table public.t300a where (id > 0);
    elsif r.command_tag = 'ALTER TABLE' and r.object_identity = 'public.t300b'
       and exists (select 1 from pg_constraint where conrelid = r.objid and conname = 'pgpm_monolith_bound')
       and not (select is_called from public.w300b_seq) then
      perform nextval('public.w300b_seq');
      create publication pub300_admin for table public.t300b;
    end if;
  end loop;
end $$;
grant usage on sequence public.w300b_seq to t300_converter;
create event trigger t300_inject on ddl_command_end when tag in ('ALTER TABLE') execute function public.t300_inject();

select dblink_connect('t300a', 'dbname=' || current_database());
select dblink_connect('t300b', 'dbname=' || current_database());
select dblink_exec('t300b', 'set role t300_converter');

-- ====================================================================================================
-- (A) a row-filtered publication committed after the preflight
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t300a', 'call pgpm.transmute(''public.t300a'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'pg_partition_magician: cannot transmute t300a -- the publication(s) (pub300_rf) name it with a row filter or a column list%',
  '(A) the cutover refuses the row-filtered publication committed after the preflight, naming it and only it, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w300a_seq), '1:true',
  'LIVENESS: (A) the window created the publication once, inside phase 1');
select is((select string_agg(p.pubname || '=' || (r.prqual is not null), ' ' order by p.pubname)
             from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
            where r.prrelid = 'public.t300a'::regclass),
  'pub300_plain=false pub300_rf=true',
  'LIVENESS: (A) pub300_rf names t300a with a row filter, committed with phase 1, beside pub300_plain');
select is((select convalidated from pg_constraint where conrelid = 'public.t300a'::regclass and conname = 'pgpm_monolith_bound'), true,
  'LIVENESS: (A) phase 2 validated the bound before the cutover');
select is((select relkind::text from pg_class where oid = 'public.t300a'::regclass), 'r',
  '(A) t300a is still the plain table');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t300a'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t300a'::regclass),
  '(A) the claim stands and nothing was registered: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t300a', 'alter publication pub300_rf set (publish_via_partition_root = true)') $$,
  'LIVENESS: (A) the operator takes the remedy the refusal names, publish_via_partition_root = true');
select lives_ok(
  $$ select dblink_exec('t300a', 'call pgpm.transmute(''public.t300a'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(A) the re-run resumes and converts t300a');
select is((select relkind::text from pg_class where oid = 'public.t300a'::regclass), 'p',
  'LIVENESS: (A) t300a is partitioned now');
select is((select string_agg(p.pubname || '=' || coalesce(pg_get_expr(r.prqual, r.prrelid), '-'), ' ' order by p.pubname)
             from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
            where r.prrelid = 'public.t300a'::regclass),
  'pub300_plain=- pub300_rf=(id > 0)',
  '(A) the new parent is in both publications, and pub300_rf keeps its row filter');
select lives_ok($$ insert into public.t300a values (210, 'past') $$, 'LIVENESS: (A) a row past the monolith is accepted');
select is((select array_agg(id order by id) from public.t300a where id > 148), array[149, 150, 210]::bigint[],
  '(A) the rows are the ones written');

-- ====================================================================================================
-- (B) a publication the converting role does not own, committed after the preflight
-- ====================================================================================================
select throws_like(
  $$ select dblink_exec('t300b', 'call pgpm.transmute(''public.t300b'', ''id'', 100::bigint, p_obtain => 2)') $$,
  'pg_partition_magician: cannot transmute t300b as t300_converter -- the publication(s) (pub300_admin) name it,%',
  '(B) the cutover refuses the publication the caller does not own, committed after the preflight, naming it and only it, in pgpm''s words');
select is((select last_value::int || ':' || is_called::text from public.w300b_seq), '1:true',
  'LIVENESS: (B) the window created the publication once, inside phase 1');
select is((select string_agg(p.pubname || '=' || pg_get_userbyid(p.pubowner), ' ' order by p.pubname)
             from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
            where r.prrelid = 'public.t300b'::regclass),
  'pub300_admin=postgres pub300_mine=t300_converter',
  'LIVENESS: (B) pub300_admin (the superuser''s) names t300b, committed with phase 1, beside the converter''s pub300_mine');
select is((select convalidated from pg_constraint where conrelid = 'public.t300b'::regclass and conname = 'pgpm_monolith_bound'), true,
  'LIVENESS: (B) phase 2 validated the bound before the cutover');
select is((select relkind::text from pg_class where oid = 'public.t300b'::regclass), 'r',
  '(B) t300b is still the plain table');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t300b'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t300b'::regclass),
  '(B) the claim stands and nothing was registered: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t300a', 'alter publication pub300_admin owner to t300_converter') $$,
  'LIVENESS: (B) the publication''s owner takes the remedy the refusal names, handing it over');
-- The re-run is a NEW session's, so it resumes by taking over a dead owner's claim. The same session's re-run
-- would be refused: its claim records no backend_start, which pg_stat_activity hides from a SET ROLE session
-- whose role does not have its session user's privileges, so #509's same-session arm cannot match it.
create temp table b300_pid as select pid from dblink('t300b', 'select pg_backend_pid()') as x(pid int);
select dblink_disconnect('t300b');
do $$ begin
  for i in 1 .. 100 loop
    perform pg_stat_clear_snapshot();
    exit when not exists (select 1 from pg_stat_activity where pid = (select pid from b300_pid));
    perform pg_sleep(0.05);
  end loop;
end $$;
select dblink_connect('t300b', 'dbname=' || current_database());
select dblink_exec('t300b', 'set role t300_converter');
select lives_ok(
  $$ select dblink_exec('t300b', 'call pgpm.transmute(''public.t300b'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(B) the re-run resumes and converts t300b, as t300_converter');
select is((select relkind::text from pg_class where oid = 'public.t300b'::regclass), 'p',
  'LIVENESS: (B) t300b is partitioned now');
select is((select array_agg(p.pubname::text order by p.pubname)
             from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
            where r.prrelid = 'public.t300b'::regclass),
  array['pub300_admin', 'pub300_mine'],
  '(B) the new parent is in both publications');
select lives_ok($$ insert into public.t300b values (310, 'past') $$, 'LIVENESS: (B) a row past the monolith is accepted');
select isnt((select tableoid from public.t300b where id = 310),
            (select monolith_oid from pgpm.config where parent_table = 'public.t300b'::regclass),
  'LIVENESS: (B) and it landed in a forward partition, not the monolith');
select is((select array_agg(id order by id) from public.t300b where id > 248), array[249, 250, 310]::bigint[],
  '(B) the rows are the ones written');

-- ====================================================================================================
-- (C) publish_via_partition_root turned off inside the cutover, while step 7a waits on a referenced table
-- ====================================================================================================
select dblink_connect('k300', 'dbname=' || current_database());
create temp table k300_pid as select pid from dblink('k300', 'select pg_backend_pid()') as x(pid int);
select dblink_send_query('k300', $q$ select public.t300_flip_in_cutover('public.t300c') $q$);
select ok(public.t300_await_hold((select pid from k300_pid))
          and exists (select 1 from pg_locks where pid = (select pid from k300_pid)
                       and relation = 'public.r300'::regclass and granted and mode = 'RowExclusiveLock'),
  'LIVENESS: (C) k300 holds a writer''s ROW EXCLUSIVE on r300, the table t300c references');
select throws_like(
  $$ select dblink_exec('t300a', 'call pgpm.transmute(''public.t300c'', ''id'', 100::bigint, p_obtain => 2, p_lock_timeout => ''60s'')') $$,
  'pg_partition_magician: cannot transmute t300c -- the publication(s) (pub300_vr) name it with a row filter or a column list%',
  '(C) the cutover refuses the publication whose publish_via_partition_root was turned off inside it, naming it, in pgpm''s words');
do $$ begin
  perform * from dblink_get_result('k300') as x(s text);
  perform * from dblink_get_result('k300') as x(s text);
end $$;
select is((select saw::text from public.w300_seen where tag = 'C') || '/' || (select pubviaroot::text from pg_publication where pubname = 'pub300_vr'),
  'true/false',
  'LIVENESS: (C) the flag was turned off and committed while the cutover held t300c and waited on r300 in step 7a');
select ok((select convalidated from pg_constraint where conrelid = 'public.t300c'::regclass and conname = 'pgpm_monolith_bound')
          and (select relkind::text from pg_class where oid = 'public.t300c'::regclass) = 'r'
          and exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t300c'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t300c'::regclass),
  '(C) the validated bound and the claim stand, t300c is still the plain table: the resumable phase-2 state');
select lives_ok($$ select dblink_exec('t300a', 'alter publication pub300_vr set (publish_via_partition_root = true)') $$,
  'LIVENESS: (C) the operator takes the remedy the refusal names, publish_via_partition_root = true');
select lives_ok(
  $$ select dblink_exec('t300a', 'call pgpm.transmute(''public.t300c'', ''id'', 100::bigint, p_obtain => 2)') $$,
  '(C) the re-run resumes and converts t300c');
select is((select string_agg(p.pubname || '=' || coalesce(pg_get_expr(r.prqual, r.prrelid), '-'), ' ' order by p.pubname)
             from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
            where r.prrelid = 'public.t300c'::regclass and (select relkind from pg_class where oid = 'public.t300c'::regclass) = 'p'),
  'pub300_vr=(id > 0)',
  '(C) the new parent is in pub300_vr, its row filter kept');

select dblink_disconnect('k300');
select dblink_disconnect('t300a');
select dblink_disconnect('t300b');
drop event trigger t300_inject;
drop owned by t300_converter;
drop role t300_converter;
select * from finish();
