-- pgpm.adopt_partition() judges the partition through a snapshot taken after its lock: READ COMMITTED only
-- (issue #1262).
--
-- THE BUG. adopt_partition locks the partition in SHARE UPDATE EXCLUSIVE mode and then re-reads the catalog to
-- judge it attached and not pending, read its name and its bounds. Those reads went through the caller's
-- snapshot, and under REPEATABLE READ or SERIALIZABLE that is the transaction's first one, which can predate a
-- change another session committed before the call. A DETACH committed after the snapshot was still read as
-- attached, so pgpm.part recorded a standalone table as a partition of the parent; a RENAME committed after it
-- was read under the old name, so the row recorded a name that no longer resolves to the oid it records (the
-- identity wedge adopt_partition exists to repair). The same call in READ COMMITTED refused, or read the
-- current name.
--
-- THE CONTRACT. adopt_partition refuses any transaction stricter than READ COMMITTED, before it locks or writes
-- anything, with a refusal that names the remedy, and the remedy works.
--   PART A  REPEATABLE READ, snapshot taken before another session's DETACH committed: refused, and nothing is
--           recorded for the detached table.
--   PART B  REPEATABLE READ, snapshot taken before another session's RENAME committed (the table is still
--           attached, so asking only whether it is attached would let this through): refused, nothing recorded.
--   PART C  SERIALIZABLE, a partition nothing touches: refused, nothing recorded.
--   PART D  the remedy as the refusal types it, in a session whose default_transaction_isolation is REPEATABLE
--           READ: BEGIN ISOLATION LEVEL READ COMMITTED, the call, COMMIT. The renamed partition is recorded by
--           its oid under its CURRENT name over its own bounds, the untouched one is recorded too, and the
--           detached table is refused as not a partition, so pgpm.part holds exactly the two attached ones.
--   PART E  READ COMMITTED, the partition renamed and a standalone table created under its old name, committed
--           while the call waits for the partition's lock (LOCK TABLE takes a name, and re-resolves it once
--           granted, so the lock lands on the squatter): refused, naming the partition as it is now, nothing
--           recorded. The remedy as typed (the call naming the partition's current name) records it, and while
--           its transaction is open a detach of that partition waits for its lock (the row's guarantee).
--   PART F  READ COMMITTED, the partition's SCHEMA swapped with one holding a partitioned table of the same name
--           while the call waits, and swapped back while LOCK TABLE waits on that table's partition: the name
--           denotes the partition again, but the call holds no lock on it. Refused (the lock manager is asked,
--           not the name), nothing recorded; the remedy as typed records it.
--   PART G  READ COMMITTED, a rename with nothing put in its place: pgpm's refusal naming the partition as it
--           is now, not LOCK TABLE's 42P01 about the old name; the remedy as typed records it.
--   PART H  READ COMMITTED, the partition DROPPED by the transaction the call waits on, nothing put in its
--           place. LOCK TABLE raises the same 42P01 as in G, and there is no lock on the oid, but nothing was
--           renamed and there is no "partition as it is now" to name (a dropped oid renders as a number): the
--           refusal says the relation no longer exists and that there is nothing to adopt, and names no re-run.
--           A later call given the dropped oid is refused the same way, before it asks for the partition's lock.
--   PART I  READ COMMITTED, the partition dropped and a new partition created under its name, committed
--           while the call waits: the lock lands on the new relation, and the refusal is still the dropped
--           one, saying the relation of that name now is a different one. It is: a call naming it adopts it,
--           under its own oid.
--
-- adopt_partition is a function, not a committing procedure, so its refusals are pinned by message.
-- ASYMMETRIC FIXTURES. Three hand partitions: x [900, 1000) holds 950 and is renamed, y [1000, 1100) holds
-- 1010 and 1020 and is detached, z [1100, 1200) holds 1111, 1122 and 1133 and is left alone. Two end up
-- recorded and one does not, and every check names the relation by oid and name, never a count alone. E's w
-- [1200, 1300) holds 1234, 1256 and 1278, and its squatter none; F's v [1300, 1400) 1301 and 1350; G's u
-- [1400, 1500) 1444; H's d [1500, 1600) 1511 and 1522, dropped with them; I's c [1600, 1700) 1601 and 1602,
-- dropped with them, and the c created in its place 1666.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(51);

create table public.t332 (id bigint primary key, payload text);
insert into public.t332 values (150, 'a');
call pgpm.transmute('public.t332', 'id', 100::bigint, p_obtain => 1, p_paused => false);
-- attached partitions pgpm.part has no row for: what adopt_partition exists to record
create table public.t332_x partition of public.t332 for values from (900) to (1000);
create table public.t332_y partition of public.t332 for values from (1000) to (1100);
create table public.t332_z partition of public.t332 for values from (1100) to (1200);
insert into public.t332 values (950, 'x'), (1010, 'y'), (1020, 'y'), (1111, 'z'), (1122, 'z'), (1133, 'z');
select 'public.t332_x'::regclass::oid as x_oid, 'public.t332_y'::regclass::oid as y_oid,
       'public.t332_z'::regclass::oid as z_oid \gset

select is((select string_agg(c.relname || ':' || pg_get_expr(c.relpartbound, c.oid), ', ' order by c.relname)
             from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t332'::regclass and c.relname in ('t332_x', 't332_y', 't332_z')),
          't332_x:FOR VALUES FROM (''900'') TO (''1000''), t332_y:FOR VALUES FROM (''1000'') TO (''1100''), t332_z:FOR VALUES FROM (''1100'') TO (''1200'')',
          'LIVENESS: x, y and z are attached over their own bounds');
select is((select string_agg(child_name, ',') from pgpm.part where parent_table = 'public.t332'::regclass
            and child_oid in (:x_oid, :y_oid, :z_oid)), null,
          'LIVENESS: and pgpm.part records none of them');
select dblink_connect('o332', 'dbname=' || current_database()) as o332 \gset

-- ============================ (A) a DETACH committed after the snapshot ============================
begin isolation level repeatable read;
select count(*) as a_snap from pgpm.config \gset
select dblink_exec('o332', 'alter table public.t332 detach partition public.t332_y') as a_detached \gset
select ok(exists (select 1 from pg_inherits where inhrelid = :y_oid)
          and not exists (select 1 from pg_partition_ancestors(:y_oid::regclass) a where a.relid = 'public.t332'::regclass)
          and (select x from dblink('o332', format('select count(*)::int from pg_inherits where inhrelid = %s', :y_oid)) as t(x int)) = 0,
  'LIVENESS: A: the detach committed, and this transaction''s snapshot still shows y attached');
select throws_like(
  $$ select pgpm.adopt_partition('public.t332', 'public.t332_y') $$,
  'pg_partition_magician: adopt_partition(t332, t332_y) must run in a READ COMMITTED transaction (this one is repeatable read)%BEGIN ISOLATION LEVEL READ COMMITTED, the call, COMMIT',
  'A: under REPEATABLE READ adopt_partition refuses, naming the remedy');
commit;
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :y_oid), null,
  'A: nothing is recorded for the detached table');

-- ============================ (B) a RENAME committed after the snapshot ============================
begin isolation level repeatable read;
select count(*) as b_snap from pgpm.config \gset
select dblink_exec('o332', 'alter table public.t332_x rename to t332_x_renamed') as b_renamed \gset
select ok((select relname from pg_class where oid = :x_oid) = 't332_x'
          and exists (select 1 from pg_partition_ancestors(:x_oid::regclass) a where a.relid = 'public.t332'::regclass)
          and (select x from dblink('o332', format('select relname::text from pg_class where oid = %s', :x_oid)) as t(x text)) = 't332_x_renamed',
  'LIVENESS: B: the rename committed and x is still attached, and this transaction''s snapshot still reads its old name');
select throws_like(
  format('select pgpm.adopt_partition(%L, %L)', 'public.t332', :x_oid::regclass::text),
  'pg_partition_magician: adopt_partition(t332, t332_x_renamed) must run in a READ COMMITTED transaction (this one is repeatable read)%',
  'B: under REPEATABLE READ adopt_partition refuses a partition that is still attached too');
commit;
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :x_oid), null,
  'B: nothing is recorded for x, under either name');

-- ============================ (C) SERIALIZABLE ============================
begin isolation level serializable;
select throws_like(
  $$ select pgpm.adopt_partition('public.t332', 'public.t332_z') $$,
  'pg_partition_magician: adopt_partition(t332, t332_z) must run in a READ COMMITTED transaction (this one is serializable)%',
  'C: under SERIALIZABLE adopt_partition refuses');
commit;
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :z_oid), null,
  'C: nothing is recorded for z');
select is((select count(*)::int from pgpm.log where parent_table = 'public.t332'::regclass and action = 'adopt_partition'),
  0, 'A, B, C: no refusal logged an adoption');

-- ============================ (D) the remedy, as typed ============================
-- the session default is REPEATABLE READ, so the remedy is the explicit level the refusal names
set default_transaction_isolation = 'repeatable read';
begin isolation level read committed;
select lives_ok(
  format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 'public.t332_x_renamed'),
  'D: BEGIN ISOLATION LEVEL READ COMMITTED, the call, COMMIT adopts the renamed partition');
select lives_ok(
  $$ select pgpm.adopt_partition('public.t332', 'public.t332_z') $$,
  'D: and the untouched one');
select throws_like(
  $$ select pgpm.adopt_partition('public.t332', 'public.t332_y') $$,
  'pg_partition_magician: t332_y is not a partition of t332:%',
  'D: and refuses the detached table as not a partition, which is what the stale snapshot hid');
commit;
reset default_transaction_isolation;

-- filtered by parent in a MATERIALIZED CTE before any bound is cast (#973)
with mine as materialized (select * from pgpm.part where parent_table = 'public.t332'::regclass)
select is((select string_agg(child_name || ' [' || lo || ', ' || hi || ') oid ' || case child_oid when :x_oid then 'x' when :z_oid then 'z' else child_oid::text end,
                             '; ' order by lo::bigint)
             from mine where child_oid in (:x_oid, :y_oid, :z_oid)),
          't332_x_renamed [900, 1000) oid x; t332_z [1100, 1200) oid z',
  'D: pgpm.part records x under its current name and z, each by its oid over its own bounds, and not y');
select is((select string_agg(id::text, ',' order by id) from public.t332_y), '1010,1020',
  'LIVENESS: D: the detached table keeps its rows 1010 and 1020, outside the parent');
select is((select string_agg(id::text, ',' order by id) from public.t332 where id >= 900), '950,1111,1122,1133',
  'D: the parent holds 950, 1111, 1122 and 1133 through the adopted partitions');
select is((select string_agg(lo || '..' || hi, ',' order by id) from pgpm.log
            where parent_table = 'public.t332'::regclass and action = 'adopt_partition'),
  '900..1000,1100..1200', 'D: one adoption logged per partition recorded, x''s range then z''s');

-- ============================ (E) a rename and a squatter while the call waits for its lock ============================
-- READ COMMITTED throughout. Session eb renames w away and creates a standalone table under w's old name, and holds
-- both uncommitted; the call (session ea, naming w) passes its first check and waits behind eb for w's lock; eb
-- commits. LOCK TABLE takes a name and resolves it again once granted, so the lock lands on the squatter: the call
-- must refuse rather than record w with no lock on it. The order is set by the lock queue and witnessed in
-- pg_locks, not by sleeps.
create table public.t332_w partition of public.t332 for values from (1200) to (1300);
insert into public.t332 values (1234, 'w'), (1256, 'w'), (1278, 'w');
select 'public.t332_w'::regclass::oid as w_oid \gset
create function pg_temp.t332_waits(p_pid int, p_rel oid) returns boolean
language plpgsql as $$
begin
  for i in 1..500 loop
    if exists (select 1 from pg_locks l where l.pid = p_pid and not l.granted and l.locktype = 'relation'
                 and l.relation = p_rel) then
      return true;
    end if;
    perform pg_sleep(0.01);
  end loop;
  return false;
end;
$$;
select dblink_connect('ea', 'dbname=' || current_database()) as ea \gset
select dblink_connect('eb', 'dbname=' || current_database()) as eb \gset
select pid as ea_pid from dblink('ea', 'select pg_backend_pid()') as t(pid int) \gset
select pid as o_pid from dblink('o332', 'select pg_backend_pid()') as t(pid int) \gset
select dblink_exec('eb', 'begin') as eb_begin \gset
select dblink_exec('eb', 'alter table public.t332_w rename to t332_w_old') as eb_rename \gset
select dblink_exec('eb', 'create table public.t332_w (id bigint, payload text)') as eb_squat \gset
select dblink_exec('ea', 'begin isolation level read committed') as ea_begin \gset
select dblink_send_query('ea', format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 'public.t332_w')) as ea_sent \gset
select ok(pg_temp.t332_waits(:ea_pid, :w_oid),
  'LIVENESS: E: adopt_partition passed its first check and waits behind the rename for w''s lock');
select dblink_exec('eb', 'commit') as eb_commit \gset
select count(*) as ea_rows from dblink_get_result('ea', false) as t(x text) \gset
select ok(dblink_error_message('ea') like '%cannot adopt t332_w_old (oid ' || :w_oid || '): this call holds no lock on it, because the name public.t332_w it locked by stopped denoting it%Re-run adopt_partition naming the partition as it is now, t332_w_old%',
  'E: the name it locked now denotes the squatter, so adopt_partition refuses, naming the partition as it is now');
select count(*) as ea_drained from dblink_get_result('ea', false) as t(x text) \gset
-- COMMIT, not ROLLBACK: a call that recorded w under a lock on the squatter would commit its row here
select dblink_exec('ea', 'commit') as ea_commit0 \gset
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :w_oid), null,
  'E: nothing is recorded for w when the call''s transaction commits');
select ok(to_regclass('public.t332_w') <> :w_oid
          and exists (select 1 from pg_inherits where inhparent = 'public.t332'::regclass and inhrelid = :w_oid),
  'LIVENESS: E: the name is the squatter''s now, and w is still attached as t332_w_old');

-- the remedy, as typed: the call again, naming the partition as it is now. Its lock is on w: a detach of w
-- from another session waits for it, and gives up at its lock_timeout, while the call's transaction is open.
select dblink_exec('ea', 'begin isolation level read committed') as ea_begin2 \gset
select lives_ok(format('select * from dblink(%L, %L) as t(r text)', 'ea',
                       format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 'public.t332_w_old')),
  'E: the call again, naming the partition as it is now, adopts it');
select dblink_exec('o332', $$set lock_timeout = '300ms'$$) as o_timeout \gset
select throws_ok(format('select dblink_exec(%L, %L)', 'o332', 'alter table public.t332 detach partition public.t332_w_old'),
  '55P03', NULL,
  'E: while the remedy''s transaction is open, a detach of the partition it recorded waits for its lock');
select dblink_exec('ea', 'commit') as ea_commit \gset
with mine as materialized (select * from pgpm.part where parent_table = 'public.t332'::regclass)
select is((select string_agg(child_name || ' [' || lo || ', ' || hi || ')', '; ') from mine where child_oid = :w_oid),
          't332_w_old [1200, 1300)',
  'E: the remedy records w by its oid, under its current name, over its own bounds');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.t332'::regclass and inhrelid = :w_oid)
          and (select string_agg(id::text, ',' order by id) from public.t332_w_old) = '1234,1256,1278'
          and not exists (select 1 from pgpm.part where child_oid = to_regclass('public.t332_w')::oid),
  'E: and w is still attached with its rows 1234, 1256 and 1278 when the row commits; the squatter is recorded nowhere');
select dblink_disconnect('ea') as ea_gone \gset
select dblink_disconnect('eb') as eb_gone \gset

-- ============================ (F) the partition's schema swapped away and back while the lock waits ============================
-- READ COMMITTED. A schema rename takes no lock on any relation in it. Session fb holds v and swaps its schema
-- s332 with tmp332, which holds a partitioned table of the same name (S) with one partition (S_c), held by fc.
-- Once fb commits, LOCK TABLE resolves s332.t332_v to S, locks it and waits for S_c; fb swaps the schemas back,
-- so the name denotes v again; fc lets go. The call holds S and S_c and nothing on v: a check of the name passes
-- here, the lock manager's witness does not, so it must refuse rather than record v with no lock on it.
create schema s332;
create table s332.t332_v partition of public.t332 for values from (1300) to (1400);
insert into public.t332 values (1301, 'v'), (1350, 'v');
create schema tmp332;
create table tmp332.t332_v (id bigint) partition by range (id);
create table tmp332.t332_v_c partition of tmp332.t332_v for values from (0) to (10);
select 's332.t332_v'::regclass::oid as v_oid, 'tmp332.t332_v'::regclass::oid as sv_oid,
       'tmp332.t332_v_c'::regclass::oid as sc_oid \gset
select dblink_connect('fa', 'dbname=' || current_database()) as fa \gset
select dblink_connect('fb', 'dbname=' || current_database()) as fb \gset
select dblink_connect('fc', 'dbname=' || current_database()) as fc \gset
select pid as fa_pid from dblink('fa', 'select pg_backend_pid()') as t(pid int) \gset
select dblink_exec('fc', 'begin') as fc_begin \gset
select dblink_exec('fc', 'lock table tmp332.t332_v_c in access exclusive mode') as fc_lock \gset
select dblink_exec('fb', 'begin') as fb_begin \gset
select dblink_exec('fb', 'lock table s332.t332_v in access exclusive mode') as fb_lock \gset
select dblink_exec('fb', 'alter schema s332 rename to s332_old') as fb_away \gset
select dblink_exec('fb', 'alter schema tmp332 rename to s332') as fb_in \gset
select dblink_exec('fa', 'begin isolation level read committed') as fa_begin \gset
select dblink_send_query('fa', format('select pgpm.adopt_partition(%L, %s::oid::regclass)', 'public.t332', :v_oid)) as fa_sent \gset
select ok(pg_temp.t332_waits(:fa_pid, :v_oid),
  'LIVENESS: F: adopt_partition passed its first check and waits behind the swap for v''s lock');
select dblink_exec('fb', 'commit') as fb_commit \gset
select ok(pg_temp.t332_waits(:fa_pid, :sc_oid)
          and exists (select 1 from pg_locks where pid = :fa_pid and relation = :sv_oid and granted)
          and not exists (select 1 from pg_locks where pid = :fa_pid and relation = :v_oid),
  'LIVENESS: F: the lock landed on S, which the name denotes now, and waits for S''s partition, with none on v');
select dblink_exec('fb', 'begin') as fb_begin2 \gset
select dblink_exec('fb', 'alter schema s332 rename to tmp332') as fb_back1 \gset
select dblink_exec('fb', 'alter schema s332_old rename to s332') as fb_back2 \gset
select dblink_exec('fb', 'commit') as fb_commit2 \gset
select ok(to_regclass('s332.t332_v') = :v_oid::regclass,
  'LIVENESS: F: the schemas are swapped back, so the name the call locked by denotes v again');
select dblink_exec('fc', 'commit') as fc_commit \gset
select count(*) as fa_rows from dblink_get_result('fa', false) as t(x text) \gset
select ok(dblink_error_message('fa') like '%cannot adopt s332.t332_v (oid ' || :v_oid || '): this call holds no lock on it%Re-run adopt_partition naming the partition as it is now, s332.t332_v%',
  'F: the call holds no lock on v, so adopt_partition refuses, though the name denotes v again');
select count(*) as fa_drained from dblink_get_result('fa', false) as t(x text) \gset
-- COMMIT, not ROLLBACK, as in E
select dblink_exec('fa', 'commit') as fa_commit \gset
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :v_oid), null,
  'F: nothing is recorded for v when the call''s transaction commits');
-- the remedy, as typed
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 's332.t332_v'),
  'F: the call again, naming the partition as it is now, adopts it');
with mine as materialized (select * from pgpm.part where parent_table = 'public.t332'::regclass)
select is((select string_agg(child_name || ' [' || lo || ', ' || hi || ')', '; ') from mine where child_oid = :v_oid)
            || ' ' || (select string_agg(id::text, ',' order by id) from s332.t332_v),
          't332_v [1300, 1400) 1301,1350',
  'F: v is recorded by its oid over its own bounds, attached with its rows 1301 and 1350');
select dblink_disconnect('fa') as fa_gone \gset
select dblink_disconnect('fb') as fb_gone \gset
select dblink_disconnect('fc') as fc_gone \gset

-- ============================ (G) a rename with nothing put in its place ============================
-- READ COMMITTED. The partition is renamed while the call waits for its lock, and nothing takes the old name:
-- LOCK TABLE then finds no relation of that name (42P01, naming the OLD name as missing). That is pgpm's
-- refusal, naming the partition as it is now, not the raw error.
create table public.t332_u partition of public.t332 for values from (1400) to (1500);
insert into public.t332 values (1444, 'u');
select 'public.t332_u'::regclass::oid as u_oid \gset
select dblink_connect('ga', 'dbname=' || current_database()) as ga \gset
select dblink_connect('gb', 'dbname=' || current_database()) as gb \gset
select pid as ga_pid from dblink('ga', 'select pg_backend_pid()') as t(pid int) \gset
select dblink_exec('gb', 'begin') as gb_begin \gset
select dblink_exec('gb', 'alter table public.t332_u rename to t332_u_old') as gb_rename \gset
select dblink_exec('ga', 'begin isolation level read committed') as ga_begin \gset
select dblink_send_query('ga', format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 'public.t332_u')) as ga_sent \gset
select ok(pg_temp.t332_waits(:ga_pid, :u_oid),
  'LIVENESS: G: adopt_partition passed its first check and waits behind the rename for u''s lock');
select dblink_exec('gb', 'commit') as gb_commit \gset
select count(*) as ga_rows from dblink_get_result('ga', false) as t(x text) \gset
select ok(dblink_error_message('ga') like '%pg_partition_magician: cannot adopt t332_u_old (oid ' || :u_oid || '): this call holds no lock on it, because the name public.t332_u it locked by stopped denoting it%Re-run adopt_partition naming the partition as it is now, t332_u_old%',
  'G: the renamed partition is refused with pgpm''s message naming it as it is now, not a missing old name');
select count(*) as ga_drained from dblink_get_result('ga', false) as t(x text) \gset
select dblink_exec('ga', 'commit') as ga_commit \gset
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :u_oid), null,
  'G: nothing is recorded for u');
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 'public.t332_u_old'),
  'G: the call again, naming the partition as it is now, adopts it');
select is((select child_name from pgpm.part where child_oid = :u_oid), 't332_u_old',
  'G: u is recorded by its oid under its current name');
select dblink_disconnect('ga') as ga_gone \gset
select dblink_disconnect('gb') as gb_gone \gset

-- ============================ (H) the partition dropped while the call waits ============================
-- READ COMMITTED. Session hb drops d and holds the drop uncommitted; the call (session ha) passes its first check
-- and waits behind it for d's lock; hb commits. LOCK TABLE finds no relation of the name, as in G, and the call
-- holds no lock on d's oid, as in E, F and G: but nothing was renamed and nothing took the name. The relation is
-- gone, so the refusal says that, and names no partition "as it is now" and no re-run (typed with the bare oid a
-- dropped regclass renders as, that re-run could only be refused).
create table public.t332_d partition of public.t332 for values from (1500) to (1600);
insert into public.t332 values (1511, 'd'), (1522, 'd');
select 'public.t332_d'::regclass::oid as d_oid \gset
select dblink_connect('ha', 'dbname=' || current_database()) as ha \gset
select dblink_connect('hb', 'dbname=' || current_database()) as hb \gset
select pid as ha_pid from dblink('ha', 'select pg_backend_pid()') as t(pid int) \gset
select dblink_exec('hb', 'begin') as hb_begin \gset
select dblink_exec('hb', 'drop table public.t332_d') as hb_drop \gset
select dblink_exec('ha', 'begin isolation level read committed') as ha_begin \gset
select dblink_send_query('ha', format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 'public.t332_d')) as ha_sent \gset
select ok(pg_temp.t332_waits(:ha_pid, :d_oid),
  'LIVENESS: H: adopt_partition passed its first check and waits behind the drop for d''s lock');
select dblink_exec('hb', 'commit') as hb_commit \gset
select count(*) as ha_rows from dblink_get_result('ha', false) as t(x text) \gset
select split_part(dblink_error_message('ha'), E'\n', 1) as h_msg \gset
select count(*) as ha_drained from dblink_get_result('ha', false) as t(x text) \gset
select dblink_exec('ha', 'commit') as ha_commit \gset
select ok(not exists (select 1 from pg_class where oid = :d_oid) and to_regclass('public.t332_d') is null
          and :d_oid::regclass::text = :'d_oid',
  'LIVENESS: H: the drop committed: d is gone, nothing took its name, and its oid renders as a bare number');
select is(:'h_msg',
  'ERROR:  pg_partition_magician: cannot adopt public.t332_d (oid ' || :'d_oid' || '): that relation no longer exists (dropped while this call waited for its lock), so there is nothing to adopt. Any relation named public.t332_d now is a different one',
  'H: the dropped partition is refused as dropped, by the name it had and its oid');
select ok(:'h_msg' like 'ERROR:  pg_partition_magician: cannot adopt %' and :'h_msg' !~* 're-run'
          and :'h_msg' not like '%as it is now%' and :'h_msg' not like '%renamed%'
          and :'h_msg' not like '%cannot adopt ' || :'d_oid' || ' %',
  'H: the refusal diagnoses no rename, names no partition "as it is now" and no re-run, and does not call the relation by its bare oid');
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :d_oid or child_name = 't332_d'), null,
  'H: nothing is recorded for d when the call''s transaction commits');
-- found before the partition's lock is asked for: the same refusal, with no name to give
select throws_like(format('select pgpm.adopt_partition(%L, %s::oid::regclass)', 'public.t332', :d_oid),
  'pg_partition_magician: cannot adopt the relation with oid ' || :'d_oid' || ': no such relation exists (if it was a partition of t332, it was dropped before this call read it or while it waited), so there is nothing to adopt',
  'H: a later call given the dropped oid is refused as dropped too, not as a relation that is "not a partition"');
select is((select string_agg(id::text, ',' order by id) from public.t332 where id >= 1400), '1444',
  'LIVENESS: H: d''s rows 1511 and 1522 went with it; u''s 1444 is the last row the parent holds');
select dblink_disconnect('ha') as ha_gone \gset
select dblink_disconnect('hb') as hb_gone \gset

-- ============================ (I) dropped, and a new partition created under its name ============================
-- READ COMMITTED. Session ib drops c and creates a new partition under the same name over the same range, both
-- uncommitted; the call (session ia, given the OLD c) waits behind the drop; ib commits. LOCK TABLE resolves the
-- name to the new relation, so the call holds no lock on the oid it was given, as in E: but that oid is gone,
-- so this is the dropped refusal again, not the squatter one. The relation of the name now is a
-- different one, as the refusal says: a call naming it resolves to the new oid and adopts that.
create table public.t332_c partition of public.t332 for values from (1600) to (1700);
insert into public.t332 values (1601, 'c'), (1602, 'c');
select 'public.t332_c'::regclass::oid as c_oid \gset
select dblink_connect('ia', 'dbname=' || current_database()) as ia \gset
select dblink_connect('ib', 'dbname=' || current_database()) as ib \gset
select pid as ia_pid from dblink('ia', 'select pg_backend_pid()') as t(pid int) \gset
select dblink_exec('ib', 'begin') as ib_begin \gset
select dblink_exec('ib', 'drop table public.t332_c') as ib_drop \gset
select dblink_exec('ib', 'create table public.t332_c partition of public.t332 for values from (1600) to (1700)') as ib_new \gset
select dblink_exec('ib', $$insert into public.t332 values (1666, 'c2')$$) as ib_row \gset
select dblink_exec('ia', 'begin isolation level read committed') as ia_begin \gset
select dblink_send_query('ia', format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 'public.t332_c')) as ia_sent \gset
select ok(pg_temp.t332_waits(:ia_pid, :c_oid),
  'LIVENESS: I: adopt_partition passed its first check and waits behind the drop for the old c''s lock');
select dblink_exec('ib', 'commit') as ib_commit \gset
select count(*) as ia_rows from dblink_get_result('ia', false) as t(x text) \gset
select split_part(dblink_error_message('ia'), E'\n', 1) as i_msg \gset
select count(*) as ia_drained from dblink_get_result('ia', false) as t(x text) \gset
select 'public.t332_c'::regclass::oid as c2_oid \gset
select ok(not exists (select 1 from pg_class where oid = :c_oid) and :c2_oid <> :c_oid
          and exists (select 1 from pg_inherits where inhparent = 'public.t332'::regclass and inhrelid = :c2_oid),
  'LIVENESS: I: the old c is gone, and a new partition of the table holds its name under another oid');
select dblink_exec('ia', 'commit') as ia_commit \gset
select is(:'i_msg',
  'ERROR:  pg_partition_magician: cannot adopt public.t332_c (oid ' || :'c_oid' || '): that relation no longer exists (dropped while this call waited for its lock), so there is nothing to adopt. Any relation named public.t332_c now is a different one',
  'I: the dropped partition is refused as dropped though its name denotes a relation, and the refusal says that one is another');
select is((select string_agg(child_name, ',') from pgpm.part where child_oid in (:c_oid, :c2_oid) or child_name = 't332_c'), null,
  'I: nothing is recorded for the old c or the new one when the call''s transaction commits');
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 'public.t332_c'),
  'I: a call naming the relation of that name now adopts it');
with mine as materialized (select * from pgpm.part where parent_table = 'public.t332'::regclass)
select is((select string_agg(child_name || ' [' || lo || ', ' || hi || ') ' || case child_oid when :c2_oid then 'the new oid' when :c_oid then 'the dropped oid' else child_oid::text end, '; ')
             from mine where child_name = 't332_c')
            || ' ' || (select string_agg(id::text, ',' order by id) from public.t332_c),
          't332_c [1600, 1700) the new oid 1666',
  'I: it is recorded under the new oid over its own bounds, with its row 1666 and none of the dropped one''s');
select dblink_disconnect('ia') as ia_gone \gset
select dblink_disconnect('ib') as ib_gone \gset

select dblink_disconnect('o332') as o332_gone \gset
select * from finish();
