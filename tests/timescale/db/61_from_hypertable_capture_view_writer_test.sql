-- A role that writes a hypertable only through a VIEW is captured during a tracking copy's online window
-- (issue #1073, the hypertable half).
--
-- A write through an ordinary view is permission-checked as the view's owner, but the hypertable's row
-- triggers fire as the session's role. The tracking capture wrote <rel>_pgpm_delta as that role, and
-- _regrain_capture_grant gives INSERT on the delta only to the hypertable's grantees and owner, so a role
-- whose only grant was on a view got 42501 'permission denied for table <rel>_pgpm_delta' on every write for
-- the whole online window. The capture function now writes the delta as its owner (pgpm._capture_definer:
-- SECURITY DEFINER, search_path pinned, EXECUTE the owner's alone), armed where from_hypertable_copy mints it
-- and re-armed by every drain, drain step and cutover, so a capture minted by an earlier release is armed by
-- the first step after the upgrade.
--
--   (A) the view writer deletes id 5, updates id 6 and inserts id 1001 through the view: captured by key;
--       a drain step applies them to the copy (5 gone, 6 updated, 1001 there, 4 and 7 untouched);
--   (B) no role but the owner holds EXECUTE on the capture function;
--   (C) the capture disarmed by hand to the pre-fix shape refuses the view writer (LIVENESS), and the next
--       drain step arms it again: the view writer's update of id 7 is then captured;
--   (D) a second hypertable, h61.g, whose OWNER loses USAGE on its schema during the online window (REVOKE
--       ALL ... FROM PUBLIC, USAGE granted to the application role w61_app alone). A tracking copy cannot be
--       started in that layout at all, before or after #1073 (TimescaleDB creates the capture trigger on each
--       chunk as the owner, which then cannot name the function), so the copy is made while the owner holds
--       USAGE and it is revoked afterwards. The definer capture can no longer name the delta, and refuses the
--       application role's write (LIVENESS, the window up to the next step; P1-02 on PR #1132); the next drain
--       step puts the writer-run capture back, and w61_app, which holds DML on the hypertable, USAGE on the
--       schema and INSERT on the delta, deletes ids 5 and 8 and inserts id 1001 (two out, one in): captured,
--       and drained into the copy.
-- ASYMMETRIC: one row out, one in, one changed, then a second change, so a lost write and a resurrected one
-- cannot cancel. Roles are named, created only when absent, granted to postgres by name (this session writes
-- as one below), and dropped at the end. The core half's guard is bench/regrain_capture_view_writer.sh.
select plan(22);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'w61_vw') then create role w61_vw; end if;
  if not exists (select 1 from pg_roles where rolname = 'w61_other') then create role w61_other; end if;
end $$;
grant w61_vw to postgres;   -- by name: this session writes as w61_vw below
grant usage on schema public to w61_vw, w61_other;

create table public.g61 (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.g61', 'ts', chunk_time_interval => interval '1 day');
insert into public.g61 select timestamptz '2024-01-01 00:00+00' + n * interval '2 hours', n, n from generate_series(1, 30) n;
create view public.g61_v as select * from public.g61;
grant select, insert, update, delete on public.g61_v to w61_vw;
call pgpm.from_hypertable_copy('public.g61', 'ts', p_track_changes => true);
select pgpm._scratch_rel('public.g61', 'hypertable_delta')::text as delta \gset
select p.oid::regprocedure::text as fn from pg_proc p
 where p.oid = (select s.obj from pgpm.scratch s where s.parent_oid = 'public.g61'::regclass::oid and s.kind = 'hypertable_delta_fn') \gset

create function w61_delta_ids() returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  execute format('select array_agg(id order by pgpm_seq) from %s', pgpm._scratch_rel('public.g61', 'hypertable_delta')) into v;
  return v;
end $f$;
create function w61_dest_rows() returns text[] language plpgsql as $f$
declare v text[];
begin
  execute format('select array_agg(id || '':'' || v order by id) from %s where id in (4, 5, 6, 7, 1001)',
                 pgpm._scratch_rel('public.g61', 'hypertable_dest')) into v;
  return v;
end $f$;

select ok(:'delta' is not null and :'fn' is not null
          and not has_table_privilege('w61_vw', 'public.g61', 'INSERT')
          and not has_table_privilege('w61_vw', 'public.g61', 'UPDATE')
          and not has_table_privilege('w61_vw', 'public.g61', 'DELETE')
          and not has_table_privilege('w61_vw', :'delta', 'INSERT')
          and has_table_privilege('w61_vw', 'public.g61_v', 'DELETE'),
  'LIVENESS: the tracking copy recorded its delta and capture, and the view writer holds DML on the view and nothing on the hypertable or the delta');

-- (A)
set role w61_vw;
select lives_ok($$ delete from public.g61_v where id = 5 $$,
  'during the online window the view writer deletes a row through the view');
select lives_ok($$ update public.g61_v set v = 66 where id = 6 $$, 'updates one');
select lives_ok($$ insert into public.g61_v values ('2024-01-02 01:00+00', 1001, 11) $$, 'and inserts one');
reset role;
select is(w61_delta_ids(), array[5, 6, 6, 1001]::bigint[],
  'all three writes were captured, by key (the UPDATE as its old and new key)');
select is(pgpm.from_hypertable_drain_delta_step('public.g61', 'ts'), 3::bigint,
  'LIVENESS: a drain step reconciled the three keys');
select is(w61_dest_rows(), array['4:4', '6:66', '7:7', '1001:11'],
  'and the copy holds the view writer''s changes: 5 gone, 6 updated, 1001 there, 4 and 7 untouched');

-- (B)
select ok(not has_function_privilege('w61_other', :'fn', 'EXECUTE')
          and not has_function_privilege('w61_vw', :'fn', 'EXECUTE'),
  'no role but its owner holds EXECUTE on the capture function, PUBLIC included');

-- (C) the capture as a release before this one minted it
alter function :fn security invoker;
alter function :fn reset search_path;
grant execute on function :fn to public;
set role w61_vw;
select throws_ok($$ update public.g61_v set v = 77 where id = 7 $$, '42501', 'permission denied for table g61_pgpm_delta',
  'LIVENESS: with the capture disarmed to the pre-fix shape the view writer is refused, as #1073 found');
reset role;
select is(pgpm.from_hypertable_drain_delta_step('public.g61', 'ts'), 0::bigint,
  'LIVENESS: the next drain step ran, with nothing to drain');
select ok((select prosecdef and proconfig = array['search_path=pg_catalog, pg_temp'] from pg_proc where oid = :'fn'::regprocedure)
          and not has_function_privilege('w61_other', :'fn', 'EXECUTE'),
  'the drain step armed the capture again: it writes as its owner, its search_path pinned, its EXECUTE the owner''s alone');
set role w61_vw;
select lives_ok($$ update public.g61_v set v = 77 where id = 7 $$,
  'the view writer updates a row through the view again');
reset role;
select is(w61_delta_ids(), array[7, 7]::bigint[],
  'and the view writer''s update of id 7 through the view is captured again');

-- (D)
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'w61_hown') then create role w61_hown; end if;
  if not exists (select 1 from pg_roles where rolname = 'w61_app') then create role w61_app; end if;
end $$;
grant w61_hown, w61_app to postgres;   -- by name: this session owns as one and writes as the other
create schema h61;
revoke all on schema h61 from public;
grant usage on schema h61 to w61_app;
grant usage, create on schema h61 to w61_hown;   -- until the copy is up
create table h61.g (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
alter table h61.g owner to w61_hown;   -- before any chunk exists, so no chunk needs re-owning
select create_hypertable('h61.g', 'ts', chunk_time_interval => interval '1 day');
insert into h61.g select timestamptz '2024-01-01 00:00+00' + n * interval '2 hours', n, n from generate_series(1, 30) n;
grant select, insert, update, delete on h61.g to w61_app;
call pgpm.from_hypertable_copy('h61.g', 'ts', p_track_changes => true);
select pgpm._scratch_rel('h61.g', 'hypertable_delta')::text as hdelta \gset
select p.oid::regprocedure::text as hfn from pg_proc p
 where p.oid = (select s.obj from pgpm.scratch s where s.parent_oid = 'h61.g'::regclass::oid and s.kind = 'hypertable_delta_fn') \gset
revoke usage on schema h61 from w61_hown;   -- the hardening, applied during the online window
create function w61_h_delta_ids() returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  execute format('select array_agg(id order by pgpm_seq) from %s', pgpm._scratch_rel('h61.g', 'hypertable_delta')) into v;
  return v;
end $f$;
create function w61_h_dest_rows() returns text[] language plpgsql as $f$
declare v text[];
begin
  execute format('select array_agg(id || '':'' || v order by id) from %s where id in (4, 5, 7, 8, 9, 1001)',
                 pgpm._scratch_rel('h61.g', 'hypertable_dest')) into v;
  return v;
end $f$;
select ok(:'hdelta' is not null
          and not has_schema_privilege('w61_hown', 'h61', 'USAGE')
          and has_schema_privilege('w61_app', 'h61', 'USAGE')
          and (select pg_get_userbyid(c.relowner) = 'w61_hown' from pg_class c where c.oid = :'hdelta'::regclass)
          and (select pg_get_userbyid(p.proowner) = 'w61_hown' from pg_proc p where p.oid = :'hfn'::regprocedure)
          and has_table_privilege('w61_app', :'hdelta', 'INSERT'),
  'LIVENESS: the tracking copy of h61.g is up; its owner owns the capture and the delta and no longer holds USAGE on their schema, and the application role holds USAGE and INSERT on the delta');
set role w61_app;
select throws_ok($$ delete from h61.g where id = 4 $$, '42501', 'permission denied for schema h61',
  'LIVENESS: until the next step the definer capture, armed while the owner could reach the delta, refuses the application role''s write');
reset role;
select is(pgpm.from_hypertable_drain_delta_step('h61.g', 'ts'), 0::bigint, 'LIVENESS: the next drain step ran, with nothing to drain');
select ok((select not prosecdef and proconfig is null from pg_proc where oid = :'hfn'::regprocedure),
  'that step put the writer-run capture back, its owner being unable to reach the delta');
set role w61_app;
select lives_ok($$ delete from h61.g where id in (5, 8) $$,
  'with the owner unable to name its own schema, the application role deletes two rows of the hypertable');
select lives_ok($$ insert into h61.g values ('2024-01-02 01:00+00', 1001, 11) $$, 'and inserts one');
reset role;
select is(w61_h_delta_ids(), array[5, 8, 1001]::bigint[], 'all three writes were captured, by key');
select is(pgpm.from_hypertable_drain_delta_step('h61.g', 'ts'), 3::bigint,
  'LIVENESS: a drain step reconciled the three keys');
select is(w61_h_dest_rows(), array['4:4', '7:7', '9:9', '1001:11'],
  'and the copy holds the application role''s changes: 5 and 8 gone, 1001 there, 4, 7 and 9 untouched');

select * from finish();

-- roles are cluster-wide: leave none behind. Everything they hold a grant on goes first.
select pgpm._scratch_rel('public.g61', 'hypertable_dest')::text as dest \gset
drop view public.g61_v;
drop table public.g61;
drop table :delta, :dest;
revoke usage on schema public from w61_vw, w61_other;
drop role w61_vw, w61_other;
drop schema h61 cascade;
drop role w61_hown, w61_app;
