-- P1-01: the refusal at the budget does NOT name the transaction in ANOTHER database that holds every snapshot back.
--
-- pgpm._snapshot_wait's holder lookup (the FLOOR HOLDER clause added for #1263) filters pg_stat_activity by
-- `a.datid = v_db`, so a transaction older than the copies that runs in another database (the very case of
-- #1263) is never found; the message falls through to the old one, which calls the local READ COMMITTED reader
-- "a reader [that] would find the regrained range empty". docs/reference.md (regrain_step, "Other databases'
-- transactions still count") and the function comment promise the clause
-- "a transaction older than the copies is still running in database D (pid H, xid X, open T)".
--
-- X: a transaction with an xid in another database, taken before any copy. B: a READ COMMITTED statement of this
-- database begun after every copy committed (it sees them), held in pg_sleep. The swap at a 300 ms budget refuses.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(7);

create temp table p101_state (k text primary key, v text);
select dblink_exec('dbname=' || current_database() || ' user=postgres',
                   format('drop database if exists %I', current_database() || '_p1x'));
select dblink_exec('dbname=' || current_database() || ' user=postgres',
                   format('create database %I', current_database() || '_p1x'));

-- the table: the multiples of 26 to 494, converted to a [0, 500) monolith and frozen by a frontier row
create table public.p101 (id bigint primary key, payload text);
insert into public.p101 select g, 'a' || g from generate_series(26, 494, 26) g;
call pgpm.transmute('public.p101', 'id', 100, p_paused => false);
insert into public.p101 values (2600, 'frontier');
insert into p101_state select 'src', child_name from pgpm.part
 where parent_table = 'public.p101'::regclass and attached and lo = '0';

-- X: a transaction in the other database, its xid taken before any copy
select dblink_connect('p101x', 'dbname=' || current_database() || '_p1x user=postgres');
select dblink_exec('p101x', 'begin');
insert into p101_state select 'xxid', x from dblink('p101x', 'select pg_current_xact_id()::text') as t(x text);
insert into p101_state select 'xpid', p::text from dblink('p101x', 'select pg_backend_pid()') as t(p int);

-- the copies, one regrain_step per transaction, to the swap's doorstep
do $$
begin
  for i in 1..40 loop
    exit when (select regrain_cursor from pgpm.config where parent_table = 'public.p101'::regclass) = '500';
    perform pgpm.regrain_step('public.p101', (select v from p101_state where k = 'src'), '100');
    commit;
  end loop;
end $$;
select is((select regrain_cursor from pgpm.config where parent_table = 'public.p101'::regclass), '500',
  'LIVENESS: every sub-range is copied and the run is at the swap');
select ok((select (select v from p101_state where k = 'xxid')::xid8 < c.regrain_written_xid
             from pgpm.config c where c.parent_table = 'public.p101'::regclass),
  'LIVENESS: the other database''s transaction X took its xid before the copies'' last write, and is still open');

-- B: a READ COMMITTED statement of this database, begun after the copies, held open in pg_sleep
select dblink_connect('p101b', 'dbname=' || current_database() || ' user=postgres');
insert into p101_state select 'bpid', p::text from dblink('p101b', 'select pg_backend_pid()') as t(p int);
select dblink_send_query('p101b', 'select pg_sleep(5)');
do $$
begin
  for i in 1..500 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity
                       where pid = (select v::int from p101_state where k = 'bpid')
                         and state = 'active' and wait_event = 'PgSleep' and backend_xmin is not null);
    perform pg_sleep(0.01);
  end loop;
end $$;
select is((select backend_xmin::text from pg_stat_activity where pid = (select v::int from p101_state where k = 'bpid')),
  (select v from p101_state where k = 'xxid'),
  'LIVENESS: B is running its statement and its backend_xmin is X''s xid: the other database''s transaction holds it back');
select ok((select a.query_start > l.at from pg_stat_activity a,
             (select max(at) as at from pgpm.log where parent_table = 'public.p101'::regclass and action = 'regrain_copy') l
            where a.pid = (select v::int from p101_state where k = 'bpid')),
  'LIVENESS: B''s statement began after the last copy was logged');

set lock_timeout = '300ms';
select throws_like(
  format($$ select pgpm.regrain_step('public.p101', %L, '100') $$, (select v from p101_state where k = 'src')),
  'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select v from p101_state where k = 'bpid') || ', open %; pids ' || (select v from p101_state where k = 'bpid') || ')%',
  'GUARD: the swap is refused at its budget, listing B');
select throws_like(
  format($$ select pgpm.regrain_step('public.p101', %L, '100') $$, (select v from p101_state where k = 'src')),
  '%a transaction older than the copies is still running in database ' || current_database() || '_p1x (pid '
    || (select v from p101_state where k = 'xpid') || ', xid ' || (select v from p101_state where k = 'xxid') || ', open %',
  'the refusal names the transaction that holds every snapshot back: database ' || current_database() || '_p1x, X''s pid and xid');
reset lock_timeout;
select is((select count(*) from pgpm.log where parent_table = 'public.p101'::regclass and action = 'regrain'), 0::bigint,
  'GUARD: nothing was swapped');

-- tidy: let B finish, end X, drop the other database
select * from dblink_get_result('p101b') as t(s text);
select dblink_disconnect('p101b');
select dblink_exec('p101x', 'commit');
select dblink_disconnect('p101x');
select dblink_exec('dbname=' || current_database() || ' user=postgres',
                   format('drop database %I', current_database() || '_p1x'));
select * from finish();
