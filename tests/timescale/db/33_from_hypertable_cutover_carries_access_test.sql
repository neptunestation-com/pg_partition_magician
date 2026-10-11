-- from_hypertable's swap left every grantee locked out (issue #787). The cutover drops the hypertable and
-- renames the copy, which from_hypertable_copy built with CREATE TABLE ... LIKE, into its place. LIKE carries
-- no privileges, no owner, no row-level security, no policies, no table comment and no triggers, and
-- nothing in the swap replayed them, so transmute, which carries all of those from a plain table onto its
-- parent (#277), found none to carry: every role the hypertable was granted to got permission denied the
-- moment the migration completed, its policies were gone, and its triggers stopped firing. The cutover now
-- reads them off the source under its ACCESS EXCLUSIVE, just before the DROP, and replays them onto the
-- table it renames into place, in the swap transaction (_from_hypertable_carried_ddl), so transmute carries
-- them on as it carries a plain table's.
--
-- ASYMMETRIC FIXTURE. Two grantees with different grants (t33_app: SELECT and INSERT on the table and UPDATE
-- of one column; t33_ro: SELECT with grant option), and two SELECT policies that admit DIFFERENT rows of the
-- three (t33_app sees 20 and 30, t33_ro sees 10 and 20), so a policy carried onto the wrong role, or lost, or
-- RLS left off, cannot read the same as the right one. The table is handed to a third role, t33_owner, so a
-- copy left owned by the migrating role is visible too. The tracked copy (p_track_changes => true) puts the
-- module's own capture trigger on the source beside the user's: the replay must take the one and not the
-- other (the capture trigger's function is gone by then). A second, keyless hypertable migrates
-- append-only with a single grant, so both catch-up paths go through the carry.
-- WITNESSES: each property is asserted on the hypertable before the migration, and the migration is
-- asserted to have completed (a partitioned table, registered, every row by value).
--
-- The tracked copy's delta table and capture function are asserted gone one at a time (issue #1091): the
-- two used to be tested together as is(delta::text || fn::text, null), and null || x is null, so a cutover
-- that dropped the delta and left hg33_pgpm_delta_fn() in public passed. Neither absence means anything
-- unless the copy minted them, which happens inside the one from_hypertable call, so an event trigger
-- records what it created there by identity.
select plan(30);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't33_app') then create role t33_app; end if;
  if not exists (select 1 from pg_roles where rolname = 't33_ro') then create role t33_ro; end if;
  if not exists (select 1 from pg_roles where rolname = 't33_owner') then create role t33_owner; end if;
end $$;
-- The migrating role (postgres) is not a superuser on the fleet image, so it is made a member of each role:
-- of t33_owner to migrate a table that role owns, of the other two to read as them below. Named, not
-- CURRENT_USER: the fleet image's GRANT hook crashes the backend on that role spec. The table is CREATED as
-- t33_owner rather than handed to it, because ALTER ... OWNER on a hypertable re-owns its chunks, which
-- needs CREATE on _timescaledb_internal, a schema this role cannot grant.
grant t33_owner, t33_app, t33_ro to postgres;
grant create on schema public to t33_owner;

set role t33_owner;
create table public.hg33 (id bigint not null, ts timestamptz not null, v int not null, note text,
                          primary key (id, ts));
select create_hypertable('public.hg33', 'ts', chunk_time_interval => interval '1 day');
insert into public.hg33 values
  (1, now() - interval '3 days', 10, 'a'), (2, now() - interval '2 days', 20, 'b'),
  (3, now() - interval '1 hour', 30, 'c');
reset role;
grant select, insert on public.hg33 to t33_app;
grant update (note) on public.hg33 to t33_app;
grant select on public.hg33 to t33_ro with grant option;
alter table public.hg33 enable row level security;
alter table public.hg33 force row level security;
create policy hg33_app_sees on public.hg33 for select to t33_app using (v >= 20);
create policy hg33_app_writes on public.hg33 for insert to t33_app with check (v < 100);
create policy hg33_ro_sees on public.hg33 for select to t33_ro using (v <= 20);
comment on table public.hg33 is 'grants, policies and a trigger ride the swap';
create function public.hg33_stamp() returns trigger language plpgsql as $f$
begin new.note := coalesce(new.note, '') || '+stamped'; return new; end $f$;
create trigger hg33_stamp before insert on public.hg33 for each row execute function public.hg33_stamp();

create table public.hk33 (ts timestamptz not null, v int);
select create_hypertable('public.hk33', 'ts', chunk_time_interval => interval '1 day');
insert into public.hk33 values (now() - interval '2 days', 1), (now() - interval '1 hour', 2);
grant select on public.hk33 to t33_ro;

-- What the migration has to keep, in one rendering used before and after: owner, the table and column
-- grants by grantee, RLS and FORCE, every policy, the comment and the user triggers (not TimescaleDB's).
-- The grants are compared by (grantee, privilege, grant option), not grantor: the replay runs as postgres,
-- a member of t33_ro too, which holds SELECT with grant option, so PostgreSQL may record either role as the
-- grantor of the owner's own SELECT, and a second aclitem for the same privilege is no difference in access.
create function pg_temp.access_of(p regclass) returns text language sql stable as $$
  select concat_ws(' | ',
    'owner ' || (select pg_get_userbyid(relowner) from pg_class where oid = p),
    'acl ' || (select string_agg(x, ',' order by x) from (
                 select distinct case when a.grantee = 0 then 'public' else pg_get_userbyid(a.grantee) end
                        || ':' || a.privilege_type || ':' || a.is_grantable as x
                   from pg_class c, aclexplode(c.relacl) a where c.oid = p) g),
    'cols ' || (select string_agg(x, ',' order by x) from (
                  select att.attname || ':' || pg_get_userbyid(a.grantee) || ':' || a.privilege_type as x
                    from pg_attribute att, aclexplode(att.attacl) a where att.attrelid = p and att.attnum > 0) g),
    'rls ' || (select relrowsecurity || '/' || relforcerowsecurity from pg_class where oid = p),
    'policies ' || (select string_agg(polname || ':' || polcmd::text || ':' || polpermissive || ':'
                                      || (select string_agg(rolname, '+' order by rolname) from pg_roles where oid = any(polroles))
                                      || ':' || coalesce(pg_get_expr(polqual, polrelid), '-')
                                      || ':' || coalesce(pg_get_expr(polwithcheck, polrelid), '-'), ',' order by polname)
                      from pg_policy where polrelid = p),
    'comment ' || coalesce(obj_description(p, 'pg_class'), '-'),
    'triggers ' || (select string_agg(tgname || ':' || tgenabled::text, ',' order by tgname) from pg_trigger
                     where tgrelid = p and not tgisinternal and tgname <> 'ts_insert_blocker'));
$$;
create temp table before33 as
  select 'hg33'::text as t, pg_temp.access_of('public.hg33') as access
  union all select 'hk33', pg_temp.access_of('public.hk33');

-- ================= WITNESSES: on the hypertable, before the migration =================
select is((select access from before33 where t = 'hg33'),
  'owner t33_owner | acl t33_app:INSERT:false,t33_app:SELECT:false,t33_owner:DELETE:false,t33_owner:INSERT:false,t33_owner:REFERENCES:false,t33_owner:SELECT:false,t33_owner:TRIGGER:false,t33_owner:TRUNCATE:false,t33_owner:UPDATE:false,t33_ro:SELECT:true | cols note:t33_app:UPDATE | rls true/true | policies hg33_app_sees:r:true:t33_app:(v >= 20):-,hg33_app_writes:a:true:t33_app:-:(v < 100),hg33_ro_sees:r:true:t33_ro:(v <= 20):- | comment grants, policies and a trigger ride the swap | triggers hg33_stamp:O',
  'LIVENESS: the hypertable has its owner, grants, column grant, RLS, three policies, comment and trigger');
select is(has_table_privilege('t33_app', 'public.hg33', 'select, insert')::text
          || '/' || has_table_privilege('t33_app', 'public.hg33', 'delete')::text
          || '/' || has_column_privilege('t33_app', 'public.hg33', 'note', 'update')::text
          || '/' || has_column_privilege('t33_app', 'public.hg33', 'v', 'update')::text,
  'true/false/true/false', 'LIVENESS: t33_app may select and insert, not delete, and update note but not v');
\set before_app_sees '(refused)'
\set before_ro_sees '(refused)'
\set before_owner_sees '(refused)'
set role t33_app;
select string_agg(v::text, ',' order by v) as app_sees from public.hg33 \gset before_
reset role;
set role t33_ro;
select string_agg(v::text, ',' order by v) as ro_sees from public.hg33 \gset before_
reset role;
set role t33_owner;
select count(*) as owner_sees from public.hg33 \gset before_
reset role;
select is(:'before_owner_sees'::text || ' of ' || (select count(*) from public.hg33), '0 of 3',
  'LIVENESS: FORCE holds the owner to the policies, and none names it, so t33_owner sees none of the 3 rows');
select is(:'before_app_sees'::text || ' / ' || :'before_ro_sees', '20,30 / 10,20',
  'LIVENESS: the policies admit different rows to the two roles (t33_app 20,30; t33_ro 10,20)');
select is((select access from before33 where t = 'hk33'),
  'owner postgres | acl postgres:DELETE:false,postgres:INSERT:false,postgres:REFERENCES:false,postgres:SELECT:false,postgres:TRIGGER:false,postgres:TRUNCATE:false,postgres:UPDATE:false,t33_ro:SELECT:false | rls false/false | comment -',
  'LIVENESS: the keyless hypertable has its one grant');
select is((select string_agg(tgname, ',' order by tgname) from pg_trigger where tgrelid = 'public.hg33'::regclass),
  'hg33_stamp,ts_insert_blocker', 'LIVENESS: the user trigger sits beside TimescaleDB''s insert blocker');

-- ================= the migrations =================
-- What the tracked copy mints for its change capture, by identity, as it creates it.
create table public.t33_minted (identity text);
create function public.t33_record_minted() returns event_trigger language plpgsql as $f$
begin
  insert into public.t33_minted
  select c.object_identity from pg_event_trigger_ddl_commands() c
   where c.object_identity like '%hg33\_pgpm\_delta%';
end $f$;
create event trigger t33_minted_et on ddl_command_end when tag in ('CREATE TABLE AS', 'CREATE FUNCTION')
  execute function public.t33_record_minted();
call pgpm.from_hypertable('public.hg33', 'ts', interval '1 day', p_paused => false, p_track_changes => true);
drop event trigger t33_minted_et;
call pgpm.from_hypertable('public.hk33', 'ts', interval '1 day', p_paused => false);

-- LIVENESS: both migrations completed, every row by value.
select is((select relkind::text from pg_class where oid = 'public.hg33'::regclass)
          || '/' || (select count(*) from pgpm.config where parent_table = 'public.hg33'::regclass)
          || '/' || (select string_agg(id || ':' || v || ':' || note, ',' order by id) from public.hg33),
  'p/1/1:10:a,2:20:b,3:30:c', 'LIVENESS: hg33 is a pgpm-managed partitioned table holding its three rows');
select is((select relkind::text from pg_class where oid = 'public.hk33'::regclass)
          || '/' || (select count(*) from pgpm.config where parent_table = 'public.hk33'::regclass)
          || '/' || (select string_agg(v::text, ',' order by v) from public.hk33),
  'p/1/1,2', 'LIVENESS: hk33 is a pgpm-managed partitioned table holding its two rows');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name in ('hg33', 'hk33')),
  0, 'LIVENESS: neither is a hypertable any more');
select is((select string_agg(distinct identity, ',' order by identity) from public.t33_minted),
  'public.hg33_pgpm_delta,public.hg33_pgpm_delta_fn()',
  'LIVENESS: the tracked copy minted its delta table and its capture function');
select is(to_regclass('public.hg33_pgpm_delta'), null,
  'the tracked copy''s delta table was dropped with the source');
select is(to_regprocedure('public.hg33_pgpm_delta_fn()'), null,
  'the tracked copy''s capture function was dropped with the source');

-- ================= THE CONTRACT: the migrated tables kept their access =================
select is(pg_temp.access_of('public.hg33'), (select access from before33 where t = 'hg33'),
  'hg33 keeps its owner, table and column grants, RLS and FORCE, policies, comment and trigger, by identity');
select is(pg_temp.access_of('public.hk33'), (select access from before33 where t = 'hk33'),
  'hk33 keeps its grant');
select ok(has_table_privilege('t33_app', 'public.hg33', 'select, insert'),
  't33_app may still select and insert on hg33');
select ok(not has_table_privilege('t33_app', 'public.hg33', 'delete'),
  'and still may not delete (the grants are the source''s, not more)');
select ok(has_column_privilege('t33_app', 'public.hg33', 'note', 'update')
          and not has_column_privilege('t33_app', 'public.hg33', 'v', 'update'),
  't33_app may still update note, and still not v');
select ok(has_table_privilege('t33_ro', 'public.hg33', 'select with grant option')
          and not has_table_privilege('t33_ro', 'public.hg33', 'insert'),
  't33_ro still selects with grant option, and still cannot insert');
select ok(has_table_privilege('t33_ro', 'public.hk33', 'select'), 't33_ro may still select hk33');
select is((select pg_get_userbyid(relowner) from pg_class where oid = 'public.hg33'::regclass), 't33_owner',
  'hg33 is still owned by t33_owner, not by the role that ran the migration');

-- Each read below runs as its role. Preset, so a read that is refused leaves a value that fails its
-- assertion rather than an unset variable that kills the statement (and the plan) with it.
\set after_app_sees '(refused)'
\set after_ro_sees '(refused)'
\set after_ro_sees_hk '(refused)'
\set after_owner_sees '(refused)'
set role t33_app;
select string_agg(v::text, ',' order by v) as app_sees from public.hg33 \gset after_
insert into public.hg33 (id, ts, v, note) values (4, now() - interval '30 minutes', 40, 'd');
reset role;
set role t33_ro;
select string_agg(v::text, ',' order by v) as ro_sees from public.hg33 \gset after_
select count(*) as ro_sees_hk from public.hk33 \gset after_
reset role;
select is(:'after_app_sees'::text, '20,30', 't33_app''s policy still admits exactly 20 and 30');
select is(:'after_ro_sees'::text, '10,20', 't33_ro''s policy still admits exactly 10 and 20');
select is(:'after_ro_sees_hk'::text, '2', 't33_ro still reads both rows of hk33');
select is((select note from public.hg33 where id = 4), 'd+stamped',
  't33_app''s insert went through, and the carried trigger stamped it');
select is((select string_agg(tgname, ',' order by tgname) from pg_trigger
            where tgrelid = 'public.hg33'::regclass and tgparentid = 0),
  'hg33_stamp', 'the parent carries the user trigger once, and neither the capture trigger nor the insert blocker');
-- every partition (the monolith the original table became among them) holds exactly one user trigger, the
-- clone of the parent's, so it fires once per row
select is((select string_agg(n::text, ',') from (
             select count(t.oid) filter (where t.tgparentid <> 0) || '/' || count(t.oid) as n
               from pg_inherits i left join pg_trigger t on t.tgrelid = i.inhrelid and not t.tgisinternal
              where i.inhparent = 'public.hg33'::regclass group by i.inhrelid) g where n <> '1/1'),
  null, 'every partition''s only user trigger is the clone of the parent''s');
select ok((select count(*) from pg_inherits where inhparent = 'public.hg33'::regclass) >= 2,
  'LIVENESS: and there are partitions to hold it (the monolith and the forward grid)');
set role t33_owner;
select count(*) as owner_sees from public.hg33 \gset after_
reset role;
select is(:'after_owner_sees'::text || ' of ' || (select count(*) from public.hg33), '0 of 4',
  'FORCE still holds the owner to the policies: t33_owner, which none names, sees none of the 4 rows');
select is((select obj_description('public.hg33'::regclass, 'pg_class')), 'grants, policies and a trigger ride the swap',
  'the table comment came across');
select is((select string_agg(id || ':' || v, ',' order by id) from public.hg33), '1:10,2:20,3:30,4:40',
  'invariant: hg33 holds its three rows and t33_app''s one');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
