-- Issue #633 (pass 11, F1-01): a preserved incoming key whose referencing table is PARTITIONED -- a
-- self-referential key of the managed table itself, or a key declared on another partitioned table -- was
-- re-added by restore_incoming_fks (maintain's tick, and every regrain swap) and by untransmute in ONE
-- validating step: ADD FOREIGN KEY scanned the whole referencing table while it held SHARE ROW EXCLUSIVE on
-- the managed table (ACCESS EXCLUSIVE in untransmute and in the swap), so every writer waited for an
-- O(rows) scan, against the reference's "re-adds each FK NOT VALID ... the blocking part is instant".
--
-- What PostgreSQL allows decides what pgpm can do, so the contract is per version:
--   * PostgreSQL 18 accepts NOT VALID on a partitioned referencing table. Both sites re-add the key NOT
--     VALID there, exactly as for a plain referencer: it enforces every new write from the re-add on, the
--     rows already there are left for validate_incoming_fks (maintain's later tick, in its own
--     transaction, under locks that block no writes), and an orphan written while the key was suspended
--     no longer keeps the key dropped.
--   * PostgreSQL 15 to 17 refuse it ("cannot add NOT VALID foreign key on partitioned table"), and the only
--     scan-free route there (a NOT VALID key per partition, validated, then adopted by the parent's ADD)
--     costs one pg_constraint row and trigger pair per (referencing partition x referenced partition), so
--     the key is still re-added validated in one step, and the reference says so. This file pins that too,
--     so the documented exception and the behaviour cannot drift apart.
--
-- No row-count assertion here: "nothing was validated in the re-add" is read off the catalog (convalidated
-- false right after the call, which a validating ADD can never leave), and every such negative is paired
-- with a witness that the key is live and enforcing. The fixture is asymmetric: three keys against one
-- managed table (a self-referential one, one on a partitioned referencer that carries an orphan written
-- while it was suspended, one on a plain referencer), so "which keys came back, and which validated" has a
-- different answer for each and cannot be satisfied by counting.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(14);

select current_setting('server_version_num')::int >= 180000 as pg18 \gset

-- ======================================================================================================
-- fixture: t322 references itself, and is referenced by a partitioned table and by a plain one
-- ======================================================================================================
create table public.t322 (id bigint primary key, parent_id bigint constraint t322_parent_fk references public.t322 (id),
                          body text);
insert into public.t322 select g, nullif(g - 1, 0), 'r' || g from generate_series(1, 15) g;
create table public.rp322 (id int, t_id bigint constraint rp322_t_fk references public.t322 (id), k int not null,
                           primary key (id, k)) partition by range (k);
create table public.rp322_a partition of public.rp322 for values from (0) to (10);
create table public.rp322_b partition of public.rp322 for values from (10) to (20);
insert into public.rp322 values (1, 3, 1), (2, 12, 15);
create table public.pl322 (id int primary key, t_id bigint constraint pl322_t_fk references public.t322 (id));
insert into public.pl322 values (1, 7);

call pgpm.transmute('public.t322', 'id', 10::bigint, p_incoming_fks => 'preserve', p_obtain => 2);

select is(
  (select array_agg(referencing_table::text || ':' || constraint_name || ':' || (restored_at is null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322:pl322_t_fk:true', 'rp322:rp322_t_fk:true', 't322:t322_parent_fk:true'],
  'LIVENESS: the conversion dropped and recorded all three keys, the self-referential one against the new parent');
select is((select array_agg(relkind::text order by relname) from pg_class
            where oid in ('public.t322'::regclass, 'public.rp322'::regclass)),
  array['p', 'p'], 'LIVENESS: two of the three referencing tables (t322 itself, rp322) are partitioned');

insert into public.rp322 values (3, 999, 5);   -- an orphan, written into rp322_a while its key is down

-- ======================================================================================================
-- restore_incoming_fks: the maintain path, and regrain's swap
-- ======================================================================================================
\if :pg18
select is(pgpm.restore_incoming_fks('public.t322'), 3,
  'PG 18: restore_incoming_fks re-adds all three keys, the orphaned partitioned referencer''s too');
select is(
  (select array_agg(conrelid::regclass::text || ':' || conname || ':' || convalidated::text order by conname)
     from pg_constraint where contype = 'f' and conparentid = 0 and confrelid = 'public.t322'::regclass),
  array['pl322:pl322_t_fk:false', 'rp322:rp322_t_fk:false', 't322:t322_parent_fk:false'],
  'PG 18: each is back at its table NOT VALID, so the re-add validated nothing: the partitioned two like the plain one');
select is(
  (select array_agg(constraint_name || ':' || (restored_at is not null)::text || ':' || (validated_at is null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322_t_fk:true:true', 'rp322_t_fk:true:true', 't322_parent_fk:true:true'],
  'PG 18: and each is recorded restored and not yet validated');
\else
select is(pgpm.restore_incoming_fks('public.t322'), 2,
  'PG 15-17: restore_incoming_fks re-adds two keys; the orphaned partitioned referencer''s fails its one-step validation');
select is(
  (select array_agg(conrelid::regclass::text || ':' || conname || ':' || convalidated::text order by conname)
     from pg_constraint where contype = 'f' and conparentid = 0 and confrelid = 'public.t322'::regclass),
  array['pl322:pl322_t_fk:false', 't322:t322_parent_fk:true'],
  'PG 15-17: the plain referencer''s is back NOT VALID; the self-referential one validated in one step (PostgreSQL refuses NOT VALID on a partitioned table)');
select is(
  (select array_agg(constraint_name || ':' || (restored_at is not null)::text || ':' || (validated_at is null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322_t_fk:true:true', 'rp322_t_fk:false:true', 't322_parent_fk:true:false'],
  'PG 15-17: and the records say so: rp322_t_fk still suspended, t322_parent_fk already validated');
\endif

-- Live and enforcing, whatever the version: a forward-partition row of t322 whose parent is missing, and a
-- row of rp322_b whose t322 row is missing, are refused; t322's real forward row is accepted. On 15-17 the
-- rp322 key stayed suspended, so the second is the one that differs.
select lives_ok($$ insert into public.t322 values (25, 1, 'forward') $$,
  'LIVENESS: a t322 row routed to a forward partition with a real parent is accepted');
select throws_ok($$ insert into public.t322 values (26, 999, 'orphan') $$, '23503', NULL,
  'the self-referential key enforces new writes on every partition of the managed table');
\if :pg18
select throws_ok($$ insert into public.rp322 values (4, 998, 16) $$, '23503', NULL,
  'PG 18: the partitioned referencer''s key enforces new writes too, the orphan before it notwithstanding');
\else
select lives_ok($$ insert into public.rp322 values (4, 998, 16) $$,
  'PG 15-17: the partitioned referencer''s key is still suspended, so an orphan still goes in');
\endif

-- ======================================================================================================
-- validate_incoming_fks: maintain's later tick, in its own transaction
-- ======================================================================================================
\if :pg18
select is(pgpm.validate_incoming_fks('public.t322'), 2,
  'PG 18: validate_incoming_fks validates the two keys without an orphan');
select is(
  (select array_agg(conrelid::regclass::text || ':' || convalidated::text order by conrelid::regclass::text)
     from pg_constraint where contype = 'f' and conname = 't322_parent_fk'),
  (select array_agg(r || ':true' order by r)
     from (select i.inhrelid::regclass::text from pg_inherits i where i.inhparent = 'public.t322'::regclass
           union all select 't322') as k(r)),
  'PG 18: the self-referential key is validated on t322 and on every one of its partitions');
select is(
  (select array_agg(constraint_name || ':' || (validated_at is not null)::text || ':' || (validate_retry_after is not null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322_t_fk:true:false', 'rp322_t_fk:false:true', 't322_parent_fk:true:false'],
  'PG 18: the orphaned rp322_t_fk stays NOT VALID and backs off, the other two are validated');
\else
select is(pgpm.validate_incoming_fks('public.t322'), 1,
  'PG 15-17: validate_incoming_fks validates the plain referencer''s key, the one left NOT VALID');
select is(
  (select array_agg(conrelid::regclass::text || ':' || convalidated::text order by conrelid::regclass::text)
     from pg_constraint where contype = 'f' and conname = 't322_parent_fk'),
  (select array_agg(r || ':true' order by r)
     from (select i.inhrelid::regclass::text from pg_inherits i where i.inhparent = 'public.t322'::regclass
           union all select 't322') as k(r)),
  'PG 15-17: the self-referential key is validated on t322 and on every one of its partitions');
select is(
  (select array_agg(constraint_name || ':' || (validated_at is not null)::text || ':' || (validate_retry_after is not null)::text
                    order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.t322'::regclass),
  array['pl322_t_fk:true:false', 'rp322_t_fk:false:false', 't322_parent_fk:true:false'],
  'PG 15-17: rp322_t_fk was never re-added, so there was nothing to validate or back off');
\endif

-- ======================================================================================================
-- untransmute: the other site, re-adding a partitioned referencer's key against the restored table
-- ======================================================================================================
create table public.u322 (id bigint primary key, body text);
insert into public.u322 select g, 'u' || g from generate_series(1, 9) g;
create table public.rpu322 (id int, u_id bigint constraint rpu322_u_fk references public.u322 (id), k int not null,
                            primary key (id, k)) partition by range (k);
create table public.rpu322_a partition of public.rpu322 for values from (0) to (10);
create table public.rpu322_b partition of public.rpu322 for values from (10) to (20);
insert into public.rpu322 values (1, 2, 1), (2, 8, 15);
call pgpm.transmute('public.u322', 'id', 10::bigint, p_incoming_fks => 'preserve', p_obtain => 2);
select pgpm.untransmute('public.u322');

select is(
  (select relkind::text || ':' || coalesce((select array_agg(constraint_name)::text from pgpm.dropped_fk
                                             where referencing_table = 'public.rpu322'::regclass), 'none')
     from pg_class where oid = 'public.u322'::regclass),
  'r:none', 'LIVENESS: u322 is a plain table again and pgpm keeps no record of rpu322_u_fk');
\if :pg18
select is(
  (select array_agg(conrelid::regclass::text || ':' || convalidated::text order by conrelid::regclass::text)
     from pg_constraint where contype = 'f' and conname = 'rpu322_u_fk' and confrelid = 'public.u322'::regclass),
  array['rpu322:false', 'rpu322_a:false', 'rpu322_b:false'],
  'PG 18: untransmute re-added the partitioned referencer''s key NOT VALID, on rpu322 and both its partitions');
\else
select is(
  (select array_agg(conrelid::regclass::text || ':' || convalidated::text order by conrelid::regclass::text)
     from pg_constraint where contype = 'f' and conname = 'rpu322_u_fk' and confrelid = 'public.u322'::regclass),
  array['rpu322:true', 'rpu322_a:true', 'rpu322_b:true'],
  'PG 15-17: untransmute re-added the partitioned referencer''s key validated in one step, on rpu322 and both its partitions');
\endif
select throws_ok($$ insert into public.rpu322 values (3, 999, 16) $$, '23503', NULL,
  'and it enforces: an rpu322 row for a missing u322 id is refused');

select * from finish();
