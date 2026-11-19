-- incoming_fk_orphans counts orphans under a collation mismatch between the two sides of the key (issue #958).
--
-- THE GAP. incoming_fk_orphans joined each referencing column to its referenced column as `r.col = p.col`, with no
-- COLLATE. PostgreSQL accepts a foreign key whose two text columns carry different (deterministic) collations, and
-- preserve re-adds it as written, but in the orphan count the two implicit collations conflict and the query raised
-- 'could not determine which collation to use for string hashing' instead of counting: the runbook sends an operator
-- to this function to find what blocks validate_incoming_fks(), and it refused to answer.
--
-- THE CONTRACT. The orphans are counted under the referenced column's collation, the one VALIDATE itself compares
-- under (PostgreSQL's RI check adds the PK side's COLLATE when the two differ), and they are the rows VALIDATE refuses.
-- Fixture: parent key (code text COLLATE "C", id), managed on id; the child references (code, id) with code COLLATE
-- "en_US". One valid row, then TWO orphans written while preserve has the key suspended (asymmetric: 1 valid, 2
-- orphans), so a count that comes from somewhere else cannot match by accident.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

create table public.f958_parent (code text collate "C" not null, id bigint not null, primary key (code, id));
insert into public.f958_parent select 'k', g from generate_series(1, 50) g;
create table public.f958_child (rid int primary key, code text collate "en_US", pid bigint,
  constraint f958_child_fk foreign key (code, pid) references public.f958_parent (code, id));
insert into public.f958_child values (1, 'k', 10);

call pgpm.transmute('public.f958_parent', 'id', 1000::bigint, p_incoming_fks => 'preserve');

insert into public.f958_child values (2, 'k', 999), (3, 'zz', 20);   -- two orphans written while suspended
select is(pgpm.restore_incoming_fks('public.f958_parent'), 1, 'LIVENESS: restore_incoming_fks re-added the key');
select is(pgpm.validate_incoming_fks('public.f958_parent'), 0, 'LIVENESS: validate_incoming_fks could not validate it');
select is((select array_agg(constraint_name::text) from pgpm.dropped_fk
            where parent_table = 'public.f958_parent'::regclass and restored_at is not null and validated_at is null),
  array['f958_child_fk'], 'LIVENESS: the key is re-added NOT VALID and unvalidated');
select isnt((select fa.attcollation from pg_attribute fa where fa.attrelid = 'public.f958_child'::regclass and fa.attname = 'code'),
            (select pa.attcollation from pg_attribute pa where pa.attrelid = 'public.f958_parent'::regclass and pa.attname = 'code'),
  'LIVENESS: the referencing and referenced columns carry different collations');

select lives_ok($$ select * from pgpm.incoming_fk_orphans('public.f958_parent') $$,
  'incoming_fk_orphans answers under a collation mismatch instead of raising');
select is((select orphan_rows from pgpm.incoming_fk_orphans('public.f958_parent') where constraint_name = 'f958_child_fk'),
  2::bigint, 'it counts the two orphans (rids 2 and 3)');

-- Identity, not cardinality: clearing exactly those two rows is what lets VALIDATE through.
delete from public.f958_child where rid in (2, 3);
select is(pgpm.validate_incoming_fks('public.f958_parent'), 1,
  'and they are the rows VALIDATE refused: with rids 2 and 3 gone the key validates');
select * from finish();
