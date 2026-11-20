-- The oracle's own guard (docs/formal/phase3-design.md, W2): for every check, a clean scenario it reports
-- nothing on, and a planted violation it reports with the right identity. Every "reports nothing" is paired with a
-- LIVENESS: premise that the scenario reached the state the check judges, since a check that never saw the state
-- reports nothing too.
--
-- Runs in a database holding pgtap, pgpm's core and tests/formal/oracle.sql, and no pg_cron (a clone of the pgTAP
-- template: pg_cron lives in `postgres`). Violations are planted with pgpm's own operations where one reaches the
-- state, and by a direct edit of pgpm's tables only where none can in this database: a custody partition and a
-- dispatched mark (both need pg_cron's pgpm_detach job), a retired chunk over a live partition, a shrunken chunk
-- (both are the defects only a mutation of pgpm reaches), an unanchored pgpm.part row (an older install's).
--
-- check() judges the whole database, so each scenario has its own tables and every assertion selects the rows of
-- its own parent or identity; the last block declares every planted violation with expect() and requires check()
-- to return exactly the one declaration left unmatched.
create extension if not exists pgtap;

select plan(52);

create schema st;

-- the identities one invariant reports for one parent, sorted
create function st.found(p_inv text, p_parent regclass) returns text[] language sql as $$
  select coalesce(array_agg(identity order by identity), '{}') from pgpm_formal.check()
   where invariant = p_inv and parent_table = p_parent;
$$;
-- the identities one invariant reports that match a pattern, whatever the parent
create function st.found_like(p_inv text, p_like text) returns text[] language sql as $$
  select coalesce(array_agg(identity order by identity), '{}') from pgpm_formal.check()
   where invariant = p_inv and identity like p_like;
$$;

-- An id grid of step 10: a monolith [0, 10) holding 1..5, then 12, 19, ... 89 (one or two per partition) and a
-- frontier at 95. retain 30 puts the horizon at 60, so [0, 60) ages out and [60, 110) stays.
create function st.mk(p_rel text) returns void language plpgsql as $$
begin
  execute format('create table %s (id bigint primary key, payload text)', p_rel);
  execute format('insert into %s select g, ''p'' || g from generate_series(1, 5) g', p_rel);
end $$;
create function st.fill(p_rel text) returns void language plpgsql as $$
begin
  execute format('insert into %s select g, ''p'' || g from generate_series(12, 89, 7) g', p_rel);
  execute format('insert into %s values (95, ''frontier'')', p_rel);
end $$;

-- ==================================================================== nothing baselined: not judged
select is((select count(*) from pgpm_formal.check()), 0::bigint, 'fixture: an empty database has no violation');
select is(
  (select array_agg(invariant || '=' || judged order by invariant) from pgpm_formal.judged()
    where invariant in ('NoLostRow', 'NoDuplicateRow')),
  array['NoDuplicateRow=false', 'NoLostRow=false'],
  'with no baseline, NoLostRow and NoDuplicateRow are reported not judged, never as a pass');

-- ==================================================================== NoLostRow
select st.mk('st.nl');
call pgpm.transmute('st.nl', 'id', 10, p_retain => 30, p_obtain => 10);
select st.fill('st.nl');
select is(pgpm_formal.baseline('st.nl'), 18::bigint,
  'fixture: the baseline records the 18 rows written (1..5, 12..89 by 7, 95)');
delete from st.nl where id = 89;
select is(pgpm_formal.deleted('st.nl', 'id = 89'), 1::bigint, 'fixture: the test records its delete of 89');
insert into st.nl values (77, 'late');
select is(pgpm_formal.wrote('st.nl', 'id = 77'), 1::bigint, 'fixture: the test records its write of 77');
select is(pgpm.retain('st.nl'), 6, 'fixture: retention drops the six partitions of [0, 60)');

select is(
  (select array_agg(id order by id) from st.nl),
  array[61, 68, 75, 77, 82, 95]::bigint[],
  'LIVENESS: the rows below the horizon are gone and the rest are visible (89 deleted, 77 written)');
select is(st.found('NoLostRow', 'st.nl'), '{}'::text[],
  'NoLostRow is clean when retention removed only aged rows, the test deleted 89 and wrote 77');

drop table st.nl_p0000000000000000070;   -- [70, 80), above the horizon, by hand
select is(st.found('NoLostRow', 'st.nl'), array['[75]', '[77]'],
  'NoLostRow names the two rows of the partition the test dropped above the horizon, the recorded write among them');
select pgpm_formal.operator_owns('st.nl_p0000000000000000080');
alter table st.nl detach partition st.nl_p0000000000000000080;   -- [80, 90) holds 82; 89 was deleted
select is((select array_agg(id) from st.nl where id >= 80 and id < 90), null::bigint[],
  'LIVENESS: 82 is out of the parent, in the table the test registered as the operator''s and detached');
select is(st.found('NoLostRow', 'st.nl'), array['[75]', '[77]'],
  'NoLostRow counts a row in the operator''s relation as kept, and still names the two dropped');

-- below the horizon, but retention never ran over it: dropped by hand before retain()
select st.mk('st.nb');
call pgpm.transmute('st.nb', 'id', 10, p_retain => 30, p_obtain => 10);
select st.fill('st.nb');
select pgpm_formal.baseline('st.nb');
drop table st.nb_p0000000000000000020;   -- [20, 30) holds 26
select is(pgpm.retain('st.nb'), 5, 'fixture: retention drops the five aged partitions that remain');
select is(
  (select array_agg(lo order by lo::numeric) from pgpm.log where parent_table = 'st.nb'::regclass and action = 'retain_drop'),
  array['0', '10', '30', '40', '50'],
  'LIVENESS: retention ran over every aged range but [20, 30), so 26 is below the horizon with no drop of retention''s over it');
select is(st.found('NoLostRow', 'st.nb'), array['[26]'],
  'NoLostRow names the row below the horizon that no retention removed');

-- ==================================================================== NoDuplicateRow, keyless
-- baselined in a session zone far from UTC: the identity is rendered under the oracle's pinned UTC either way
set timezone = 'Asia/Kolkata';
create table st.kl (v int, ts timestamptz);
insert into st.kl values (1, '2026-01-01 00:00:00+00'), (1, '2026-01-01 00:00:00+00'), (2, '2026-01-02 00:00:00+00');
select is(pgpm_formal.baseline('st.kl'), 3::bigint, 'fixture: the keyless baseline records three rows');
reset timezone;
select is(
  (select mult from pgpm_formal.ledger where parent_oid = 'st.kl'::regclass and identity = '{"v": 1, "ts": "2026-01-01T00:00:00+00:00"}'),
  2, 'LIVENESS: the equal pair is recorded once with multiplicity 2, its identity rendered in UTC');
select is(st.found('NoDuplicateRow', 'st.kl'), '{}'::text[],
  'NoDuplicateRow is clean on a keyless table whose equal rows were written as such');
insert into st.kl values (1, '2026-01-01 00:00:00+00');
select is(st.found('NoDuplicateRow', 'st.kl'), array['{"v": 1, "ts": "2026-01-01T00:00:00+00:00"}'],
  'NoDuplicateRow names the keyless row now visible three times where two were written');

-- ==================================================================== custody (NoLostRow, NoDuplicateRow, NoWedge)
select st.mk('st.cu');
call pgpm.transmute('st.cu', 'id', 10, p_retain => 30, p_obtain => 10);
select st.fill('st.cu');
select pgpm_formal.baseline('st.cu');
-- pgpm's dispatched detach of [30, 40), landed: the state pg_cron's pgpm_detach job leaves (no pg_cron here)
alter table st.cu detach partition st.cu_p0000000000000000030;
update pgpm.part set retiring_at = now(), retiring_oid = child_oid, detach_dispatched_oid = child_oid
 where parent_table = 'st.cu'::regclass and child_name = 'cu_p0000000000000000030';
select is(
  (select (select array_agg(id) from st.cu_p0000000000000000030)::text || ' ' || (p.detach_dispatched_oid = p.child_oid)
          || ' ' || exists (select 1 from pg_inherits i where i.inhrelid = p.child_oid)
     from pgpm.part p where p.parent_table = 'st.cu'::regclass and p.child_name = 'cu_p0000000000000000030'),
  '{33} true false',
  'LIVENESS: 33 is out of the parent, in a partition pgpm''s recorded dispatch holds');
select is(st.found('NoLostRow', 'st.cu'), '{}'::text[], 'NoLostRow counts a row in custody as kept');
select is(st.found_like('NoWedge', 'mark cu_%'), '{}'::text[],
  'NoWedge is clean on a mark whose detach landed (the partition is in custody, retire() drops it next)');
update pgpm.part set detach_dispatched_oid = null
 where parent_table = 'st.cu'::regclass and child_name = 'cu_p0000000000000000030';
select is(st.found('NoLostRow', 'st.cu'), array['[33]'],
  'with no dispatch recorded the same table is not custody, and NoLostRow names its row');
update pgpm.part set detach_dispatched_oid = child_oid
 where parent_table = 'st.cu'::regclass and child_name = 'cu_p0000000000000000030';
select is(st.found('NoDuplicateRow', 'st.cu'), '{}'::text[], 'NoDuplicateRow is clean across the parent and custody');
insert into st.cu_p0000000000000000030 values (54, 'copy of a row the parent holds');
select is(st.found('NoDuplicateRow', 'st.cu'), array['[54]'],
  'NoDuplicateRow names the identity visible through the parent and in custody');
-- a dispatched mark on a partition still attached, which no pgpm_detach job can detach
update pgpm.part set retiring_at = now(), retiring_oid = child_oid, detach_dispatched_oid = child_oid
 where parent_table = 'st.cu'::regclass and child_name = 'cu_p0000000000000000060';
select is(st.found_like('NoWedge', 'mark cu_%'), array['mark cu_p0000000000000000060'],
  'NoWedge names the dispatched mark on an attached partition nothing will detach, and not the landed one');

-- ==================================================================== DropOnlyCovered, ArchiveNoClobber, NoWedge chunks
create table st.calls (p_child name, p_lo text, p_hi text);
create function st.arch(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into st.calls values (p_child, p_lo, p_hi);
  v.covered_hi := p_hi; v.rows_archived := 0; v.s3_key := format('%s/%s', p_parent, p_lo); v.etag := 'e';
  execute format('select count(*) from %s where id >= %s and id < %s', p_parent, p_lo, p_hi) into v.rows_archived;
  return v;
end $$;
select st.mk('st.dc');
call pgpm.transmute('st.dc', 'id', 10, p_retain => 30, p_obtain => 10);
select st.fill('st.dc');
select pgpm_formal.baseline('st.dc');
create table st.dc_before as select * from st.dc;
select pgpm.set_archive_fn('st.dc', 'st.arch(regclass,name,text,text)'::regprocedure);
select pgpm.resume('st.dc');
call pgpm.maintain('st.dc');
call pgpm.maintain('st.dc');
call pgpm.maintain('st.dc');
call pgpm.maintain('st.dc');
call pgpm.maintain('st.dc');
call pgpm.maintain('st.dc');
select is(
  (select array_agg(l.lo || ':' || (h.by_pgpm is true) order by l.lo::numeric)
     from pgpm.archive_ledger l left join pgpm_formal.drop_history h on h.objid = l.child_oid
    where l.parent_table = 'st.dc'::regclass and l.retired_at is not null),
  array['0:true', '10:true', '20:true', '30:true', '40:true', '50:true'],
  'LIVENESS: six chunks archived and retired, each from a relation the drop history shows pgpm dropped');
select is((select array_agg(id order by id) from st.dc where id < 60), null::bigint[],
  'LIVENESS: every row below the horizon is gone');
select is(st.found('DropOnlyCovered', 'st.dc'), '{}'::text[],
  'DropOnlyCovered is clean when every row retention removed is in a retired chunk pgpm dropped');
select is(st.found_like('NoWedge', 'chunk %'), '{}'::text[],
  'NoWedge is clean when every retired chunk''s relation is gone');
select is((select judged from pgpm_formal.judged() where invariant = 'ArchiveNoClobber'), false,
  'ArchiveNoClobber is not judged before the store is listed');
-- the store the archive track's harness would load: each aged row under its chunk's key
insert into pgpm_formal.store (parent_table, s3_key, identity)
select 'st.dc'::regclass, format('st.dc/%s', (id / 10) * 10), jsonb_build_array(id)::text from st.dc_before where id < 60;
insert into pgpm_formal.store_listing (parent_table) values ('st.dc'::regclass);
select is(st.found('ArchiveNoClobber', 'st.dc'), '{}'::text[],
  'ArchiveNoClobber is clean when every retired chunk''s object holds its rows');
select is((select identities from pgpm_formal.judged() where invariant = 'ArchiveNoClobber'), 12::bigint,
  'LIVENESS: ArchiveNoClobber judged the twelve aged rows of st.dc');
delete from pgpm_formal.store where parent_table = 'st.dc'::regclass and identity = '[40]';
select is(st.found('ArchiveNoClobber', 'st.dc'), array['[40]'],
  'ArchiveNoClobber names the row its chunk''s object no longer holds');
update pgpm.archive_ledger set hi = '15' where parent_table = 'st.dc'::regclass and lo = '10';   -- [10, 15): 19 uncovered
select is(st.found('DropOnlyCovered', 'st.dc'), array['[19]'],
  'DropOnlyCovered names the row removed with no retired chunk holding it');
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, rows_archived, retired_at, child_oid)
select 'st.dc'::regclass, '70', '80', child_name, 'st.dc/70', 1, now(), child_oid
  from pgpm.part where parent_table = 'st.dc'::regclass and child_name = 'dc_p0000000000000000070';
select is(st.found_like('NoWedge', 'chunk %'), array['chunk 70'],
  'NoWedge names the retired chunk whose relation, a live partition, still exists');

-- ==================================================================== NoWedge, regrain copies
create table st.rg (id bigint primary key, body text);
insert into st.rg select g, 'b' || g from generate_series(1, 500) g;
call pgpm.transmute('st.rg', 'id', 100, p_obtain => 2, p_paused => true);
insert into st.rg values (750, 'past the monolith');
select is(pgpm.regrain_step('st.rg', 'rg_p0000000000000000000_to_0000000000000000600', '10', 30), 'prepared',
  'fixture: the regrain of the monolith is prepared');
select is(pgpm.regrain_step('st.rg', 'rg_p0000000000000000000_to_0000000000000000600', '10', 30), 'copied:9',
  'fixture: the first fine copy is made');
select is(
  (select array_agg(child_name) from pgpm.part where parent_table = 'st.rg'::regclass and not attached),
  array['rg_p0000000000000000000'::name],
  'LIVENESS: a regrain copy stands, not yet attached');
select is(st.found_like('NoWedge', 'copy rg_%'), '{}'::text[], 'NoWedge is clean while the copy''s source stands');
drop table st.rg_p0000000000000000000_to_0000000000000000600;
select is(st.found_like('NoWedge', 'copy rg_%'), array['copy rg_p0000000000000000000'],
  'NoWedge names the regrain copy that outlived its source');

-- ==================================================================== ResolveByRecord
select st.mk('st.rb');
call pgpm.transmute('st.rb', 'id', 10, p_retain => 30, p_obtain => 10);
select st.fill('st.rb');
create table st.op1 (id int);
select pgpm_formal.operator_owns('st.op1');
drop table st.op1;
select pgpm_formal.operator_owns('st.rb_p0000000000000000060');
alter table st.rb detach partition st.rb_p0000000000000000060;
select is(
  (select string_agg(object_name || ':' || by_pgpm, ' ') from pgpm_formal.drop_history where object_name = 'op1')
  || ' ' || exists (select 1 from pg_inherits where inhrelid = 'st.rb_p0000000000000000060'::regclass)
  || ' ' || (select by_pgpm from pgpm_formal.alter_history where objid = 'st.rb'::regclass order by id desc limit 1),
  'op1:false false false',
  'LIVENESS: the test dropped one operator relation and detached the other, and the histories attribute both to it');
select is(st.found_like('ResolveByRecord', 'st.%'), '{}'::text[],
  'ResolveByRecord is clean when the test drops and detaches its own relations');
select pgpm_formal.operator_owns('st.rb_p0000000000000000010');
-- an older install's row, which records no oid, and a namesake the test put in its place (the #421 shape)
update pgpm.part set child_oid = null where parent_table = 'st.rb'::regclass and child_name = 'rb_p0000000000000000020';
drop table st.rb_p0000000000000000020;
create table st.rb_p0000000000000000020 partition of st.rb for values from (20) to (30);
select is(pgpm.retain('st.rb'), 6, 'fixture: retention drops [0, 60), the operator''s [10, 20) and the namesake in [20, 30) among it');
select is(
  (select string_agg(object_name || ':' || by_pgpm || ':' || coalesce(recorded_as, '-'), ' ' order by id)
     from pgpm_formal.drop_history where schema_name = 'st' and object_name = 'rb_p0000000000000000030'),
  'rb_p0000000000000000030:true:pgpm.part child_oid, created by pgpm',
  'LIVENESS: pgpm''s drop of a partition it made and recorded is attributed to pgpm and recorded twice over');
select is(st.found_like('ResolveByRecord', 'st.%'),
  array['st.rb_p0000000000000000010', 'st.rb_p0000000000000000020'],
  'ResolveByRecord names the operator''s relation pgpm dropped and the namesake pgpm dropped by name, and no other drop');
create table st.ut (id bigint primary key, body text);
insert into st.ut select g, 'b' || g from generate_series(1, 50) g;
call pgpm.transmute('st.ut', 'id', 100, p_obtain => 2);
select pgpm_formal.operator_owns('st.ut_p0000000000000000000');
select is(pgpm.untransmute('st.ut')::text, 'st.ut', 'fixture: untransmute hands the monolith back');
select is(st.found_like('ResolveByRecord', 'st.ut%'), array['st.ut'],
  'ResolveByRecord names the operator''s relation pgpm detached from its parent');

-- ==================================================================== expectations
select throws_like($$ select pgpm_formal.expect('NoLostRows', '[1]', 'typo') $$,
  '%NoLostRows is not an invariant the oracle judges%', 'expect() refuses a name that is not an invariant');
select throws_like($$ select pgpm_formal.expect('NoLostRow', '[1]', ' ') $$,
  '%say why%', 'expect() refuses a declaration with no reason');
select pgpm_formal.expect('NoLostRow', '[75]', 'planted: [70, 80) dropped by hand', 'st.nl');
select pgpm_formal.expect('NoLostRow', '[77]', 'planted: [70, 80) dropped by hand', 'st.nl');
select pgpm_formal.expect('NoLostRow', '[26]', 'planted: [20, 30) dropped by hand', 'st.nb');
select pgpm_formal.expect('NoDuplicateRow', '{"v": 1, "ts": "2026-01-01T00:00:00+00:00"}', 'planted: a third copy');
select pgpm_formal.expect('NoDuplicateRow', '[54]', 'planted: a copy in custody', 'st.cu');
select pgpm_formal.expect('NoWedge', 'mark cu_p0000000000000000060', 'planted: a mark no job holds');
select pgpm_formal.expect('ArchiveNoClobber', '[40]', 'planted: the object lost a row', 'st.dc');
select pgpm_formal.expect('DropOnlyCovered', '[19]', 'planted: the chunk shrunk', 'st.dc');
select pgpm_formal.expect('NoWedge', 'chunk 70', 'planted: a retired chunk over a live partition');
select pgpm_formal.expect('NoWedge', 'copy rg_p0000000000000000000', 'planted: the source dropped by hand');
select pgpm_formal.expect('ResolveByRecord', 'st.rb_p0000000000000000010', 'planted: the operator''s partition aged out');
select pgpm_formal.expect('ResolveByRecord', 'st.rb_p0000000000000000020', 'planted: an unanchored row');
select pgpm_formal.expect('ResolveByRecord', 'st.ut', 'planted: untransmute of an operator''s monolith');
select pgpm_formal.expect('NoLostRow', '[424242]', 'a declaration nothing matches');
select pgpm_formal.expect('NoLostRow', '[19]', 'a right identity on the wrong parent', 'st.nl');
select is(
  (select array_agg(invariant || ' ' || identity order by identity) from pgpm_formal.check()),
  array['UnusedExpectation NoLostRow:[19]', 'UnusedExpectation NoLostRow:[424242]'],
  'with every planted violation declared, check() reports only the two declarations that matched nothing');
select is(
  (select array_agg(invariant || '=' || expected order by invariant) from pgpm_formal.judged()),
  array['ArchiveNoClobber=1', 'DropOnlyCovered=1', 'NoDuplicateRow=2', 'NoLostRow=5', 'NoWedge=3', 'ResolveByRecord=3'],
  'judged() counts the declarations per invariant');
select is(
  (select array_agg(invariant order by invariant) from pgpm_formal.judged() where judged and identities > 0),
  array['ArchiveNoClobber', 'DropOnlyCovered', 'NoDuplicateRow', 'NoLostRow', 'NoWedge', 'ResolveByRecord'],
  'LIVENESS: the last check() judged every invariant over at least one identity');

select * from finish();
