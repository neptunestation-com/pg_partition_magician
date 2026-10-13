-- P1-01: adopt_partition's READ COMMITTED refusal (install.sql ~14021) never fires: its condition is a
-- constant, so a REPEATABLE READ caller is admitted and every judgement after the SHARE UPDATE EXCLUSIVE
-- lock (attached and not pending, the name, the bounds) is made through the transaction's first snapshot.
-- A DETACH another session committed before the call is read as still attached and the standalone table is
-- recorded in pgpm.part as a partition of the parent; a RENAME committed before the call is recorded under
-- the old name, so the row's child_name no longer resolves to the child_oid it records. The header, the
-- reference ("a transaction stricter than READ COMMITTED ... before it takes any lock") and the CHANGELOG all
-- say the call refuses up front.
--
-- Fixtures are asymmetric: y [1000,1100) holds 1010 and 1020 and is DETACHED; x [900,1000) holds 950 and is
-- RENAMED; z [1100,1200) holds 1111, 1122, 1133 and is left alone as a control that READ COMMITTED still
-- adopts. Every check names the relation by oid, never a count alone.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(10);

create table public.p1a (id bigint primary key, payload text);
insert into public.p1a values (150, 'a');
call pgpm.transmute('public.p1a', 'id', 100::bigint, p_obtain => 1, p_paused => false);
-- attached partitions pgpm.part has no row for: what adopt_partition exists to record
create table public.p1a_x partition of public.p1a for values from (900) to (1000);
create table public.p1a_y partition of public.p1a for values from (1000) to (1100);
create table public.p1a_z partition of public.p1a for values from (1100) to (1200);
insert into public.p1a values (950, 'x'), (1010, 'y'), (1020, 'y'), (1111, 'z'), (1122, 'z'), (1133, 'z');
select 'public.p1a_x'::regclass::oid as x_oid, 'public.p1a_y'::regclass::oid as y_oid,
       'public.p1a_z'::regclass::oid as z_oid \gset

select is((select string_agg(c.relname, ',' order by c.relname) from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.p1a'::regclass and c.oid in (:x_oid, :y_oid, :z_oid)),
          'p1a_x,p1a_y,p1a_z', 'LIVENESS: x, y and z are attached');
select is((select string_agg(child_name, ',') from pgpm.part where child_oid in (:x_oid, :y_oid, :z_oid)), null,
          'LIVENESS: and pgpm.part records none of them');
select dblink_connect('o1', 'dbname=' || current_database()) as o1 \gset

-- (A) REPEATABLE READ, snapshot older than a DETACH another session committed before the call
begin isolation level repeatable read;
select count(*) as a_snap from pgpm.config \gset
select dblink_exec('o1', 'alter table public.p1a detach partition public.p1a_y') as a_detached \gset
select ok(exists (select 1 from pg_inherits where inhrelid = :y_oid)
          and (select x from dblink('o1', format('select count(*)::int from pg_inherits where inhrelid = %s', :y_oid)) as t(x int)) = 0,
  'LIVENESS: A: the detach committed, and this transaction''s snapshot still shows y attached');
-- the call: on a tree that refuses, the exception is swallowed here and the row is never written; on this
-- tree it is admitted and the row is. The defect is judged on pgpm.part below, not on the exception.
do $$ begin perform pgpm.adopt_partition('public.p1a', 'public.p1a_y'); exception when others then null; end $$;
commit;
select is((select string_agg(child_name || ' attached=' || attached, ',') from pgpm.part where child_oid = :y_oid), null,
  'A: pgpm.part records no row for y, which was not a partition of p1a when adopt_partition was called');

-- (B) REPEATABLE READ, snapshot older than a RENAME another session committed; x is still attached
begin isolation level repeatable read;
select count(*) as b_snap from pgpm.config \gset
select dblink_exec('o1', 'alter table public.p1a_x rename to p1a_x_renamed') as b_renamed \gset
select ok((select relname from pg_class where oid = :x_oid) = 'p1a_x'
          and (select x from dblink('o1', format('select relname::text from pg_class where oid = %s', :x_oid)) as t(x text)) = 'p1a_x_renamed',
  'LIVENESS: B: the rename committed, and this transaction''s snapshot still reads x''s old name');
select format('do $x$ begin perform pgpm.adopt_partition(''public.p1a'', %s::regclass); exception when others then null; end $x$', :x_oid) as b_call \gset
:b_call ;
commit;
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :x_oid), null,
  'B: pgpm.part records no row for x under its old name (a REPEATABLE READ caller is refused before any lock)');

-- the two admitted calls, if they happened, were logged as adoptions
select is((select string_agg(lo || '..' || hi, ',' order by id) from pgpm.log
            where parent_table = 'public.p1a'::regclass and action = 'adopt_partition'), null,
  'A, B: no adoption was logged for a REPEATABLE READ caller');

-- control: READ COMMITTED on the same state adopts the untouched partition and refuses the detached one
begin isolation level read committed;
select lives_ok($$ select pgpm.adopt_partition('public.p1a', 'public.p1a_z') $$,
  'LIVENESS: in READ COMMITTED the untouched partition z is adopted');
select throws_like($$ select pgpm.adopt_partition('public.p1a', 'public.p1a_y') $$,
  'pg_partition_magician: p1a_y is not a partition of p1a:%',
  'LIVENESS: in READ COMMITTED the detached table y is refused as not a partition');
commit;
select is((select string_agg(child_name || ' [' || lo || ', ' || hi || ')', '; ' order by lo::bigint)
             from pgpm.part where parent_table = 'public.p1a'::regclass and child_oid in (:x_oid, :y_oid, :z_oid)),
          'p1a_z [1100, 1200)',
  'after the READ COMMITTED control, pgpm.part holds z alone of the three (x and y were refused, not recorded)');

select dblink_disconnect('o1') as o1_gone \gset
select * from finish();
