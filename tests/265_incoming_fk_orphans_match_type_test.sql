-- incoming_fk_orphans counts the rows that block VALIDATE under the key's own match type (issue #909).
--
-- THE BUG. incoming_fk_orphans built its predicate as "every FK column is non-null and no parent row
-- matches", which is MATCH SIMPLE's rule, and never read pg_constraint.confmatchtype. A MATCH FULL key
-- also refuses a row with SOME but not all of its key columns null, whatever the parent holds, so such a
-- row made validate_incoming_fks fail 23503 while incoming_fk_orphans reported 0 orphans for that key:
-- the tool docs/reference.md and runbook step 2 send the operator to, to find what to clear, named
-- nothing. preserve re-adds a MATCH FULL key as written, so the state is reachable on the documented path.
--
-- THE CONTRACT. For each re-added, unvalidated key, orphan_rows is the number of referencing rows
-- PostgreSQL's VALIDATE refuses under that key's match type:
--   MATCH FULL    a row with every key column null is exempt; a row with some null and some not is an
--                 orphan outright; a row with none null is an orphan when no parent row matches it.
--   MATCH SIMPLE  a row with ANY key column null is exempt; a row with none null is an orphan when no
--                 parent row matches it. (MATCH PARTIAL is not implemented by PostgreSQL.)
-- And it is the count of THOSE rows: clearing them one at a time takes the count down one at a time, a
-- key still refused by VALIDATE never reads 0, and the key validates once it does.
--
-- ASYMMETRIC FIXTURES. Two keys on one parent, written while preserve has them suspended:
--   t265_full   (MATCH FULL):   rid 3 (1, NULL) and rid 4 (NULL, 7) partly null, rid 5 (NULL, NULL) exempt,
--                               rid 6 (1, 999) no parent, rid 7 (1, 30) valid           -> 3 orphans
--   t265_simple (MATCH SIMPLE): rid 3 (1, NULL) and rid 4 (NULL, NULL) exempt, rid 6 (1, 888) and
--                               rid 8 (1, 777) no parent, rid 7 (1, 30) valid           -> 2 orphans
-- The SIMPLE-only predicate reads 1 for the FULL key; a predicate counting any null for every key reads 3
-- for the SIMPLE one; neither can land on the right pair.
--
-- bench/incoming_fk_orphans_match_type.sh runs this file against the mutants that put each wrong predicate
-- back (incoming_fk_orphans_simple_only, incoming_fk_orphans_full_everywhere), and each must FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(19);

create table t265_parent (tenant int not null, id bigint not null, primary key (tenant, id));
insert into t265_parent select 1, g from generate_series(1, 50) g;
create table t265_full (rid int primary key, tenant int, pid bigint,
  constraint t265_full_fk foreign key (tenant, pid) references t265_parent (tenant, id) match full);
create table t265_simple (rid int primary key, tenant int, pid bigint,
  constraint t265_simple_fk foreign key (tenant, pid) references t265_parent (tenant, id) match simple);
insert into t265_full values (1, 1, 10), (2, 1, 20);
insert into t265_simple values (1, 1, 10);

call pgpm.transmute('t265_parent', 'id', 1000::bigint, p_incoming_fks => 'preserve');

-- while the keys are suspended
insert into t265_full values (3, 1, null), (4, null, 7), (5, null, null), (6, 1, 999), (7, 1, 30);
insert into t265_simple values (3, 1, null), (4, null, null), (6, 1, 888), (8, 1, 777), (7, 1, 30);
select is(pgpm.restore_incoming_fks('t265_parent'), 2, 'LIVENESS: restore_incoming_fks re-added both keys');
select is(pgpm.validate_incoming_fks('t265_parent'), 0, 'LIVENESS: validate_incoming_fks validated neither');

create function t265_orphans(p_con name) returns bigint language sql as $$
  select orphan_rows from pgpm.incoming_fk_orphans('t265_parent') where constraint_name = p_con
$$;

-- LIVENESS: both keys are back NOT VALID and VALIDATE refused each of them
select is((select array_agg(constraint_name::text order by constraint_name) from pgpm.dropped_fk
            where parent_table = 't265_parent'::regclass and restored_at is not null and validated_at is null),
  array['t265_full_fk', 't265_simple_fk'],
  'LIVENESS: both keys were re-added NOT VALID and neither is validated');
select is((select convalidated from pg_constraint where conname = 't265_full_fk'), false,
  'LIVENESS: the MATCH FULL key is live and NOT VALID');
select is((select confmatchtype from pg_constraint where conname = 't265_full_fk'), 'f'::"char",
  'LIVENESS: preserve re-added the key as MATCH FULL, as it was written');
select is((select count(*)::int from pgpm.log where parent_table = 't265_parent'::regclass
            and action = 'fail_validate_incoming_fk' and split_part(method, ':', 1) = 't265_full_fk'), 1,
  'LIVENESS: validate_incoming_fks failed on the MATCH FULL key');

-- the counts, per key
select is(t265_orphans('t265_full_fk'), 3::bigint,
  'MATCH FULL: rids 3 and 4 (partly null) and 6 (no parent) are the orphans; rid 5 (all null) is exempt');
select is(t265_orphans('t265_simple_fk'), 2::bigint,
  'MATCH SIMPLE: rids 6 and 8 (no parent) are the orphans; rids 3 and 4 (a null column) are exempt');

-- identity, MATCH FULL: clear the no-parent row first. What is left is only the partly-null rows, the
-- state the bug read as 0, and VALIDATE still refuses it.
delete from t265_full where rid = 6;
select is(t265_orphans('t265_full_fk'), 2::bigint,
  'MATCH FULL: with rid 6 cleared, the two partly-null rows are still counted');
select throws_ok('alter table t265_full validate constraint t265_full_fk', '23503', NULL,
  'LIVENESS: PostgreSQL still refuses to validate the MATCH FULL key over the partly-null rows');
delete from t265_full where rid = 3;
select is(t265_orphans('t265_full_fk'), 1::bigint,
  'MATCH FULL: with rid 3 (1, NULL) cleared, one orphan is left');
delete from t265_full where rid = 4;
select is(t265_orphans('t265_full_fk'), 0::bigint,
  'MATCH FULL: with rid 4 (NULL, 7) cleared, none is left');

-- identity, MATCH SIMPLE: one no-parent row at a time, the null-column rows never cleared
delete from t265_simple where rid = 8;
select is(t265_orphans('t265_simple_fk'), 1::bigint,
  'MATCH SIMPLE: with rid 8 cleared, one orphan is left');
delete from t265_simple where rid = 6;
select is(t265_orphans('t265_simple_fk'), 0::bigint,
  'MATCH SIMPLE: with rid 6 cleared, none is left though rids 3 and 4 still hold a null');

-- and 0 means VALIDATE succeeds: both keys validate with their exempt rows still in place
select is(pgpm.validate_incoming_fks('t265_parent'), 2,
  'validate_incoming_fks validates both keys once incoming_fk_orphans reads 0 for each');
select is((select array_agg(constraint_name::text order by constraint_name) from pgpm.dropped_fk
            where parent_table = 't265_parent'::regclass and validated_at is not null),
  array['t265_full_fk', 't265_simple_fk'],
  'both keys are recorded validated');
select is((select array_agg(rid order by rid) from t265_full), array[1, 2, 5, 7],
  'the MATCH FULL table kept its all-null row (rid 5) and its valid rows');
select is((select array_agg(rid order by rid) from t265_simple), array[1, 3, 4, 7],
  'the MATCH SIMPLE table kept its null-column rows (rids 3 and 4) and its valid rows');
select is((select count(*)::int from pgpm.incoming_fk_orphans('t265_parent')), 0,
  'incoming_fk_orphans lists no key once both are validated');

select * from finish();
