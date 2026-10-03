-- A moved parent's every lifecycle stage acts on the relations pgpm RECORDED (issue #872, the conformance
-- suite of the recorded-identity lever).
--
-- ALTER TABLE <parent> SET SCHEMA is safe by contract: the managed table moves, its partitions, its regrain
-- copies and every table that references it stay where they were, and pgpm knows each by oid. The class this
-- suite closes is every site that instead resolved one of them as <the parent's CURRENT schema>.<name>, or by
-- a name recorded before the move: the fix makes each go through the recorded identity (the oid, with the
-- recorded schema only as the fallback when the oid is gone). One table is taken through SET SCHEMA before
-- EVERY stage, so a site left out is met by a stage, and each stage plants a NAMESAKE exactly where the old
-- resolution would land, so a wrong resolution acts on a relation the stage can see untouched, rather than
-- failing in some way that might also pass:
--
--   S1  after transmute, with a suspended incoming key: restore_incoming_fks re-adds it against the managed
--       parent (its recorded text names the conversion-time schema, where a namesake now sits)
--   S2  mid-regrain, a copy part-filled before the move: the run copies on into the RECORDED copy (a
--       namesake bears its name in the parent's new schema), makes its other copies beside the source, swaps
--       them in by oid, puts the incoming key back against the parent across the swap, and names the source
--       where it was in its archive_coverage_reset line
--   S3  before archive coverage and retain, the key suspended (a referenced partition is detached only
--       through pg_cron, which a test database lacks): each aged partition is archived and retired by oid
--       (namesakes of two of them sit in the parent's new schema)
--   S4  before untransmute (a second table, moved AND renamed, its old qualified name taken): the key comes
--       back against the restored table
--   S5  before uninstall, the key still suspended: uninstall's restore re-adds it against the parent, not the
--       namesake at its recorded name, and the schema goes
--
-- ASYMMETRIC FIXTURES. The managed table holds ids 1..150 except every multiple of 7 (129 rows); every
-- namesake holds a single id the table does not (999, 7777, 8888), so a write or a key against the wrong
-- relation is visible in exactly one place. Identity is asserted by oid, sets of rows by id.
--
-- bench/recorded_identity.sh runs this file and tests/240 against every mutant that puts one site back to a
-- name (bench/mutations/mutate.py; its header lists them), and each must FAIL there.
\if :{?uninstall}
\else
\set uninstall ../pgpm_core/uninstall.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(28);

create schema m0; create schema m1; create schema m2; create schema m3; create schema m4;

-- the top-level key on a referencing table, by the referenced relation's current qualified name, or 'none'
create function pg_temp.key_on(p_rel regclass) returns text language sql as $$
  select coalesce(string_agg(k.conname || '->' || n.nspname || '.' || c.relname, ',' order by k.conname), 'none')
    from pg_constraint k join pg_class c on c.oid = k.confrelid join pg_namespace n on n.oid = c.relnamespace
   where k.conrelid = p_rel and k.contype = 'f' and k.conparentid = 0
$$;
create function pg_temp.refused(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'accepted';
exception when foreign_key_violation then
  return 'refused';
end $$;
-- a relation's schema-qualified name by oid, or 'gone'
create function pg_temp.at(p_oid oid) returns text language sql as $$
  select coalesce((select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where c.oid = p_oid), 'gone')
$$;
-- how many rows a relation holds, by oid
create function pg_temp.rows_in(p_oid oid) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute format('select count(*) from %s', p_oid::regclass::text) into v;
  return v;
end $$;
-- drive a regrain to the swap in one transaction, as regrain() does; the error text instead of an abort,
-- so a wrong resolution fails the assertion and the file goes on
create function pg_temp.drive(p_parent regclass, p_child name) returns text language plpgsql as $$
declare v text;
begin
  for i in 1 .. 30 loop
    v := pgpm.regrain_step(p_parent, p_child, '50', 1000);
    exit when v like 'swapped:%';
  end loop;
  return v;
exception when others then
  return 'error: ' || sqlerrm;
end $$;

create table m0.ev (id bigint primary key, body text);
insert into m0.ev select g, 'r' || g from generate_series(1, 150) g where g % 7 <> 0;
create table m0.refs (id int primary key, ev_id bigint constraint refs_ev_fk references m0.ev (id));
insert into m0.refs values (10, 3), (11, 117);
call pgpm.transmute('m0.ev', 'id', 100::bigint, p_obtain => 3, p_incoming_fks => 'preserve');
select 'm0.ev'::regclass::oid as parent \gset

-- ======================================================================================================
-- S1: after transmute, the key suspended; moved m0 -> m1, a namesake takes m0.ev
-- ======================================================================================================
alter table m0.ev set schema m1;
create table m0.ev (id bigint constraint ev_s1_pkey primary key);
insert into m0.ev values (999);
select ok((select restored_at is null and definition like '%REFERENCES m0.ev(id)%'
             from pgpm.dropped_fk where parent_table = :parent::oid::regclass)
          and 'm0.ev'::regclass::oid <> :parent::oid,
  'S1 LIVENESS: the key is suspended, its recorded text names m0.ev, and m0.ev is now a namesake');
select is(pgpm.restore_incoming_fks(:parent::oid::regclass), 1, 'S1: restore_incoming_fks re-adds the key');
select is(pg_temp.key_on('m0.refs'), 'refs_ev_fk->m1.ev', 'S1: against the managed parent, not the namesake');

-- ======================================================================================================
-- S2: mid-regrain, the first copy part-filled; moved m1 -> m2, a namesake takes the copy's name in m2
-- ======================================================================================================
insert into m1.ev values (250, 'frontier');   -- freezes the monolith [0, 200)
select pgpm.set_regrain('m1.ev', '50');
select pgpm.regrain_step('m1.ev', 'ev_p0000000000000000000_to_0000000000000000200', '50', 20);   -- prepare
select pgpm.regrain_step('m1.ev', 'ev_p0000000000000000000_to_0000000000000000200', '50', 20);   -- 20 rows into [0, 50)
select child_oid as copy0 from pgpm.part where parent_table = :parent::oid::regclass and not attached and lo = '0' \gset
select child_oid as source from pgpm.part where parent_table = :parent::oid::regclass and attached and lo = '0' \gset
alter table m1.ev set schema m2;
create table m2.ev_p0000000000000000000 (id bigint, note text);
insert into m2.ev_p0000000000000000000 values (7777, 'namesake');
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived)
  values (:parent::oid::regclass, '0', '10', 'ev_p0000000000000000000_to_0000000000000000200', 8);

select is((select regrain_cursor from pgpm.config where parent_table = :parent::oid::regclass)
          || ' ' || pg_temp.rows_in(:copy0),
  '0 20', 'S2 LIVENESS: the copy of [0, 50) is part-filled: 20 rows, and the cursor still at 0');
select ok(pg_temp.at(:copy0) in ('m0.ev_p0000000000000000000', 'm1.ev_p0000000000000000000')
          and 'm2.ev_p0000000000000000000'::regclass::oid <> :copy0::oid,
  'S2 LIVENESS: the copy stayed where it was made, and its name in the parent''s new schema m2 is a namesake''s');
select is(pg_temp.drive(:parent::oid::regclass, 'ev_p0000000000000000000_to_0000000000000000200'), 'swapped:4',
  'S2: the moved table''s regrain runs on to the swap');
select is((select child_oid from pgpm.part where parent_table = :parent::oid::regclass and attached and lo = '0'),
  :copy0::oid, 'S2: the copy attached for [0, 50) is the one recorded before the move');
select is((select array_agg(pg_temp.at(child_oid) order by lo::bigint) from pgpm.part
            where parent_table = :parent::oid::regclass and lo::bigint < 200),
  array['m0.ev_p0000000000000000000', 'm0.ev_p0000000000000000050', 'm0.ev_p0000000000000000100',
        'm0.ev_p0000000000000000150'],
  'S2: every copy was made beside the source in m0, and none in the parent''s new schema');
select is(pg_temp.at(:source), 'gone', 'S2: the source the copies replaced is dropped, by oid');
select is((select array_agg(id order by id) from m2.ev where id < 200),
  (select array_agg(g::bigint order by g) from generate_series(1, 150) g where g % 7 <> 0),
  'S2: the managed table holds exactly its rows below 200');
select is((select array_agg(id::text || ':' || note) from m2.ev_p0000000000000000000)
          || (select relispartition::text from pg_class where oid = 'm2.ev_p0000000000000000000'::regclass),
  array['7777:namesake', 'false'], 'S2: the namesake keeps its one row and is no partition of anything');
select is(pg_temp.key_on('m0.refs'), 'refs_ev_fk->m2.ev', 'S2: the swap put the incoming key back against the parent');
select is((select method from pgpm.log where parent_table = :parent::oid::regclass and action = 'archive_coverage_reset'),
  '1 archived chunk(s) were recorded for m0.ev_p0000000000000000000_to_0000000000000000200, which this regrain replaced with 4 fine partition(s) and dropped; discarded, and each fine partition archives from its own lo',
  'S2: the coverage reset names the source where it was, in m0');

-- ======================================================================================================
-- S3: archive coverage and retain, the key suspended; moved m2 -> m3, namesakes of the two aged partitions
-- in m3. The write block, the archive step and retain are called as maintain calls them, without the tick's
-- restore of the key.
-- ======================================================================================================
alter table m2.ev set schema m3;
create table m3.ev_p0000000000000000000 (id bigint);
insert into m3.ev_p0000000000000000000 values (8888);
create table m3.ev_p0000000000000000050 (id bigint);
insert into m3.ev_p0000000000000000050 values (8888);
select pgpm.set_archive_fn(:parent::oid::regclass, 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
update pgpm.config set retain = '100' where parent_table = :parent::oid::regclass;   -- set_retain refuses arming a drop
select pgpm.suspend_incoming_fks(:parent::oid::regclass, true);
select ok(not exists (select 1 from pg_constraint where confrelid = :parent::oid and contype = 'f'),
  'S3 LIVENESS: no live key references the managed table, so its partitions retire without pg_cron');
select child_oid as aged50 from pgpm.part where parent_table = :parent::oid::regclass and lo = '50' \gset
select is((select pgpm._retain_boundary(c) from pgpm.config c where parent_table = :parent::oid::regclass), '100',
  'S3 LIVENESS: the horizon is 100, so [0, 50) and [50, 100) are wholly past it');
select ok(pg_temp.at(:copy0) = 'm0.ev_p0000000000000000000' and pg_temp.at(:aged50) = 'm0.ev_p0000000000000000050'
          and 'm3.ev_p0000000000000000000'::regclass::oid <> :copy0::oid,
  'S3 LIVENESS: both aged partitions are in m0, and their names in the parent''s new schema m3 are namesakes''');
select pgpm._enforce_write_blocks(:parent::oid::regclass);
select pgpm._archive_step(:parent::oid::regclass);
select pgpm._archive_step(:parent::oid::regclass);
select pgpm.retain(:parent::oid::regclass);
select is((select array_agg(lo || '-' || hi order by lo::bigint) from pgpm.log
            where parent_table = :parent::oid::regclass and action = 'retain_drop'),
  array['0-50', '50-100'], 'S3: retire dropped exactly the two aged partitions');
select is(pg_temp.at(:copy0) || ' ' || pg_temp.at(:aged50), 'gone gone', 'S3: the relations pgpm recorded, by oid');
select is((select array_agg(child_name || ' ' || lo || '-' || hi || ':' || rows_archived order by lo::bigint)
             from pgpm.archive_ledger where parent_table = :parent::oid::regclass),
  array['ev_p0000000000000000000 0-50:42', 'ev_p0000000000000000050 50-100:43'],
  'S3: each was archived whole first, its rows counted in the relation pgpm recorded (42 and 43)');
select is((select array_agg(id) from m3.ev_p0000000000000000000) || (select array_agg(id) from m3.ev_p0000000000000000050),
  array[8888, 8888]::bigint[], 'S3: both namesakes keep their rows');
select is((select array_agg(id order by id) from m3.ev where id < 200),
  (select array_agg(g::bigint order by g) from generate_series(100, 150) g where g % 7 <> 0),
  'S3: the managed table lost exactly its rows below 100');

-- ======================================================================================================
-- S4: untransmute, a second table moved AND renamed, a namesake at its recorded qualified name
-- ======================================================================================================
create table m0.uv (id bigint primary key, body text);
insert into m0.uv values (1, 'a'), (2, 'b'), (5, 'e');
create table m0.urefs (id int primary key, uv_id bigint constraint urefs_uv_fk references m0.uv (id));
insert into m0.urefs values (10, 1);
call pgpm.transmute('m0.uv', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('m0.uv');
select monolith_oid as umono from pgpm.config where parent_table = 'm0.uv'::regclass \gset
alter table m0.uv set schema m1;
alter table m1.uv rename to uv2;
create table m0.uv (id bigint constraint uv_s4_pkey primary key);
insert into m0.uv values (999);
select ok((select definition like '%REFERENCES m0.uv(id)%' from pgpm.dropped_fk where parent_table = 'm1.uv2'::regclass)
          and pg_temp.at(:umono) like 'm0.%',
  'S4 LIVENESS: the recorded text names m0.uv, a namesake holds it, and the monolith is in m0');
select is(pg_temp.at(pgpm.untransmute('m1.uv2')::oid), 'm1.uv2', 'S4: untransmute hands back the monolith as m1.uv2');
select is(pg_temp.key_on('m0.urefs'), 'urefs_uv_fk->m1.uv2', 'S4: the key is back against the restored table');

-- ======================================================================================================
-- S5: uninstall, the key still suspended; moved m3 -> m4, a namesake takes m3.ev
-- ======================================================================================================
select ok((select restored_at is null and definition like '%REFERENCES m0.ev(id)%' from pgpm.dropped_fk
             where parent_table = :parent::oid::regclass),
  'S5 LIVENESS: the key is still suspended, its recorded text naming m0.ev');
alter table m3.ev set schema m4;
create table m3.ev (id bigint constraint ev_s5_pkey primary key);
insert into m3.ev values (999);

\set ON_ERROR_STOP 0
begin;
\ir :uninstall
commit;
\set ON_ERROR_STOP 1

select is(to_regnamespace('pgpm'), null, 'S5 LIVENESS: uninstall went through');
select is(pg_temp.key_on('m0.refs'), 'refs_ev_fk->m4.ev', 'S5: uninstall put the key back against the managed table');
select is(pg_temp.refused($$ insert into m0.refs values (12, 999) $$) || '/'
          || pg_temp.refused($$ insert into m0.refs values (13, 101) $$),
  'refused/accepted', 'S5: and it enforces the managed table''s keys (999 refused, 101 accepted)');

select * from finish();
