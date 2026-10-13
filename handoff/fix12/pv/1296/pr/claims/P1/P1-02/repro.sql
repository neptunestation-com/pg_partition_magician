-- P1-02: under maintain, the holder clause never reaches the skip_regrain log row.
--
-- maintain's regrain tick catches the step's error and logs it as skip_regrain with left(sqlerrm, 200). The
-- refusal's head, up to and including 'a transaction older than the copies is still running in database ', is
-- 206 characters with ONE pid listed, so the holder's database, pid and xid (the remedy the clause exists to
-- give, per docs/reference.md: "the tick logs skip_regrain with method beginning ... the holder clause above
-- follows when a transaction older than the copies is still running") are cut off in every skip_regrain row.
-- The operator who only sees maintain's log (the issue's own scenario: skip_regrain every tick) cannot learn
-- which transaction to end.
--
-- The holder here is a transaction of THIS database (a writer with an xid older than the copies, which the
-- lookup finds on this tree), so the claim is independent of P1-01's datid filter: the hand regrain_step
-- (GUARD) shows the clause whole, the maintain tick's log row does not.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(9);

create temp table p102_state (k text primary key, v text);
create table public.p102_other (id int);

-- the table: the multiples of 26 to 494, converted to a [0, 500) monolith and frozen by a frontier row,
-- with auto-regrain to step 100 so maintain's ticks do the copies and the swap
create table public.p102 (id bigint primary key, payload text);
insert into public.p102 select g, 'a' || g from generate_series(26, 494, 26) g;
call pgpm.transmute('public.p102', 'id', 100, p_paused => false);
insert into public.p102 values (2600, 'frontier');
select pgpm.set_regrain('public.p102', '100');
insert into p102_state select 'src', child_name from pgpm.part
 where parent_table = 'public.p102'::regclass and attached and lo = '0';

-- W: a REPEATABLE READ transaction of THIS database with an xid taken before any copy (a writer of an unrelated
-- table), kept open: it holds its snapshot (so it is listed) and its xid (so it is the floor holder)
select dblink_connect('p102w', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('p102w', 'begin isolation level repeatable read');
select dblink_exec('p102w', 'insert into public.p102_other values (1)');
insert into p102_state select 'wxid', x from dblink('p102w', 'select pg_current_xact_id()::text') as t(x text);
insert into p102_state select 'wpid', p::text from dblink('p102w', 'select pg_backend_pid()') as t(p int);

-- maintain ticks, each its own transaction, until the copies are at the swap's doorstep
do $$
declare v_status text;
begin
  for i in 1..60 loop
    exit when (select regrain_cursor from pgpm.config where parent_table = 'public.p102'::regclass) = '500';
    call pgpm.maintain('public.p102', v_status);
    commit;
  end loop;
end $$;
select is((select regrain_cursor from pgpm.config where parent_table = 'public.p102'::regclass), '500',
  'LIVENESS: maintain''s ticks copied every sub-range and the run is at the swap');
select ok((select (select v from p102_state where k = 'wxid')::xid8 < c.regrain_written_xid
             from pgpm.config c where c.parent_table = 'public.p102'::regclass),
  'LIVENESS: W took its xid before the copies'' last write');
select ok(exists (select 1 from pg_stat_activity where pid = (select v::int from p102_state where k = 'wpid')
                     and backend_xid::text = (select v from p102_state where k = 'wxid')),
  'LIVENESS: W is still open with that xid');
select ok(exists (select 1 from pg_stat_activity where pid = (select v::int from p102_state where k = 'wpid')
                     and backend_xmin is not null),
  'LIVENESS: and W holds its snapshot, so the swap must wait for it');

-- the refusal seen whole, by a hand regrain_step at the same budget maintain uses
set lock_timeout = '200ms';
select throws_like(
  format($$ select pgpm.regrain_step('public.p102', %L, '100') $$, (select v from p102_state where k = 'src')),
  'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select v from p102_state where k = 'wpid') || ', open %; pids ' || (select v from p102_state where k = 'wpid')
    || '); a transaction older than the copies is still running in database ' || current_database() || ' (pid '
    || (select v from p102_state where k = 'wpid') || ', xid ' || (select v from p102_state where k = 'wxid') || ', open %',
  'GUARD: the refusal, seen whole, names W as the holder: database, pid and xid');
reset lock_timeout;

-- the swap tick under maintain: refused at its 200 ms budget and logged as skip_regrain
insert into p102_state values ('before', clock_timestamp()::text);
call pgpm.maintain('public.p102');
select is((select count(*) from pgpm.log where parent_table = 'public.p102'::regclass and action = 'regrain'), 0::bigint,
  'GUARD: nothing was swapped');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.p102'::regclass and action = 'skip_regrain'
                     and at >= (select v::timestamptz from p102_state where k = 'before')
                     and method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
                                     || (select v from p102_state where k = 'wpid') || ',%'),
  'LIVENESS: the tick logged the deferred swap as skip_regrain, its method beginning with the refusal''s head');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.p102'::regclass and action = 'skip_regrain'
                     and at >= (select v::timestamptz from p102_state where k = 'before')
                     and method like '%a transaction older than the copies is still running%'),
  'LIVENESS: and that row says a transaction older than the copies is still running');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.p102'::regclass and action = 'skip_regrain'
                     and at >= (select v::timestamptz from p102_state where k = 'before')
                     and method like '%still running in database ' || current_database() || ' (pid '
                                     || (select v from p102_state where k = 'wpid') || ', xid ' || (select v from p102_state where k = 'wxid') || '%'),
  'the skip_regrain row names the holder: its database, pid and xid (the remedy maintain''s operator needs)');

select dblink_exec('p102w', 'rollback');
select dblink_disconnect('p102w');
select * from finish();
