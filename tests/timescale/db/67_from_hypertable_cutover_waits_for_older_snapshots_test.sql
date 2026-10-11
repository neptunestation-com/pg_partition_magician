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
-- ASYMMETRIC: the rows are judged by identity against the source as it stood (a bag), never by count.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t67.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(10);

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
select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
