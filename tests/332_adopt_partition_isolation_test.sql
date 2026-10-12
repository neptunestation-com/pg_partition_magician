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
--
-- adopt_partition is a function, not a committing procedure, so its refusals are pinned by message.
-- ASYMMETRIC FIXTURES. Three hand partitions: x [900, 1000) holds 950 and is renamed, y [1000, 1100) holds
-- 1010 and 1020 and is detached, z [1100, 1200) holds 1111, 1122 and 1133 and is left alone. Two end up
-- recorded and one does not, and every check names the relation by oid and name, never a count alone.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(18);

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

select dblink_disconnect('o332') as o332_gone \gset
select * from finish();
