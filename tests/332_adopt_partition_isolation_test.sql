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
--
-- adopt_partition is a function, not a committing procedure, so its refusals are pinned by message.
-- ASYMMETRIC FIXTURES. Three hand partitions: x [900, 1000) holds 950 and is renamed, y [1000, 1100) holds
-- 1010 and 1020 and is detached, z [1100, 1200) holds 1111, 1122 and 1133 and is left alone. Two end up
-- recorded and one does not, and every check names the relation by oid and name, never a count alone. E's w
-- [1200, 1300) holds 1234, 1256 and 1278, and its squatter none.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(25);

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
select ok(dblink_error_message('ea') like '%cannot adopt t332_w_old (oid ' || :w_oid || '): the name public.t332_w no longer denotes it%Re-run adopt_partition naming the partition as it is now, t332_w_old%',
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
select r as e_adopted from dblink('ea', format('select pgpm.adopt_partition(%L, %L)', 'public.t332', 'public.t332_w_old')) as t(r text) \gset
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

select dblink_disconnect('o332') as o332_gone \gset
select * from finish();
