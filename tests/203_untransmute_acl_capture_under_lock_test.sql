-- untransmute captures the parent's privileges under its ACCESS EXCLUSIVE, not before it (#667; review pass
-- 5 seed S8).
--
-- untransmute hands the PARENT's grants and row security back to the restored table, because GRANT, REVOKE
-- and the RLS DDL change the parent and none of them recurses to the monolith. The capture has to be read
-- under the explicit lock of #443's second gate: before it, the reversal holds only its first gate's ACCESS
-- SHARE, which does not exclude a GRANT, so a privilege granted while the lock was queued would be on the
-- parent, missing from the capture, and lost with the parent's DROP. tests/158 covers the trigger capture
-- (#666) in exactly this window and tests/176 covers the privileges with no window at all; nothing covered
-- this one, so moving the capture above the gate passed the suite.
--
-- The concurrent session is a dblink connection, as in tests/158: it takes ROW SHARE, the reversal queues
-- for ACCESS EXCLUSIVE behind it, and only once this session has seen that wait does it GRANT and commit.
-- This session does not touch the table while the reversal waits (a new ACCESS SHARE would queue behind
-- the pending ACCESS EXCLUSIVE).
--
-- Asymmetric: acl203_early is granted SELECT before the reversal starts and acl203_late is granted INSERT
-- during the wait. Both must be on the restored table; under the defect only acl203_early's is, so the
-- early grant is the liveness witness that the capture runs at all and the late one is the verdict.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(10);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'acl203_early') then create role acl203_early; end if;
  if not exists (select 1 from pg_roles where rolname = 'acl203_late')  then create role acl203_late;  end if;
end $$;

create table public.acl203 (id bigint primary key, body text);
insert into public.acl203 select g, 'b' || g from generate_series(1, 5) g;
call pgpm.transmute('public.acl203', 'id', 100::bigint, p_obtain => 2);   -- monolith [0, 100)
grant select on public.acl203 to acl203_early;

select ok(has_table_privilege('acl203_early', 'public.acl203', 'SELECT')
          and not has_table_privilege('acl203_late', 'public.acl203', 'INSERT'),
  'LIVENESS: before the reversal acl203_early may SELECT from the converted table and acl203_late may not INSERT');

select dblink_connect('w203', 'dbname=' || current_database());
select dblink_exec('w203', $$set application_name = 'acl203_writer'$$);
select dblink_exec('w203', 'begin');
select dblink_exec('w203', 'lock table public.acl203 in row share mode');

select dblink_connect('u203', 'dbname=' || current_database());
select dblink_exec('u203', $$set application_name = 'acl203_untransmute'$$);
select dblink_exec('u203', $$set lock_timeout = '60s'$$);
select dblink_send_query('u203', $$select pgpm.untransmute('public.acl203')::text$$);

-- Poll for the WAIT, bounded at 30 s so a broken fixture fails rather than hangs. pg_stat_activity is read
-- once per transaction and then frozen (a DO block is one transaction), so the loop clears it each turn.
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                       where a.application_name = 'acl203_untransmute' and l.locktype = 'relation'
                         and l.relation = 'public.acl203'::regclass
                         and l.mode = 'AccessExclusiveLock' and not l.granted);
    perform pg_sleep(0.05);
  end loop;
end $$;
select is(
  (select count(*)::int from pg_locks l join pg_stat_activity a on a.pid = l.pid
    where a.application_name = 'acl203_untransmute' and l.locktype = 'relation'
      and l.relation = 'public.acl203'::regclass and l.mode = 'AccessExclusiveLock' and not l.granted),
  1, 'LIVENESS: untransmute passed its first gate and is queued for ACCESS EXCLUSIVE behind the writer');

-- A GRANT takes no lock the queued request blocks, so it goes ahead of it.
select dblink_exec('w203', 'grant insert on public.acl203 to acl203_late');
select is(
  (select count(*)::int from pg_locks l join pg_stat_activity a on a.pid = l.pid
    where a.application_name = 'acl203_untransmute' and l.locktype = 'relation'
      and l.relation = 'public.acl203'::regclass and l.mode = 'AccessExclusiveLock' and not l.granted),
  1, 'LIVENESS: and still queued after the writer''s GRANT, so the grant came after any pre-lock capture point');
select dblink_exec('w203', 'commit');
select is((select r from dblink_get_result('u203') as t(r text)), 'acl203',
  'untransmute completed once the writer committed');
select dblink_disconnect('u203');
select dblink_disconnect('w203');

select is((select relkind::text from pg_class where oid = 'public.acl203'::regclass), 'r',
  'LIVENESS: acl203 is a plain table again');
select is((select count(*)::int from pgpm.config where parent_table = 'public.acl203'::regclass), 0,
  'LIVENESS: and pgpm no longer manages it');

select ok(has_table_privilege('acl203_early', 'public.acl203', 'SELECT'),
  'LIVENESS: the restored table carries the grant made before the reversal (the capture ran)');
select ok(has_table_privilege('acl203_late', 'public.acl203', 'INSERT'),
  'the restored table carries the grant committed while the reversal was queued for its lock');
select is(
  (select array_agg(pg_get_userbyid(a.grantee) || ':' || a.privilege_type
                    order by pg_get_userbyid(a.grantee), a.privilege_type)
     from pg_class c, aclexplode(c.relacl) a
    where c.oid = 'public.acl203'::regclass and a.grantee in ('acl203_early'::regrole, 'acl203_late'::regrole)),
  array['acl203_early:SELECT', 'acl203_late:INSERT'],
  'exactly those two grants for the two roles: early SELECT, late INSERT, nothing crossed over');
select ok(not has_table_privilege('acl203_late', 'public.acl203', 'SELECT')
          and not has_table_privilege('acl203_early', 'public.acl203', 'INSERT'),
  'and neither role gained the other''s privilege');

select * from finish();
