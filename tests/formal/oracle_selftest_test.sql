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

select plan(100);

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

-- ==================================================================== no dependency on pgpm
-- pgpm's uninstall refuses while anything outside pgpm depends on it (tests/239 runs it), so the oracle must not
create function st.deps_on_pgpm() returns text[] language sql as $$
  select coalesce(array_agg(distinct pg_describe_object(d.classid, d.objid, d.objsubid)), '{}')
    from pg_depend d
   where ((d.classid = 'pg_proc'::regclass and d.objid in (select oid from pg_proc where pronamespace = 'pgpm_formal'::regnamespace))
       or (d.classid = 'pg_class'::regclass and d.objid in (select oid from pg_class where relnamespace = 'pgpm_formal'::regnamespace))
       or (d.classid = 'pg_type'::regclass and d.objid in (select oid from pg_type where typnamespace = 'pgpm_formal'::regnamespace)))
     and ((d.refclassid = 'pg_proc'::regclass and d.refobjid in (select oid from pg_proc where pronamespace = 'pgpm'::regnamespace))
       or (d.refclassid = 'pg_class'::regclass and d.refobjid in (select oid from pg_class where relnamespace = 'pgpm'::regnamespace))
       or (d.refclassid = 'pg_type'::regclass and d.refobjid in (select oid from pg_type where typnamespace = 'pgpm'::regnamespace)));
$$;
select cmp_ok((select count(*) from pg_proc where pronamespace = 'pgpm_formal'::regnamespace), '>', 10::bigint,
  'LIVENESS: the oracle''s functions are installed');
select is(st.deps_on_pgpm(), '{}'::text[], 'nothing of the oracle depends on an object of pgpm''s');

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

-- ==================================================================== retention's crossing delete (W3)
-- retire() on a partition a declared foreign key references DELETEs the referenced rows first, so the ON DELETE runs,
-- and logs retain_crossing; the partition stays attached until the dispatched detach lands. Retention ran over those
-- rows as surely as a retain_drop, but NoLostRow excused only retain_drop and regrain_aged, so they read as lost
-- (tests/231, 253 and 266). A cron.job stand-in takes the dispatch, as those files do (no pg_cron here). Early in the
-- file: pgpm dispatches one referenced detach at a time database-wide, and the custody section below plants a mark.
create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');
select st.mk('st.xc');
call pgpm.transmute('st.xc', 'id', 10, p_retain => 30, p_obtain => 10);
select st.fill('st.xc');
select pgpm_formal.baseline('st.xc') as xc_n \gset
create table st.xc_ref (id bigint primary key, xc_id bigint references st.xc (id) on delete cascade);
insert into st.xc_ref values (1, 12), (2, 54);
select child_name as xc_doomed from pgpm.part where parent_table = 'st.xc'::regclass and lo = '10' \gset
select is(pgpm.retire('st.xc', :'xc_doomed'), false, 'LIVENESS: retire() takes the referenced path (dispatch, drop later)');
select is((select array_agg(id order by id) from st.xc where id < 20) || (select array_agg(id order by id) from st.xc_ref),
  array[1, 2, 3, 4, 5, 19, 2]::bigint[], 'LIVENESS: the crossing delete took exactly the referenced row 12, and the ON DELETE ref 1');
select is((select count(*)::int from pgpm.log where parent_table = 'st.xc'::regclass and action = 'retain_crossing' and lo = '10'), 1,
  'LIVENESS: retain_crossing logged over [10, 20)');
select is((select count(*)::int from pgpm_formal.check() where parent_table = 'st.xc'::regclass), 0,
  'the row retention''s crossing delete took is not reported lost');
delete from st.xc where id = 54;
select is((select array_agg(identity) from pgpm_formal.check() where parent_table = 'st.xc'::regclass and invariant = 'NoLostRow'),
  array['[54]'], 'and a row deleted outside every range retention ran over still is (ref 2 went with it)');
select pgpm_formal.deleted('st.xc', 'id = 54');
-- land the dispatched detach as the pgpm_detach job would, and let retire() drop it: no mark stays in flight
alter table st.xc detach partition st.xc_p0000000000000000010;
select is(pgpm.retire('st.xc', :'xc_doomed'), true, 'fixture: with its detach landed, retire() drops [10, 20)');
drop schema cron cascade;

-- ==================================================================== a retired chunk's bound no session parses (W3)
-- check() cast every retired chunk's bounds to the control's type, so one written under another DateStyle or in
-- another encoding (tests/347 G, on purpose) raised out of check() for the whole file. pgpm reads it at its widest.
select st.mk('st.ub');
call pgpm.transmute('st.ub', 'id', 10, p_retain => 30, p_obtain => 10);
select st.fill('st.ub');
select pgpm_formal.baseline('st.ub') as ub_n \gset
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, rows_archived, retired_at)
  values ('st.ub', 'ten', '20', 'ub_gone', 'k/ub', 0, now());
delete from st.ub where id = 61;
select is(pgpm_formal._bound('ten', 'bigint'), null, 'LIVENESS: the planted chunk''s lo parses as no bigint');
select is((select array_agg(invariant || ' ' || identity) from pgpm_formal.check() where parent_table = 'st.ub'::regclass),
  array['NoLostRow [61]'], 'check() reads past a chunk whose bound it cannot parse, and still names the row deleted by hand');
select pgpm_formal.deleted('st.ub', 'id = 61');
delete from pgpm.archive_ledger where parent_table = 'st.ub'::regclass;

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
-- a keyless parent: a row written twice and aged out twice needs both copies in its object (Codex, #1486)
create table st.dk (id bigint not null, payload text);
insert into st.dk values (3, 'twin'), (3, 'twin'), (7, 'solo');
call pgpm.transmute('st.dk', 'id', 10, p_retain => 30, p_obtain => 10);
select st.fill('st.dk');
select pgpm_formal.baseline('st.dk');
select pgpm.set_archive_fn('st.dk', 'st.arch(regclass,name,text,text)'::regprocedure);
select pgpm.resume('st.dk');
call pgpm.maintain('st.dk');
call pgpm.maintain('st.dk');
call pgpm.maintain('st.dk');
call pgpm.maintain('st.dk');
call pgpm.maintain('st.dk');
call pgpm.maintain('st.dk');
select is((select mult from pgpm_formal.ledger where parent_oid = 'st.dk'::regclass and row_data ->> 'payload' = 'twin'), 2,
  'fixture: the ledger records the keyless twin with multiplicity 2');
select is((select count(*) from st.dk where payload = 'twin'), 0::bigint,
  'LIVENESS: both copies of the twin are gone, its chunk retired');
insert into pgpm_formal.store (parent_table, s3_key, identity)
select 'st.dk'::regclass, format('st.dk/%s', ((l.row_data ->> 'id')::bigint / 10) * 10), l.identity
  from pgpm_formal.ledger l cross join lateral generate_series(1, l.mult)
 where l.parent_oid = 'st.dk'::regclass and (l.row_data ->> 'id')::bigint < 60;
insert into pgpm_formal.store_listing (parent_table) values ('st.dk'::regclass);
select is(st.found('ArchiveNoClobber', 'st.dk'), '{}'::text[],
  'ArchiveNoClobber is clean when the object holds both copies of the keyless twin');
delete from pgpm_formal.store where ctid = (select ctid from pgpm_formal.store
  where parent_table = 'st.dk'::regclass and identity like '%twin%' limit 1);
select is(st.found('ArchiveNoClobber', 'st.dk'),
  array[(select identity from pgpm_formal.ledger where parent_oid = 'st.dk'::regclass and row_data ->> 'payload' = 'twin')],
  'ArchiveNoClobber names the keyless twin whose object holds one of its two copies');
insert into pgpm_formal.store (parent_table, s3_key, identity)
select 'st.dk'::regclass, 'st.dk/0', identity from pgpm_formal.ledger
 where parent_oid = 'st.dk'::regclass and row_data ->> 'payload' = 'twin';
update pgpm.archive_ledger set hi = '15' where parent_table = 'st.dc'::regclass and lo = '10';   -- [10, 15): 19 uncovered
select is(st.found('DropOnlyCovered', 'st.dc'), array['[19]'],
  'DropOnlyCovered names the row removed with no retired chunk holding it');
-- judged by the strategy in force at the drop, not today's (W6): unset now, the uncovered drop is still named
select is((select array_agg(distinct strategy) from pgpm_formal.drop_history
            where by_pgpm and parent_oid = 'st.dc'::regclass::oid and part_lo is not null), array[true],
  'LIVENESS: every partition of st.dc pgpm dropped was dropped while its archive strategy was set');
update pgpm.config set archive_fn = null where parent_table = 'st.dc'::regclass;
select is(st.found('DropOnlyCovered', 'st.dc'), array['[19]'],
  'DropOnlyCovered still names it once the strategy is unset: the drop ran under one');
update pgpm.config set archive_fn = 'st.arch(regclass,name,text,text)'::regprocedure where parent_table = 'st.dc'::regclass;

-- ==================================================================== DropOnlyCovered, a strategy set after the drop (W6)
-- tests/59: retention under no strategy drops what it ages out, as documented; a strategy set later covers only
-- the drops made under it.
select st.mk('st.ds');
call pgpm.transmute('st.ds', 'id', 10, p_retain => 30, p_obtain => 10);
select st.fill('st.ds');
select pgpm_formal.baseline('st.ds');
select is(pgpm.retain('st.ds'), 6, 'fixture: retention under no strategy drops the six partitions of [0, 60)');
select pgpm.set_archive_fn('st.ds', 'st.arch(regclass,name,text,text)'::regprocedure);
select is((select array_agg(distinct strategy) from pgpm_formal.drop_history
            where by_pgpm and parent_oid = 'st.ds'::regclass::oid and part_lo is not null), array[false],
  'LIVENESS: the drops ran with no strategy, and one is set now, so today''s config would judge them');
select is(st.found('DropOnlyCovered', 'st.ds'), '{}'::text[],
  'DropOnlyCovered judges a drop by the strategy in force when it ran, not by one set after it');
select is(st.found('NoLostRow', 'st.ds'), '{}'::text[], 'and retention accounts for every row it dropped');
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
-- a copy whose whole parent is gone is not judged (W6, tests/276's closing `drop owned by`): pgpm.part keeps the
-- dropped parent's rows under its dangling oid, and the promise lasts while the parent does
create table st.wg (id bigint primary key, body text);
insert into st.wg select g, 'b' || g from generate_series(1, 500) g;
call pgpm.transmute('st.wg', 'id', 100, p_obtain => 2, p_paused => true);
insert into st.wg values (750, 'past the monolith');
select is(pgpm.regrain_step('st.wg', 'wg_p0000000000000000000_to_0000000000000000600', '10', 30), 'prepared',
  'fixture: the regrain of st.wg''s monolith is prepared');
select is(pgpm.regrain_step('st.wg', 'wg_p0000000000000000000_to_0000000000000000600', '10', 30), 'copied:9',
  'fixture: and its first fine copy is made');
select 'st.wg'::regclass::oid as wg_oid \gset
drop table st.wg cascade;
select is(
  (select array_agg(p.child_name) from pgpm.part p where p.parent_table::oid = :wg_oid and not p.attached
      and not exists (select 1 from pg_class c where c.oid = :wg_oid)),
  array['wg_p0000000000000000000'::name],
  'LIVENESS: the copy''s row stands in pgpm.part, not attached, under a parent oid pg_class no longer has');
select is(st.found_like('NoWedge', 'copy wg_%'), '{}'::text[], 'NoWedge does not judge the copy of a parent that is gone');

-- ==================================================================== a text_time key with no native value (W6)
-- tests/389: a key without the declared shape has no native value, and pgpm routes and retires it by text order
-- against the encoded bounds. The 8 hex digits of the epoch second, then a suffix; the odd key puts a 'z' in the
-- eighth digit.
create function st.hx(p_ts timestamptz) returns text language sql immutable as
  $$ select lpad(to_hex(extract(epoch from p_ts)::bigint), 8, '0') $$;
create table st.tt (id text collate "C" primary key, v int);
insert into st.tt values (st.hx('2020-01-10 00:00:00+00') || 'a', 1), (st.hx('2020-06-01 00:00:00+00') || 'a', 2);
select (now() - timestamptz '2021-06-15 00:00:00+00') as tt_ret \gset
call pgpm.transmute('st.tt', 'id', interval '1 year', p_obtain => 1,
  p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's');
-- the monolith runs to the present, so it is regrained into years first (as tests/389 does), past a frontier row,
-- with no retention yet (the regrain would age 2020 out itself)
select (date_trunc('year', now()) + interval '2 years 5 months 14 days') as tt_pin \gset
select pgpm.extend_to('st.tt', st.hx(:'tt_pin'::timestamptz) || 'a') as tt_ext \gset
insert into st.tt values (st.hx(:'tt_pin'::timestamptz) || 'a', 9);
do $$
declare v_child name; v_status text; i int := 0;
begin
  select child_name into v_child from pgpm.part where parent_table = 'st.tt'::regclass
     and lo::timestamptz = '2020-01-01 00:00:00+00';
  loop
    v_status := pgpm.regrain_step('st.tt', v_child, '1 year', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or v_status in ('active', 'nokey', 'nosubdiv') or i > 100;
  end loop;
  if v_status not like 'swapped:%' then raise exception 'st.tt: the regrain ended %', v_status; end if;
end $$;
insert into st.tt values (left(st.hx('2020-01-11 00:00:00+00'), 7) || 'z', 3);
select pgpm_formal.baseline('st.tt');
-- by hand: set_retain refuses a value whose next tick drops a partition, the very thing wanted here
update pgpm.config set retain = :'tt_ret' where parent_table = 'st.tt'::regclass;
select is(pgpm_formal._native_of((select to_jsonb(c) from pgpm.config c where parent_table = 'st.tt'::regclass),
                                 jsonb_build_object('id', left(st.hx('2020-01-11 00:00:00+00'), 7) || 'z')),
  null, 'LIVENESS: the odd key has no native value');
select cmp_ok(pgpm.retain('st.tt'), '>', 0, 'fixture: retention drops the 2020 partition, the odd key with it');
select is((select count(*)::int from pgpm.log where parent_table = 'st.tt'::regclass and action = 'retain_drop'
              and lo::timestamptz = '2020-01-01 00:00:00+00'), 1,
  'LIVENESS: retain_drop is logged for [2020, 2021), and the odd key is gone');
select is(st.found('NoLostRow', 'st.tt'), '{}'::text[],
  'NoLostRow places a key with no native value by text order in the retained range that took it');
-- the same key gone with no retention at all is lost
create table st.tu (id text collate "C" primary key, v int);
insert into st.tu values (st.hx('2020-01-10 00:00:00+00') || 'a', 1), (st.hx('2020-06-01 00:00:00+00') || 'a', 2);
call pgpm.transmute('st.tu', 'id', interval '1 year', p_obtain => 1,
  p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's');
insert into st.tu values (left(st.hx('2020-01-11 00:00:00+00'), 7) || 'z', 3);
select pgpm_formal.baseline('st.tu');
delete from st.tu where v = 3;
select is(st.found('NoLostRow', 'st.tu'),
  array[(select identity from pgpm_formal.ledger where parent_oid = 'st.tu'::regclass and row_data ->> 'v' = '3')],
  'NoLostRow names a key with no native value that is gone with no retention over it');

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
  'rb_p0000000000000000030:true:pgpm.part child_oid, anchored earlier, created by pgpm',
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

-- ==================================================================== the parent after its monolith is gone (W3)
-- The ledger holds the oid baseline() was handed, which transmute makes the monolith of a NEW parent. Once a regrain
-- swap drops the monolith, the name was all that was left: a parent moved to another schema, with a namesake made
-- under its old name, had every row read as lost against the namesake (tests/349, 197, 204, 355). The triggers now
-- note the parent each baselined table is a partition of (parent_seen).
create schema mv3;
create table mv3.t (id bigint primary key, payload text);
insert into mv3.t select g, 'p' || g from generate_series(1, 25) g;
select pgpm_formal.baseline('mv3.t') as mv3_n \gset
select oid as mv3_orig from pg_class where oid = 'mv3.t'::regclass \gset
call pgpm.transmute('mv3.t', 'id', 10, p_obtain => 2);
insert into mv3.t values (35, 'frontier');
select pgpm.regrain_history('mv3.t') as mv3_rg \gset
alter schema mv3 rename to mv3_aside;
create schema mv3;
create table mv3.t (id bigint primary key, payload text);
select is((select count(*)::int from pg_class where oid = :'mv3_orig'::oid) || ':' || pgpm_formal._current_parent(:'mv3_orig'::oid)::text,
  '0:mv3_aside.t', 'LIVENESS: the monolith is gone, a namesake stands under the old name, and the ledger finds the moved parent');
select is((select count(*)::int from mv3_aside.t where id <= 25), 25, 'LIVENESS: all 25 baselined rows are in the moved parent');
select is((select count(*)::int from pgpm_formal.check() where parent_table::text in ('mv3.t', 'mv3_aside.t')), 0,
  'no row of the moved parent reads as lost, and none is judged against the namesake');

-- ==================================================================== a column named like the row alias (W3)
-- baseline() read each row as to_jsonb(t) over `from <parent> t`, and a column named t won that name: the ledger kept
-- the column, not the row, so no control value could be decoded and every aged row read as lost (tests/archive/db/33
-- and 48). A text column t here; the regrain ages the rows below the horizon out.
create table st.sh (id bigint primary key, t text);
insert into st.sh select g, 'p' || g from generate_series(1, 50) g;
select pgpm_formal.baseline('st.sh') as sh_n \gset
call pgpm.transmute('st.sh', 'id', 10, p_retain => 20);
insert into st.sh values (65, 'frontier');
select pgpm.regrain_history('st.sh') as sh_rg \gset
select is((select bool_and(row_data ? 'id' and row_data ? 't') from pgpm_formal.ledger
            where parent_oid = (select parent_oid from pgpm_formal.ledger_parent where parent_name = 'st.sh')),
  true, 'the ledger holds each row of a table with a column named t, not the column');
select ok((select count(*) from st.sh where id <= 50) between 1 and 49,
  'LIVENESS: the regrain aged some baselined rows out and kept others');
select is((select count(*)::int from pgpm_formal.check() where parent_table = 'st.sh'::regclass), 0,
  'no aged row of it reads as lost');

-- ==================================================================== a hypertable pgpm converts (W3)
-- pgpm_hypertable's cutover drops the hypertable it was handed, which pgpm neither created nor lists in pgpm.part or
-- pgpm.config: pgpm.scratch keys the copy's working relations by the hypertable's oid (parent_oid), and that is its
-- record. No TimescaleDB here, so the cutover's drop is stood in for by a function in schema pgpm (a pgpm frame).
create table st.ht_src (id int);
create table st.ht_dest (id int);
create table st.ht_none (id int);
create function pgpm.st_drop_w3(p_rel regclass) returns void language plpgsql as $$
begin execute format('drop table %s', p_rel); end $$;
insert into pgpm.scratch (parent_oid, kind, obj) values ('st.ht_src'::regclass, 'hypertable_dest', 'st.ht_dest'::regclass);
select pgpm.st_drop_w3('st.ht_src');
select pgpm.st_drop_w3('st.ht_none');
delete from pgpm.scratch where kind = 'hypertable_dest' and obj = 'st.ht_dest'::regclass;
drop function pgpm.st_drop_w3(regclass);
select is((select array_agg(object_name || ':' || by_pgpm || ':' || coalesce(recorded_as, '-') order by object_name)
             from pgpm_formal.drop_history where object_name in ('ht_src', 'ht_none')),
  array['ht_none:true:-', 'ht_src:true:pgpm.scratch parent_oid'],
  'LIVENESS: both drops ran under a pgpm frame, and pgpm.scratch named the one as the relation its work is keyed by');
select is(st.found_like('ResolveByRecord', 'st.ht_src'), '{}'::text[],
  'ResolveByRecord accepts the drop of a relation pgpm.scratch keys a conversion by');
select is(st.found_like('ResolveByRecord', 'st.ht_none'), array['st.ht_none'],
  'ResolveByRecord names the drop of a relation nothing of pgpm''s named');
-- pgpm_hypertable's comment record (W6, tests/348): uninstall's sweeps drop a relation by marker AND suffix, so a
-- marked one is recorded, and a lookalike that only ends in the suffix is not (#737, #773)
create table st.mk_pgpm_dest (id int);
comment on table st.mk_pgpm_dest is 'pgpm from_hypertable copy of 4242';
create table st.mk_pgpm_delta (id int);
comment on table st.mk_pgpm_delta is 'pgpm from_hypertable horizon 777';
create table st.um_pgpm_dest (id int);
create function pgpm.st_drop_w6(p_rel regclass) returns void language plpgsql as $$
begin execute format('drop table %s', p_rel); end $$;
select pgpm.st_drop_w6('st.mk_pgpm_dest');
select pgpm.st_drop_w6('st.mk_pgpm_delta');
select pgpm.st_drop_w6('st.um_pgpm_dest');
drop function pgpm.st_drop_w6(regclass);
select is((select array_agg(object_name || ':' || by_pgpm order by object_name)
             from pgpm_formal.drop_history where object_name in ('mk_pgpm_dest', 'mk_pgpm_delta', 'um_pgpm_dest')),
  array['mk_pgpm_delta:true', 'mk_pgpm_dest:true', 'um_pgpm_dest:true'],
  'LIVENESS: the three drops ran under a pgpm frame');
select is(st.found_like('ResolveByRecord', 'st.mk_pgpm_%'), '{}'::text[],
  'ResolveByRecord accepts the drop of a relation the module''s comment marks as its copy or delta');
select is(st.found_like('ResolveByRecord', 'st.um_pgpm_%'), array['st.um_pgpm_dest'],
  'ResolveByRecord names the drop of an unmarked lookalike that only ends in _pgpm_dest');

-- ==================================================================== no new locks for temporary tables (W3)
-- pgpm_archive's archive._refuse_foreign_read fails a read whose transaction newly holds a lock on any relation that is
-- not the read's own, and archive._pq_snapshot drops and creates its temporary snapshot table inside that window. The
-- triggers once read pgpm's catalog and wrote the history there, so tests/archive/db/08 failed with the oracle
-- installed and only then. The relations a DDL statement newly locks (oids from 16384 up, as that check reads them):
create function st.new_locks(p_sql text) returns int language plpgsql as $$
declare v_before oid[]; v_n int;
begin
  select coalesce(array_agg(relation), '{}') into v_before from pg_locks
   where locktype = 'relation' and pid = pg_backend_pid() and relation >= 16384;
  execute p_sql;
  select count(distinct relation) into v_n from pg_locks
   where locktype = 'relation' and pid = pg_backend_pid() and relation >= 16384 and relation <> all (v_before)
     -- the statement's own table: temporary, or gone (the dropped one)
     and relation in (select oid from pg_class where relpersistence <> 't');
  return v_n;
end $$;
select cmp_ok(st.new_locks('create table st.lk_plain as select 1 as x'), '>', 0,
  'LIVENESS: a CREATE TABLE AS of an ordinary table newly locks relations outside the catalog (the oracle''s history)');
select is(st.new_locks('create temp table lk_temp as select 1 as x'), 0,
  'a CREATE TEMP TABLE AS newly locks no relation outside the catalog');
select is(st.new_locks('drop table pg_temp.lk_temp'), 0, 'a DROP of a temporary table newly locks no relation outside the catalog');
select is((select count(*)::int from pgpm_formal.drop_history where object_name = 'lk_temp'), 0,
  'the temporary table''s drop is not in the history (check() never reads one)');

-- ==================================================================== no wait on another session's anchor (W3)
-- Both triggers note pgpm's anchors at every DDL statement. With a unique key on anchor_seen, a session noting an oid
-- another transaction had just noted waited for that transaction to end; tests/345 part C's swap (pgpm's, holding the
-- copy's oid noted) and the test's own ALTER TABLE in a second session deadlocked, with the oracle installed and only
-- then. Here a second session notes an oid and stays open while this one notes the same oid under a statement timeout
-- (a timeout is not swallowed by _note_anchors' handler, so a wait fails the call).
create extension if not exists dblink;
create table st.an_rel (id int);
insert into pgpm.scratch (parent_oid, kind, obj) values ('st.an_rel'::regclass, 'hypertable_delta', 'st.an_rel'::regclass);
select dblink_connect('an', format('dbname=%s user=postgres', current_database())) as an_c \gset
select dblink_exec('an', 'begin') as an_b \gset
select dblink_exec('an', 'do $n$ begin perform pgpm_formal._note_anchors(); end $n$') as an_n \gset
set statement_timeout = '3s';
select lives_ok('select pgpm_formal._note_anchors()', 'noting an anchor another open transaction just noted does not wait for it');
reset statement_timeout;
select dblink_exec('an', 'commit') as an_e \gset
select dblink_disconnect('an') as an_d \gset
select is((select count(*)::int from pgpm_formal.anchor_seen where objid = 'st.an_rel'::regclass),
  2, 'LIVENESS: both sessions noted the oid, the other one''s uncommitted when this one did');
delete from pgpm.scratch where kind = 'hypertable_delta' and obj = 'st.an_rel'::regclass;

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
select pgpm_formal.expect('ResolveByRecord', 'st.ht_none', 'planted: a pgpm-framed drop of a relation nothing named');
select pgpm_formal.expect('ResolveByRecord', 'st.um_pgpm_dest', 'planted: a pgpm-framed drop of an unmarked lookalike');
select pgpm_formal.expect('NoLostRow', (select identity from pgpm_formal.ledger where parent_oid = 'st.tu'::regclass
                                         and row_data ->> 'v' = '3'), 'planted: an odd key deleted by hand', 'st.tu');
select pgpm_formal.expect('NoLostRow', '[424242]', 'a declaration nothing matches');
select pgpm_formal.expect('NoLostRow', '[19]', 'a right identity on the wrong parent', 'st.nl');
select is(
  (select array_agg(invariant || ' ' || identity order by identity) from pgpm_formal.check()),
  array['UnusedExpectation NoLostRow:[19]', 'UnusedExpectation NoLostRow:[424242]'],
  'with every planted violation declared, check() reports only the two declarations that matched nothing');
select is(
  (select array_agg(invariant || '=' || expected order by invariant) from pgpm_formal.judged()),
  array['ArchiveNoClobber=1', 'DropOnlyCovered=1', 'NoDuplicateRow=2', 'NoLostRow=6', 'NoWedge=3', 'ResolveByRecord=5'],
  'judged() counts the declarations per invariant');
-- Every declaration above but the two unused matched a violation, and a violation is of an identity check() judged, so
-- each invariant judged() names with a declaration must count at least one identity. Not a premise: judged() is the
-- oracle's output, and one that reports nothing judged where check() found violations is the zero-judged reading the
-- track's witness (tests/formal/summarize.py) fails on, here held to what check() just reported (W5).
select is(
  (select array_agg(invariant order by invariant) from pgpm_formal.judged() where expected > 0 and identities = 0),
  null::text[],
  'judged() counts the identities of every invariant whose violations check() reported');
select is(
  (select array_agg(invariant order by invariant) from pgpm_formal.judged() where judged and identities > 0),
  array['ArchiveNoClobber', 'DropOnlyCovered', 'NoDuplicateRow', 'NoLostRow', 'NoWedge', 'ResolveByRecord'],
  'LIVENESS: the last check() judged every invariant over at least one identity');

select * from finish();
