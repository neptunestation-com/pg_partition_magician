-- from_hypertable_cutover waits for every snapshot that cannot see its copy before it swaps (issue #1241, the
-- hypertable copy of regrain's swap).
--
-- THE BUG. The cutover drops the hypertable and renames the copy into its place. The copy's rows were written by
-- from_hypertable_copy and the drains, after the snapshot of a REPEATABLE READ transaction opened before the copy,
-- and no snapshot sees rows written after it. A reader holding no lock on the hypertable (so the cutover's ACCESS
-- EXCLUSIVE had nothing to wait for) that first read the table after the cutover read the copy and found it EMPTY:
-- 0 rows of 240, with no error.
--
-- THE CONTRACT. With that reader open, the cutover waits for it under p_lock_timeout and then gives up whole, as it
-- does on a lock it cannot get: the hypertable is still the hypertable and the reader reads every row of it. Once
-- the reader commits, the same cutover goes through. The negative ("the cutover did not swap") is paired with its
-- premises: the reader's snapshot predates the copy (it cannot see even the copy's catalog row) and the reader
-- holds no lock on the hypertable, its chunks or the copy. The first cutover runs in a second session, so that one
-- which does not wait commits its swap there and the reader's empty read shows.
--
-- PART B  the same, run by the hypertable's non-superuser owner without pg_read_all_stats against a reader in
--         another role, whose state, xact_start and backend_type read NULL to the owner: it is waited for alike.
-- PART C  the reference is the copy's LAST write, a drain's pure DELETE included: a key deleted from the source,
--         then a reader opened (the key is gone to it), then the drain deletes the key from the copy. The reader's
--         snapshot predates that delete, so after a swap the copy would show it the deleted key again: it is
--         waited for, and never reads the deleted row back.
-- PART D  no settling: a reader in the middle of a statement when p_lock_timeout runs out makes the cutover refuse
--         exactly as an idle one does (it would read the table empty after the swap).
-- PART E  the wait reads the sessions afresh on every poll: a REPEATABLE READ transaction that imports a snapshot
--         older than the copy (exported by another) after the cutover's wait began is waited for once the exporter
--         has gone, and the cutover refuses rather than swap under it.
-- PART F  the same for a copy with no recorded last write (made before pgpm.scratch.written_xid existed, so the
--         cutover waits against its own xid), with a writer idle in its transaction since before the exporter's
--         snapshot: the importer's xmin EQUALS that writer's xid, the oldest running, and it is waited for alike.
-- ASYMMETRIC: A has 240 rows, B 120, C 60 keyed devices with device 17 deleted, D 90, E 75, F 66; the rows are judged by identity
-- against the source as it stood (a bag), never by count.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t67.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(36);

-- runs the cutover in dblink connection p_conn, waits for it from short statements of this session, and returns
-- its error message ('' when it went through): a refusal raised here would be a raw error
create function pg_temp.t67_cutover(p_conn text, p_sql text) returns text language plpgsql as $$
declare v_status text;
begin
  perform dblink_send_query(p_conn, p_sql);
  for i in 1..600 loop
    exit when dblink_is_busy(p_conn) = 0;
    perform pg_sleep(0.05);
  end loop;
  select r into v_status from dblink_get_result(p_conn, false) as t(r text);
  perform * from dblink_get_result(p_conn, false) as t(r text);   -- drains the connection
  if v_status = 'CALL' then return ''; end if;
  return dblink_error_message(p_conn);
end $$;

select mk_plain_hypertable('h67', 240, '1 day', '10 days') \g /dev/null
create temp table h67_before as select * from h67;

-- the reader: REPEATABLE READ, its snapshot taken now (on a catalog), before the copy, no lock on the table
select dblink_connect('r67', current_setting('t67.connstr')) \g /dev/null
select dblink_exec('r67', 'begin isolation level repeatable read') \g /dev/null
create temp table h67_reader as select pid from dblink('r67', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);

call pgpm.from_hypertable_copy('h67', 'ts');
create temp table h67_copy as select pgpm._from_hypertable_scratch('h67'::regclass, 'hypertable_dest') as name;

select is((select count(*) from h67_before), 240::bigint, 'LIVENESS: the hypertable holds 240 rows');
select ok((select n from dblink('r67', format('select count(*) from pg_class where relname = %L', (select name from h67_copy))) as t(n bigint)) = 0
          and exists (select 1 from pg_class where relname = (select name from h67_copy)),
  'LIVENESS: the reader''s snapshot predates the copy (it cannot see even the copy''s catalog row)');
select is((select count(*) from pg_locks l, h67_reader r
            where l.pid = r.pid and l.locktype = 'relation'
              and l.relation in (select 'h67'::regclass::oid
                                 union all select i.inhrelid from pg_inherits i where i.inhparent = 'h67'::regclass
                                 union all select c.oid from pg_class c where c.relname = (select name from h67_copy))),
  0::bigint, 'LIVENESS: the reader holds no lock on the hypertable, its chunks or the copy');

-- the cutover, from a second session so that a cutover which does not wait commits its swap (a refusal raised in
-- this session would be a raw error); p_predrain => false keeps its swap in the transaction its call opened, which
-- began before this session's poll, so the poll is not one of the snapshots it waits for
select dblink_connect('d67', current_setting('t67.connstr')) \g /dev/null
select dblink_send_query('d67', $q$call pgpm.from_hypertable_cutover('h67', 'ts', interval '1 month', p_paused => false, p_predrain => false, p_lock_timeout => '1s')$q$) \g /dev/null
do $$
begin
  for i in 1..600 loop
    exit when dblink_is_busy('d67') = 0;
    perform pg_sleep(0.05);
  end loop;
end $$;
create temp table h67_outcome as
  select dblink_error_message('d67') as msg, (select count(*) from dblink_get_result('d67', false) as t(r text)) as n;
select alike((select msg from h67_outcome),
  'ERROR:  pg_partition_magician: hypertable cutover deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select pid from h67_reader) || ',%',
  'the cutover waited for the reader under p_lock_timeout and gave up, naming it by pid');
select is((select relkind::text from pg_class where oid = 'h67'::regclass), 'r', 'the hypertable was not swapped');
-- by (ts, device_id): a float read back through dblink's text rendering need not compare equal to the stored one
select bag_eq($$ select * from dblink('r67', 'select ts, device_id from h67') as t(ts timestamptz, device_id bigint) $$,
  'select ts, device_id from h67_before',
  'the reader reads every row of the hypertable, by identity');
select dblink_exec('r67', 'commit') \g /dev/null

call pgpm.from_hypertable_cutover('h67', 'ts', interval '1 month', p_paused => false, p_lock_timeout => '5s');
select is((select relkind::text from pg_class where oid = 'h67'::regclass), 'p',
  'LIVENESS: once the reader committed, the same cutover migrated the table');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'h67'), 0,
  'and the hypertable was torn down');
select bag_eq('select * from h67', 'select * from h67_before',
  'and the migrated table holds every row of the source, by identity');
select is((select n from dblink('r67', 'select count(*) from h67') as t(n bigint)), 240::bigint,
  'a new transaction of the reader''s session counts every row');

select dblink_disconnect('r67') \g /dev/null
select dblink_disconnect('d67') \g /dev/null

-- ============================================ PART B ============================================
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't67_owner') then create role t67_owner login password 't67pw'; end if;
  if not exists (select 1 from pg_roles where rolname = 't67_reporter') then create role t67_reporter login password 't67pw'; end if;
end $$;
grant usage, create on schema pgpm to t67_owner;
grant all on all tables in schema pgpm to t67_owner;
grant all on all sequences in schema pgpm to t67_owner;
grant execute on all functions in schema pgpm to t67_owner;
grant execute on all procedures in schema pgpm to t67_owner;
grant create, usage on schema public to t67_owner;
grant t67_owner to postgres;   -- by name, not CURRENT_USER: the fleet image's GRANT hook crashes on that spec (tests/33)
select set_config('t67.owner', replace(replace(current_setting('t67.connstr'), 'user=postgres', 'user=t67_owner'), 'password=postgres', 'password=t67pw'), false) \g /dev/null
select set_config('t67.reporter', replace(replace(current_setting('t67.connstr'), 'user=postgres', 'user=t67_reporter'), 'password=postgres', 'password=t67pw'), false) \g /dev/null
set role t67_owner;
select mk_plain_hypertable('h67b', 120, '1 day', '10 days') \g /dev/null
grant select on h67b to t67_reporter;
reset role;
create temp table h67b_before as select ts, device_id from h67b;
select dblink_connect('r67b', current_setting('t67.reporter')) \g /dev/null
select dblink_exec('r67b', 'begin isolation level repeatable read') \g /dev/null
create temp table h67b_reader as select pid from dblink('r67b', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
grant select on h67b_reader to t67_owner;
set role t67_owner;
call pgpm.from_hypertable_copy('h67b', 'ts');
select ok(not (select rolsuper from pg_roles where rolname = 't67_owner')
          and not pg_has_role('t67_owner', 'pg_read_all_stats', 'usage')
          and (select backend_xmin is not null and state is null and xact_start is null and backend_type is null
                 from pg_stat_activity where pid = (select pid from h67b_reader)),
  'LIVENESS: (B) the owner, no superuser and without pg_read_all_stats, sees the reader''s snapshot and nothing else of it');
reset role;
select dblink_connect('d67b', current_setting('t67.owner')) \g /dev/null
select alike(pg_temp.t67_cutover('d67b', $q$call pgpm.from_hypertable_cutover('h67b', 'ts', interval '1 month', p_paused => false, p_predrain => false, p_lock_timeout => '1s')$q$),
  'ERROR:  pg_partition_magician: hypertable cutover deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select pid from h67b_reader) || ',%',
  '(B) the owner''s cutover waited for the other role''s reader and refused, naming it by pid');
select is((select relkind::text from pg_class where oid = 'h67b'::regclass), 'r', '(B) the hypertable was not swapped');
select bag_eq($$ select * from dblink('r67b', 'select ts, device_id from h67b') as t(ts timestamptz, device_id bigint) $$,
  'select * from h67b_before', '(B) the reader reads every row of the hypertable, by identity');
select dblink_exec('r67b', 'commit') \g /dev/null
select is(pg_temp.t67_cutover('d67b', $q$call pgpm.from_hypertable_cutover('h67b', 'ts', interval '1 month', p_paused => false, p_lock_timeout => '5s')$q$),
  '', 'LIVENESS: (B) once the reader committed, the owner''s cutover went through');
select is((select relkind::text from pg_class where oid = 'h67b'::regclass), 'p', 'LIVENESS: (B) and migrated the table');
select dblink_disconnect('r67b') \g /dev/null
select dblink_disconnect('d67b') \g /dev/null

-- ============================================ PART C ============================================
select mk_keyed_hypertable('h67c', 60, '1 day', '4 days') \g /dev/null
call pgpm.from_hypertable_copy('h67c', 'ts', p_track_changes => true);
create temp table h67c_del (xid xid8);
begin;
delete from h67c where device_id = 17;                              -- captured in the delta, not yet drained
insert into h67c_del select pg_current_xact_id();
commit;
create temp table h67c_after as select ts, device_id from h67c;     -- 59 devices, 17 gone
-- the reader opens after the source delete, so device 17 is gone to it, and touches nothing of the table
select dblink_connect('r67c', current_setting('t67.connstr')) \g /dev/null
select dblink_exec('r67c', 'begin isolation level repeatable read') \g /dev/null
create temp table h67c_reader as select pid from dblink('r67c', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
call pgpm.from_hypertable_drain_delta('h67c', 'ts');               -- deletes device 17 from the copy, inserts nothing
select ok((select age(a.backend_xmin) < age((select xid from h67c_del)::xid) from pg_stat_activity a
            where a.pid = (select pid from h67c_reader)),
  'LIVENESS: (C) the reader''s snapshot is past the source delete (device 17 is gone to it)');
select ok((select age(a.backend_xmin) >= age(s.written_xid::xid)
             from pg_stat_activity a, pgpm.scratch s
            where a.pid = (select pid from h67c_reader) and s.parent_oid = 'h67c'::regclass::oid and s.kind = 'hypertable_dest'),
  'LIVENESS: (C) and predates the drain that deleted it from the copy, the copy''s last write');
select dblink_connect('d67c', current_setting('t67.connstr')) \g /dev/null
select alike(pg_temp.t67_cutover('d67c', $q$call pgpm.from_hypertable_cutover('h67c', 'ts', interval '1 month', p_paused => false, p_predrain => false, p_lock_timeout => '1s')$q$),
  'ERROR:  pg_partition_magician: hypertable cutover deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select pid from h67c_reader) || ',%',
  '(C) the cutover waited for the reader whose snapshot predates the drain''s delete, and refused');
select bag_eq($$ select * from dblink('r67c', 'select ts, device_id from h67c') as t(ts timestamptz, device_id bigint) $$,
  'select * from h67c_after', '(C) the reader reads the 59 devices it should: device 17 does not come back');
select dblink_exec('r67c', 'commit') \g /dev/null
select is(pg_temp.t67_cutover('d67c', $q$call pgpm.from_hypertable_cutover('h67c', 'ts', interval '1 month', p_paused => false, p_lock_timeout => '5s')$q$),
  '', 'LIVENESS: (C) once the reader committed, the cutover went through');
select bag_eq('select ts, device_id from h67c', 'select * from h67c_after',
  '(C) and the migrated table holds the 59 devices, 17 not among them');
select dblink_disconnect('r67c') \g /dev/null
select dblink_disconnect('d67c') \g /dev/null

-- ============================================ PART D ============================================
select mk_plain_hypertable('h67d', 90, '1 day', '10 days') \g /dev/null
create temp table h67d_before as select ts, device_id from h67d;
select dblink_connect('r67d', current_setting('t67.connstr')) \g /dev/null
select dblink_exec('r67d', 'begin isolation level repeatable read') \g /dev/null
create temp table h67d_reader as select pid from dblink('r67d', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
call pgpm.from_hypertable_copy('h67d', 'ts');
-- the reader runs a statement that does not touch the table and outlasts the cutover's budget
select dblink_send_query('r67d', 'select pg_sleep(3)') \g /dev/null
select pg_sleep(0.2) \g /dev/null
select ok((select state = 'active' and backend_xmin is not null from pg_stat_activity where pid = (select pid from h67d_reader)),
  'LIVENESS: (D) the reader is in the middle of a statement, its snapshot from before the copy still held');
select dblink_connect('d67d', current_setting('t67.connstr')) \g /dev/null
select alike(pg_temp.t67_cutover('d67d', $q$call pgpm.from_hypertable_cutover('h67d', 'ts', interval '1 month', p_paused => false, p_predrain => false, p_lock_timeout => '1s')$q$),
  'ERROR:  pg_partition_magician: hypertable cutover deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select pid from h67d_reader) || ',%',
  '(D) the cutover refused under the reader mid-statement, naming it: it never settles');
select is((select relkind::text from pg_class where oid = 'h67d'::regclass), 'r', '(D) the hypertable was not swapped');
select count(*) from dblink_get_result('r67d') as t(r text) \g /dev/null
select count(*) from dblink_get_result('r67d') as t(r text) \g /dev/null
select bag_eq($$ select * from dblink('r67d', 'select ts, device_id from h67d') as t(ts timestamptz, device_id bigint) $$,
  'select * from h67d_before', '(D) the reader''s next statement reads every row of the hypertable, by identity');
select dblink_exec('r67d', 'commit') \g /dev/null
select dblink_disconnect('r67d') \g /dev/null
select dblink_disconnect('d67d') \g /dev/null

-- ============================================ PART E ============================================
select mk_plain_hypertable('h67e', 75, '1 day', '10 days') \g /dev/null
create temp table h67e_before as select ts, device_id from h67e;
create temp table h67e_state (k text primary key, v text);
-- A: REPEATABLE READ, its snapshot taken before the copy and exported, no lock on the table
select dblink_connect('a67e', current_setting('t67.connstr')) \g /dev/null
select dblink_exec('a67e', 'begin isolation level repeatable read') \g /dev/null
insert into h67e_state select 'snap', s from dblink('a67e', 'select pg_export_snapshot()') as t(s text);
insert into h67e_state select 'apid', p::text from dblink('a67e', 'select pg_backend_pid()') as t(p int);
call pgpm.from_hypertable_copy('h67e', 'ts');
-- the cutover, its budget 3 s; it waits for A
select dblink_connect('d67e', current_setting('t67.connstr')) \g /dev/null
insert into h67e_state select 'dpid', p::text from dblink('d67e', 'select pg_backend_pid()') as t(p int);
select dblink_send_query('d67e', $q$call pgpm.from_hypertable_cutover('h67e', 'ts', interval '1 month', p_paused => false, p_predrain => false, p_lock_timeout => '3s')$q$) \g /dev/null
do $$
begin
  for i in 1..400 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where pid = (select v::int from h67e_state where k = 'dpid')
                        and wait_event = 'PgSleep');
    perform pg_sleep(0.01);
  end loop;
end $$;
insert into h67e_state select 'd_waiting_at', clock_timestamp()::text
  where exists (select 1 from pg_stat_activity where pid = (select v::int from h67e_state where k = 'dpid') and wait_event = 'PgSleep');
select ok(exists (select 1 from h67e_state where k = 'd_waiting_at'), 'LIVENESS: (E) the cutover is in its snapshot wait (waiting for A)');
-- B: opened NOW, after the wait began, importing A's snapshot
select dblink_connect('b67e', current_setting('t67.connstr')) \g /dev/null
select dblink_exec('b67e', 'begin isolation level repeatable read') \g /dev/null
select dblink_exec('b67e', format('set transaction snapshot %L', (select v from h67e_state where k = 'snap'))) \g /dev/null
insert into h67e_state select 'bpid', p::text from dblink('b67e', 'select pg_backend_pid()') as t(p int);
select ok((select b.backend_xmin = a.backend_xmin and b.xact_start > (select v::timestamptz from h67e_state where k = 'd_waiting_at')
             from pg_stat_activity a, pg_stat_activity b
            where a.pid = (select v::int from h67e_state where k = 'apid') and b.pid = (select v::int from h67e_state where k = 'bpid')),
  'LIVENESS: (E) B began after the cutover''s wait did, and holds A''s snapshot (the same backend_xmin)');
select dblink_exec('a67e', 'commit') \g /dev/null
do $$
begin
  for i in 1..600 loop
    exit when dblink_is_busy('d67e') = 0;
    perform pg_sleep(0.05);
  end loop;
end $$;
create temp table h67e_outcome as
  select (select r from dblink_get_result('d67e', false) as t(r text) limit 1) as status, dblink_error_message('d67e') as msg;
select count(*) from dblink_get_result('d67e', false) as t(r text) \g /dev/null
select alike((select msg from h67e_outcome),
  'ERROR:  pg_partition_magician: hypertable cutover deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select v from h67e_state where k = 'bpid') || ',%',
  '(E) once A committed, the cutover waited for B, the importer, and refused');
select is((select relkind::text from pg_class where oid = 'h67e'::regclass), 'r', '(E) the hypertable was not swapped');
select bag_eq($$ select * from dblink('b67e', 'select ts, device_id from h67e') as t(ts timestamptz, device_id bigint) $$,
  'select * from h67e_before', '(E) B reads every row of the hypertable, by identity');
select dblink_exec('b67e', 'commit') \g /dev/null
select dblink_disconnect('a67e') \g /dev/null
select dblink_disconnect('b67e') \g /dev/null
select dblink_disconnect('d67e') \g /dev/null

-- ============================================ PART F ============================================
select mk_plain_hypertable('h67f', 66, '1 day', '10 days') \g /dev/null
create temp table h67f_before as select ts, device_id from h67f;
create temp table h67f_state (k text primary key, v text);
create table h67f_w (x int);
-- W: a writer idle in its transaction from here on, holding the oldest running xid
select dblink_connect('w67f', current_setting('t67.connstr')) \g /dev/null
select dblink_exec('w67f', 'begin') \g /dev/null
select dblink_exec('w67f', 'insert into h67f_w values (1)') \g /dev/null
insert into h67f_state select 'wpid', p::text from dblink('w67f', 'select pg_backend_pid()') as t(p int);
-- A: REPEATABLE READ, its snapshot taken before the copy and exported
select dblink_connect('a67f', current_setting('t67.connstr')) \g /dev/null
select dblink_exec('a67f', 'begin isolation level repeatable read') \g /dev/null
insert into h67f_state select 'snap', s from dblink('a67f', 'select pg_export_snapshot()') as t(s text);
call pgpm.from_hypertable_copy('h67f', 'ts');
-- the state a copy made before the record existed is in: no recorded last write
update pgpm.scratch set written_xid = null where parent_oid = 'h67f'::regclass::oid and kind = 'hypertable_dest';
select ok((select written_xid is null from pgpm.scratch where parent_oid = 'h67f'::regclass::oid and kind = 'hypertable_dest'),
  'LIVENESS: (F) the copy has no recorded last write (the cutover waits against its own xid)');
select dblink_connect('d67f', current_setting('t67.connstr')) \g /dev/null
insert into h67f_state select 'dpid', p::text from dblink('d67f', 'select pg_backend_pid()') as t(p int);
select dblink_send_query('d67f', $q$call pgpm.from_hypertable_cutover('h67f', 'ts', interval '1 month', p_paused => false, p_predrain => false, p_lock_timeout => '3s')$q$) \g /dev/null
do $$
begin
  for i in 1..400 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where pid = (select v::int from h67f_state where k = 'dpid')
                        and wait_event = 'PgSleep');
    perform pg_sleep(0.01);
  end loop;
end $$;
insert into h67f_state select 'd_waiting_at', clock_timestamp()::text
  where exists (select 1 from pg_stat_activity where pid = (select v::int from h67f_state where k = 'dpid') and wait_event = 'PgSleep');
select ok(exists (select 1 from h67f_state where k = 'd_waiting_at'), 'LIVENESS: (F) the cutover is in its snapshot wait');
-- B: opened after the wait began, importing A's snapshot
select dblink_connect('b67f', current_setting('t67.connstr')) \g /dev/null
select dblink_exec('b67f', 'begin isolation level repeatable read') \g /dev/null
select dblink_exec('b67f', format('set transaction snapshot %L', (select v from h67f_state where k = 'snap'))) \g /dev/null
insert into h67f_state select 'bpid', p::text from dblink('b67f', 'select pg_backend_pid()') as t(p int);
select ok((select b.xact_start > (select v::timestamptz from h67f_state where k = 'd_waiting_at')
                  and w.backend_xid is not null and age(b.backend_xmin) >= age(w.backend_xid)
             from pg_stat_activity b, pg_stat_activity w
            where b.pid = (select v::int from h67f_state where k = 'bpid') and w.pid = (select v::int from h67f_state where k = 'wpid')),
  'LIVENESS: (F) B began after the cutover''s wait did, its xmin at or before W''s xid (equal to it when no other transaction runs)');
select dblink_exec('a67f', 'commit') \g /dev/null
do $$
begin
  for i in 1..600 loop
    exit when dblink_is_busy('d67f') = 0;
    perform pg_sleep(0.05);
  end loop;
end $$;
create temp table h67f_outcome as
  select (select r from dblink_get_result('d67f', false) as t(r text) limit 1) as status, dblink_error_message('d67f') as msg;
select count(*) from dblink_get_result('d67f', false) as t(r text) \g /dev/null
select ok((select msg from h67f_outcome) ~ ('^ERROR:  pg_partition_magician: hypertable cutover deferred: [0-9]+ snapshot\(s\) older than the copies still open \(oldest: pid [0-9]+, open [^;]*; pids ([0-9]+, )*'
                                            || (select v from h67f_state where k = 'bpid') || '(, [0-9]+)*\)')
          and (select relkind::text from pg_class where oid = 'h67f'::regclass) = 'r',
  '(F) once A committed, the cutover waited for B, the importer, refused naming it, and did not swap');
select bag_eq($$ select * from dblink('b67f', 'select ts, device_id from h67f') as t(ts timestamptz, device_id bigint) $$,
  'select * from h67f_before', '(F) B reads every row of the hypertable, by identity');
select dblink_exec('b67f', 'commit') \g /dev/null
select dblink_exec('w67f', 'rollback') \g /dev/null
select dblink_disconnect('a67f') \g /dev/null
select dblink_disconnect('b67f') \g /dev/null
select dblink_disconnect('d67f') \g /dev/null
select dblink_disconnect('w67f') \g /dev/null

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
