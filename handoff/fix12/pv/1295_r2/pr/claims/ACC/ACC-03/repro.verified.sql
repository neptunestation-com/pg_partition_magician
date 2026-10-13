-- ACC-03, rebuilt by the claims verifier (round 2 of PR #1295). The original (round 1's V-01) needed the defect
-- to go on: its LIVENESS step 3 required adopt_partition to RECORD the renamed partition, and its defect checks
-- (a lock held on the recorded relation, the relation still attached at commit) are only meaningful after that.
-- The fix makes the call refuse, so the original stops at its own premise (premise_removed). This version pins
-- the contract instead:
--   * READ COMMITTED; session b renames the partition away and creates a standalone table under its old name,
--     uncommitted; session a calls adopt_partition by oid and waits for the partition's lock (witnessed in
--     pg_locks, polled server-side); b commits;
--   * the call REFUSES, naming the partition as it is now (v1_x_old), and nothing is recorded for it;
--   * the remedy as typed (the call naming the current name, READ COMMITTED) records it by oid, and while its
--     transaction is open a DETACH of it from another session waits and gives up at lock_timeout (55P03);
--     after commit the row names v1_x_old by oid and the partition is still attached with its rows.
-- Fails on the base and on the adopt_partition_lock_name_unchecked mutant (the call records the partition with
-- the lock on the squatter); passes on the head.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(9);

create table public.v1 (id bigint primary key, payload text);
insert into public.v1 values (150, 'a');
call pgpm.transmute('public.v1', 'id', 100::bigint, p_obtain => 1, p_paused => false);
create table public.v1_x partition of public.v1 for values from (900) to (1000);
insert into public.v1 values (950, 'x'), (960, 'xx');
select 'public.v1_x'::regclass::oid as x_oid \gset
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.v1'::regclass and child_oid = :x_oid)
          and exists (select 1 from pg_inherits where inhparent = 'public.v1'::regclass and inhrelid = :x_oid),
  'LIVENESS: v1_x is attached and untracked');

-- run a statement on a dblink connection and return its first column, or 'ERROR: <message>' (never raises)
create function pg_temp.rcall(p_conn text, p_sql text) returns text language plpgsql as $f$
declare v text; n int := 0;
begin
  perform dblink_send_query(p_conn, p_sql);
  loop
    exit when dblink_is_busy(p_conn) = 0;
    perform pg_sleep(0.02);
    n := n + 1;
    if n > 1500 then return 'ERROR: timeout'; end if;
  end loop;
  begin
    select r into v from dblink_get_result(p_conn) as t(r text);
  exception when others then
    v := 'ERROR: ' || sqlerrm;
  end;
  perform 1 from dblink_get_result(p_conn, false) as t(r text);   -- drain
  return v;
end $f$;
-- true once p_pid waits (ungranted) for a lock on relation p_rel; pg_locks is live, polled server-side
create function pg_temp.waits(p_pid int, p_rel oid) returns boolean language plpgsql as $f$
begin
  for i in 1..500 loop
    if exists (select 1 from pg_locks where pid = p_pid and relation = p_rel and not granted) then return true; end if;
    perform pg_sleep(0.02);
  end loop;
  return false;
end $f$;

select format('dbname=%s user=postgres', current_database()) as conn \gset
select dblink_connect('b', :'conn') as b \gset
select dblink_connect('a', :'conn') as a \gset
select x as a_pid from dblink('a', 'select pg_backend_pid()') as t(x int) \gset
-- b renames the partition and creates a standalone table under its old name, transaction left open
select dblink_exec('b', 'begin') as x \gset
select dblink_exec('b', 'alter table public.v1_x rename to v1_x_old') as x \gset
select dblink_exec('b', 'create table public.v1_x (id bigint)') as x \gset
-- a (READ COMMITTED) calls adopt_partition on the partition, by oid; it waits for the partition's lock
select dblink_exec('a', 'begin isolation level read committed') as x \gset
select dblink_send_query('a', format('select pgpm.adopt_partition(%L, %s::oid::regclass)', 'public.v1', :x_oid)) as sent \gset
select ok(pg_temp.waits(:a_pid, :x_oid),
  'LIVENESS: the call waits for the partition''s lock while the rename and the squatter are uncommitted');
select dblink_exec('b', 'commit') as x \gset
select ok(to_regclass('public.v1_x') is distinct from :x_oid::regclass
          and to_regclass('public.v1_x') is not null
          and (select relname from pg_class where oid = :x_oid) = 'v1_x_old',
  'LIVENESS: the rename and the squatter committed: v1_x is a different relation, the partition is v1_x_old');
create temporary table call1 as
  select coalesce((select r from dblink_get_result('a', false) as t(r text)), '') || '|' || dblink_error_message('a') as r;
select count(*) as drained from dblink_get_result('a', false) as t(r text) \gset
-- a COMMIT of an aborted transaction rolls it back
select dblink_exec('a', 'commit') as x \gset
select matches((select r from call1),
  'cannot adopt v1_x_old \(oid [0-9]+\): the name public\.v1_x no longer denotes it.*naming the partition as it is now, v1_x_old',
  'the call refuses, naming the partition as it is now');
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :x_oid), null,
  'nothing is recorded for the partition (under either name)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.v1'::regclass and action = 'adopt_partition'),
  0, 'no adoption logged');

-- the remedy as typed: the call naming the partition as it is now, READ COMMITTED
select dblink_exec('a', 'begin isolation level read committed') as x \gset
select pg_temp.rcall('a', $$select pgpm.adopt_partition('public.v1', 'public.v1_x_old')$$) as remedy \gset
select ok(:'remedy' like '%is a partition of this table that pgpm.part had no row for%',
  'the remedy as typed records the partition');
-- while a's transaction is open, a DETACH of the partition waits for a's lock and gives up
create temporary table det as select 'not tried'::text as outcome;
set lock_timeout = '2s';
do $$ begin
  execute 'alter table public.v1 detach partition public.v1_x_old';
  update det set outcome = 'detached';
exception when lock_not_available then
  update det set outcome = '55P03';
end $$;
reset lock_timeout;
select is((select outcome from det), '55P03',
  'a DETACH of the adopted partition waits for the call''s lock and gives up at lock_timeout');
select dblink_exec('a', 'commit') as x \gset
select is((select p.child_name || ' [' || p.lo || ', ' || p.hi || ') attached=' ||
                  exists (select 1 from pg_inherits i where i.inhparent = 'public.v1'::regclass and i.inhrelid = :x_oid)::text
                  || ' rows=' || (select string_agg(id::text, ',' order by id) from public.v1_x_old)
             from pgpm.part p where p.parent_table = 'public.v1'::regclass and p.child_oid = :x_oid),
  'v1_x_old [900, 1000) attached=true rows=950,960',
  'after commit pgpm.part records v1_x_old by oid over its bounds, still attached with its rows');
select dblink_disconnect('a'), dblink_disconnect('b');
select * from finish();
