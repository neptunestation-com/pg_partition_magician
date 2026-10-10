-- uninstall.sql removes the manager and neither loses a key nor leaves a copy behind (issue #589).
--
-- Two things pgpm holds only in its own schema went with `drop schema pgpm cascade`:
--
--   (A) an incoming foreign key transmute(..., p_incoming_fks => 'preserve') dropped and pgpm had not
--       restored yet. transmute leaves a table paused by default and maintain does nothing for a paused
--       table, so the key stays dropped until the operator unpauses; pgpm.dropped_fk is the only record of
--       it, and an uninstall in that window erased the record and the key was gone for good, silently.
--       Now uninstall restores every pending key through restore_incoming_fks (the maintain path) and
--       REFUSES, dropping nothing, while any key it could not restore is still recorded; its message
--       carries the DDL and the reason, since the whole script rolls back and takes pgpm.log with it.
--
--   (B) an in-flight regrain's not-yet-attached fine copies. uninstall tore down the change capture but
--       left the copies as standalone tables in the operator's schema, with pgpm.part (the only record
--       that they were pgpm's staging copies) gone. Now uninstall abandons the regrain through
--       regrain_cancel first, as untransmute does: the source still holds every row, so only the copy
--       work is lost.
--
-- The fixture is asymmetric on purpose: two keys, one restorable (a plain referencer) and one not (the
-- table's own self-referencing key, with an orphan written while RI was off: a partitioned referencer
-- can only get its key back validating, which the orphan fails), so "the uninstall restored what it could and refused on the rest" cannot be satisfied by
-- restoring both or neither. Every negative ("no copy survives", "the schema is gone") is paired with a
-- witness that the thing was there to lose.
--
-- The uninstall script is read with \ir, relative to this file. bench/uninstall_residue.sh runs this file
-- against a mutant uninstall.sql by setting the psql variable `uninstall` to its path.
\if :{?uninstall}
\else
\set uninstall ../pgpm_core/uninstall.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(24);

create schema u589;

-- ======================================================================================================
-- fixture (A): two incoming keys on u589.orders, one restorable and one not
-- ======================================================================================================
create table u589.orders (id bigint primary key, v text,
                          parent_id bigint constraint orders_parent_fkey references u589.orders (id));
insert into u589.orders values (1, 'a', null), (2, 'b', 1), (3, 'c', 1);
create table u589.lines (id bigint primary key, order_id bigint references u589.orders (id));
insert into u589.lines values (10, 1), (11, 2);

select is(
  (select array_agg(conrelid::regclass::text || ':' || conname order by conname) from pg_constraint
    where confrelid = 'u589.orders'::regclass and contype = 'f' and conparentid = 0),
  array['u589.lines:lines_order_id_fkey', 'u589.orders:orders_parent_fkey'],
  'LIVENESS: (A) both incoming keys are live before the conversion');

call pgpm.transmute('u589.orders', 'id', 1000::bigint, p_incoming_fks => 'preserve');

select is(
  (select array_agg(constraint_name || ':' || (restored_at is null)::text order by constraint_name) from pgpm.dropped_fk
    where parent_table = 'u589.orders'::regclass),
  array['lines_order_id_fkey:true', 'orders_parent_fkey:true'],
  'LIVENESS: (A) the conversion dropped both keys and recorded each for restore');
select is(
  (select count(*)::int from pg_constraint where contype = 'f' and conrelid in ('u589.lines'::regclass, 'u589.orders'::regclass)),
  0, 'LIVENESS: (A) neither key is live on its referencing table');
select ok((select paused from pgpm.config where parent_table = 'u589.orders'::regclass),
  'LIVENESS: (A) the table is paused, so no tick will restore the keys');

insert into u589.orders values (4, 'd', 99);                                -- an orphan, written while RI is off
select is((select array_agg(id || ':' || coalesce(parent_id::text, '-') order by id) from u589.orders),
  array['1:-', '2:1', '3:1', '4:99'],
  'LIVENESS: (A) the orphan went in, so the self-referencing key cannot come back validating');

-- ======================================================================================================
-- fixture (B): a regrain in flight, with one standalone copy holding rows the source still holds
-- ======================================================================================================
create table u589.ev (id bigint primary key, v text);
insert into u589.ev select g, 'x' || g from generate_series(1, 45) g;
call pgpm.transmute('u589.ev', 'id', 10::bigint);
insert into u589.ev values (55, 'y'), (65, 'z');                            -- frontier past the monolith: frozen
select child_name as mon from pgpm.part where parent_table = 'u589.ev'::regclass and lo = '0' and attached \gset
select is(pgpm.regrain_step('u589.ev', :'mon', '10', 3), 'prepared', 'LIVENESS: (B) the regrain prepared');
select child_name as mon from pgpm.part where parent_table = 'u589.ev'::regclass and lo = '0' and attached \gset
select is(pgpm.regrain_step('u589.ev', :'mon', '10', 3), 'copied:3', 'LIVENESS: (B) one batch of three rows copied');
select is(
  (select array_agg(child_name || ':' || lo || '-' || hi) from pgpm.part where parent_table = 'u589.ev'::regclass and not attached),
  array['ev_p0000000000000000000:0-10'],
  'LIVENESS: (B) exactly one not-yet-attached fine copy is recorded');
select is((select array_agg(id order by id) from u589.ev_p0000000000000000000), array[1,2,3]::bigint[],
  'LIVENESS: (B) and it is a real standalone table holding copies of ids 1..3');

-- ======================================================================================================
-- first uninstall: refused, in one transaction, as the script says to run it
-- ======================================================================================================
\set ON_ERROR_STOP 0
begin;
\ir :uninstall
rollback;
\set ON_ERROR_STOP 1

select is(:'LAST_ERROR_SQLSTATE'::text, 'P0001', '(A) the uninstall refused with a raised exception');
select matches(:'LAST_ERROR_MESSAGE'::text,
  'refusing to uninstall.*alter table u589\.orders add constraint orders_parent_fkey FOREIGN KEY \(parent_id\) REFERENCES u589\.orders\(id\)',
  '(A) the refusal names the key it could not restore, with the DDL to re-add it by hand');
select matches(:'LAST_ERROR_MESSAGE'::text, 'orders_parent_fkey: .*violat',
  '(A) and says why it could not, since the rollback takes pgpm.log with it');
select doesnt_match(:'LAST_ERROR_MESSAGE'::text, 'lines_order_id_fkey',
  '(A) and does not name the key it did restore');
select isnt(to_regnamespace('pgpm'), null, '(A) the refusal dropped nothing: the pgpm schema is still there');
select is(
  (select array_agg(constraint_name || ':' || (restored_at is null)::text order by constraint_name) from pgpm.dropped_fk
    where parent_table = 'u589.orders'::regclass),
  array['lines_order_id_fkey:true', 'orders_parent_fkey:true'],
  '(A) and both records are as they were');

-- One of the ways out the refusal offers: clear the orphan and re-add the key by hand, then re-run. The
-- record stays unrestored (nothing told pgpm), so the second run must see the key live and not refuse.
update u589.orders set parent_id = null where id = 4;
alter table u589.orders add constraint orders_parent_fkey foreign key (parent_id) references u589.orders (id);

-- ======================================================================================================
-- second uninstall: goes through
-- ======================================================================================================
begin;
\ir :uninstall
commit;

select is(to_regnamespace('pgpm'), null, 'LIVENESS: the second uninstall went through and removed the pgpm schema');
select is(
  (select array_agg(conrelid::regclass::text || ':' || conname || ':' || confrelid::regclass::text || ':' || convalidated order by conname)
     from pg_constraint where contype = 'f' and conparentid = 0 and conrelid in ('u589.lines'::regclass, 'u589.orders'::regclass)),
  array['u589.lines:lines_order_id_fkey:u589.orders:false', 'u589.orders:orders_parent_fkey:u589.orders:true'],
  '(A) the pending key is live again on u589.lines, pointing at u589.orders (NOT VALID), beside the one re-added by hand');
select throws_ok($$ insert into u589.lines values (12, 42) $$, '23503', NULL,
  '(A) and it enforces: a line for a missing order is rejected');
select is((select array_agg(id || ':' || order_id order by id) from u589.lines), array['10:1', '11:2'],
  '(A) the referencing rows are exactly the two there were');
select is((select array_agg(id || v order by id) from u589.orders), array['1a', '2b', '3c', '4d'],
  'LIVENESS: (A) the orders are intact under the original name, row 4 (the orphan until cleared) among them');

select is(to_regclass('u589.ev_p0000000000000000000'), null,
  '(B) the regrain''s standalone copy did not survive the uninstall');
select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}') from pg_class c
    where c.relnamespace = 'u589'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition),
  array['ev', 'lines', 'orders'],
  '(B) no relation pgpm made survives in the schema beyond the tables and their partitions');
select is((select relkind::text from pg_class where oid = 'u589.ev'::regclass), 'p',
  'LIVENESS: (B) the regrained table is still partitioned');
select is((select array_agg(id order by id) from u589.ev),
  (select array_agg(g::bigint order by g) from generate_series(1, 45) g) || array[55, 65]::bigint[],
  'LIVENESS: (B) and holds exactly its 47 rows, 1..3 once each');

select * from finish();
