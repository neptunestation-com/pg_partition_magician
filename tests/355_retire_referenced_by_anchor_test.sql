-- retire()'s referenced path retires the partition pgpm.part anchors, never a namesake in another schema (#1365).
--
-- THE BUG. retire() vouches for a partition by its anchor (child_oid, the #407/#428 identity check) and locks that
-- relation (v_rel), but its referenced (incoming-FK) path then picked the partition to retire out of pg_inherits by
-- RELNAME alone: `where i.inhparent = p_parent and c.relname = p_child`, no schema, no oid. A partition of the same
-- parent under the same relname in another schema (an operator's table, attached over a range pgpm does not hold)
-- could be the row that query returned. retire() then recorded the stranger's oid as retiring_oid, armed the
-- pgpm_detach job with a detach of the STRANGER, and every later retire() of the aged cell refused it as
-- fail_retain_identity: retention wedged for good, and the operator's table queued to leave its parent. The same
-- relname-only reading decided whether ANOTHER retirement's mark was still in flight, so a mark whose partition was
-- gone held every referenced retirement in the database off, silently, for as long as a namesake was attached.
--
-- THE CONTRACT.
--   PART A  the issue. With an operator's same-named partition listed first in pg_inherits, retire() records the
--           anchored partition as retiring_oid and arms the job with ITS detach; run as pg_cron would, the detach
--           lands on it, the next retire() drops it (true, retain_drop, no fail_retain_identity), and the operator's
--           table is still a partition of the parent with its one row.
--   PART B  the sibling, the one-detach-in-flight check: a mark whose partition was dropped by hand while a
--           namesake in another schema is attached to its parent does not hold off another parent's referenced
--           retirement, which marks its own partition and dispatches its detach.
--   PART C  the upgrade's half: a mark an older retire() recorded on the namesake (retiring_oid and the dispatch
--           record its oid, the job armed with its detach, which that retire() then refused for good) is cleared
--           by the re-run install.sql (retain_disown naming that oid), the job disarmed, and the cell's retirement
--           starts over on the anchored partition, never refused again; the namesake stays attached with its row.
--   PART D  the #421 backfill of an unanchored row (an install older than child_oid), the namesake listed first:
--           the row is anchored to the partition in the parent's schema, and retire()'s one-step DROP takes that
--           partition, the namesake standing with its row.
--   PART E  _child_nsp for an unanchored row, the namesake listed first: the parent's schema, and retire()'s
--           one-step DROP takes the partition there, never the namesake.
--   PART F  an unanchored row whose own partition was dropped by hand, the SOLE partition of the parent carrying its
--           name an operator's table in another schema over another range: neither the backfill nor _child_nsp
--           takes it (its bound is not the row's range), and retire() drops nothing; the table keeps both rows.
--   PART G  the same with the operator's table in the PARENT'S OWN schema, where _child_nsp's last answer leads:
--           retire() refuses it (fail_retain_identity) and the write block is not put on it
--           (fail_write_block_identity), compared by the row's range; the table keeps both rows and stays writable.
--   PART H  an int4 grid, whose non-negative bounds pg_get_expr spells bare (FROM (100) TO (200)): the upgrade
--           anchors every unanchored row of it to its own partition and backfills the monolith from them.
--   PART I  a moved int4 parent's unanchored row: _child_nsp finds its partition in the old schema by its range,
--           and retire() drops it.
--   PART J  adopt_partition on an int4 grid reads the bare bound and records the partition over it.
--   An older retire()'s mark on an UNANCHORED row is judged by the relation it marks, which must be a partition of
--   the parent carrying the row's range. Each mark below is the one a retire() older than this fix writes on that
--   state: retiring_oid and detach_dispatched_oid the operator's table, the job armed with its detach. This file
--   has one install, so it writes them by hand; the per-PR verification's repro.verified.sh shows the base's own
--   retire() writing exactly that.
--   PART K  the operator's table in the parent's own schema, still attached: the upgrade clears the mark (one
--           retain_disown) and disarms the job; retire() and pg_cron's run of the job take nothing.
--   PART L  the same in another schema, the row's name resolving to nothing (the pass reaches it all the same).
--   PART M  the same after pg_cron ran the armed detach: a mark on a relation the detach took out of the parent
--           has no range left to vouch for it; cleared, and retire() does not drop the table.
--   PART N  the mark written after the upgrade: retire() itself disowns it before honouring it.
--   PART O  the other side of M: an unanchored row's OWN partition (attached on the row's range) retired by this
--           retire(), its detach run by the job, is dropped by the next call (retain_drop), never disowned: retire()
--           anchors the row when it marks it.
--   PART P  regrain() of an unanchored row whose own partition was dropped by hand, an operator's table under the
--           name in the parent's schema attached over another range: the operator's table stays, with its rows.
--           Every step resolves a row's name through pgpm._part_rel, which withholds that table.
--   PART Q  the same state read by _is_write_blocked: the operator's table carries a pgpm_write_block enabled ALWAYS
--           (as an older pgpm left one), and it is not the row's block; _part_rel answers null for the row.
--   PART R  G's state one level down: the operator's table under the row's name is a partition of the operator's own
--           sub-partitioned partition of the parent, over another range. retire() takes it for attached at any level
--           (pg_partition_ancestors), so _part_rel must judge it at any level too: it is withheld, and retire()
--           drops nothing.
--
-- ASYMMETRIC FIXTURES. A's cell [100, 200) holds ids 101 and 102, the operator's table one row (5005); B's dropped
-- cell held 2 rows, its namesake holds 7007, and the other parent's aged cell holds 3 rows (301, 302, 303). C's cell
-- holds 121 and 122, its namesake 8008; D's cell 131 and 132, its namesake 9009; E's cell 141 and 142, its namesake
-- 9505; F's dropped cell held 151 and 152, its namesake holds 9701 and 9702; G's namesake 9801 and 9802; H's cells
-- hold 161 and 162 and 361; I's 171 and 172; J's 381; the operators' tables of K, L, M and N hold two rows each
-- (9811/9812, 9821/9822, 9831/9832, 9841/9842); O's cell holds 195 and 196 and its parent's frontier row 600; P's
-- operator table holds 9851 and 9852, Q's 9861, R's 9871 and 9872.
--
-- install.sql is re-run with \ir, relative to this file; the psql variable `install` overrides the path.
\if :{?install}
\else
\set install ../pgpm_core/install.sql
\endif
-- retire() is a function, not a committing procedure; no throws_* here.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(98);

-- pg_cron's job table, stood in for (as tests/171 and tests/194 do): the dispatch has to be real for the armed
-- command to be read and run
create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

-- ============================ PART A: the namesake listed first ============================
-- earlier pg_inherits tuples, freed below, so the operator's later ATTACH takes a lower heap slot than pgpm's cell
create table public.ra355_dummy (id int) partition by range (id);
create table public.ra355_d1 partition of public.ra355_dummy for values from (0) to (10);
create table public.ra355_d2 partition of public.ra355_dummy for values from (10) to (20);

create table public.ra355 (id bigint primary key, payload text);
insert into public.ra355 values (101, 'a'), (102, 'b');
call pgpm.transmute('public.ra355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.ra355 values (600, 'frontier');
create table public.ra355_ref (id bigint primary key, f_id bigint references public.ra355 (id));
insert into public.ra355_ref values (1, 600);
select child_name as a_cell, child_oid as a_cell_oid from pgpm.part
 where parent_table = 'public.ra355'::regclass and lo = '100' \gset

drop table public.ra355_dummy;
vacuum pg_inherits;
create schema ra355_ops;
create table ra355_ops.:"a_cell" (id bigint primary key, payload text);
insert into ra355_ops.:"a_cell" values (5005, 'operator');
alter table public.ra355 attach partition ra355_ops.:"a_cell" for values from (5000) to (5100);
select to_regclass(format('ra355_ops.%I', :'a_cell'))::oid as a_ops_oid \gset

select ok((select i.inhrelid from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.ra355'::regclass and c.relname = :'a_cell' limit 1) = :a_ops_oid
          and exists (select 1 from pg_inherits where inhparent = 'public.ra355'::regclass and inhrelid = :a_cell_oid),
  'LIVENESS: both relations named the cell are partitions of the parent, the operator''s listed first by name');

select is(pgpm.retire('public.ra355', :'a_cell'), false, 'LIVENESS: retire() takes the referenced path (false: under way)');
select is((select retiring_oid from pgpm.part where parent_table = 'public.ra355'::regclass and child_name = :'a_cell'),
  :'a_cell_oid'::oid, 'the retirement records the partition pgpm.part anchors, not the operator''s namesake');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.ra355 detach partition public.%I concurrently', :'a_cell'),
  'the job is armed with the detach of the anchored partition, in its own schema');
select is((select action from pgpm.log where parent_table = 'public.ra355'::regclass and lo = '100'
            and action in ('retain_detach', 'fail_retain_detach', 'fail_retain_identity') order by id),
  'retain_detach', 'LIVENESS: the dispatch succeeded and was logged once as retain_detach');

-- pg_cron runs the armed detach
select command from cron.job where jobname = 'pgpm_detach' \gexec

select is(pgpm.retire('public.ra355', :'a_cell'), true, 'the next retire() completes the retirement');
select ok(not exists (select 1 from pg_class where oid = :a_cell_oid), 'the anchored partition is the one dropped');
select results_eq(
  $$ select action from pgpm.log where parent_table = 'public.ra355'::regclass and lo = '100'
      and action in ('retain_detach', 'fail_retain_detach', 'fail_retain_identity', 'retain_drop', 'fail_retain_drop')
      order by id $$,
  $$ values ('retain_detach'::text), ('retain_drop'::text) $$,
  'the cell went retain_detach then retain_drop, never fail_retain_identity');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.ra355'::regclass and inhrelid = :a_ops_oid
                   and not inhdetachpending),
  'the operator''s namesake is still a partition of the parent');
select is((select string_agg(id::text, ',' order by id) from public.ra355 where id >= 5000), '5005',
  'and serves its one row through it');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.ra355'::regclass and lo = '100'),
  'the cell''s pgpm.part row went with the drop');
-- fixture: no mark of this part outlives it (one detach in flight is database-wide), and the job idles
update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'public.ra355'::regclass;
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';

-- ============================ PART B: a mark held by a namesake ============================
-- parent B1: a retirement under way (marked, detach dispatched and landed), its detached table then dropped by
-- hand, and a namesake of the operator's in another schema attached to B1
create table public.rb355 (id bigint primary key, payload text);
insert into public.rb355 values (111, 'a'), (112, 'b');
call pgpm.transmute('public.rb355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rb355 values (600, 'frontier');
create table public.rb355_ref (id bigint primary key, f_id bigint references public.rb355 (id));
insert into public.rb355_ref values (1, 600);
select child_name as b_cell, child_oid as b_cell_oid from pgpm.part
 where parent_table = 'public.rb355'::regclass and lo = '100' \gset
select is(pgpm.retire('public.rb355', :'b_cell'), false, 'LIVENESS: B1''s retirement is under way');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.rb355 detach partition public.%I concurrently', :'b_cell'),
  'LIVENESS: B1''s detach is the one armed');
select command from cron.job
 where jobname = 'pgpm_detach' and command = format('alter table public.rb355 detach partition public.%I concurrently', :'b_cell') \gexec
drop table public.:"b_cell";
create schema rb355_ops;
create table rb355_ops.:"b_cell" (id bigint primary key, payload text);
insert into rb355_ops.:"b_cell" values (7007, 'operator');
alter table public.rb355 attach partition rb355_ops.:"b_cell" for values from (7000) to (7100);
select is(pgpm.retire('public.rb355', :'b_cell'), false, 'LIVENESS: retire() of B1''s cell refuses');
select ok((select retiring_at is not null from pgpm.part where parent_table = 'public.rb355'::regclass and child_name = :'b_cell')
          and exists (select 1 from pgpm.log where parent_table = 'public.rb355'::regclass and lo = '100'
                       and action = 'fail_retain_identity'),
  'LIVENESS: B1''s mark stands, wedged on identity (fail_retain_identity)');
select ok(exists (select 1 from pg_inherits i join pg_class c on c.oid = i.inhrelid
                   where i.inhparent = 'public.rb355'::regclass and c.relname = :'b_cell'),
  'LIVENESS: a partition of B1 carries the mark''s name (the namesake)');

-- parent B2: an aged referenced cell of 3 rows, whose retirement sorts after B1's mark
create table public.rc355 (id bigint primary key, payload text);
insert into public.rc355 values (301, 'a'), (302, 'b'), (303, 'c');
call pgpm.transmute('public.rc355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rc355 values (900, 'frontier');
create table public.rc355_ref (id bigint primary key, f_id bigint references public.rc355 (id));
insert into public.rc355_ref values (1, 900);
select child_name as c_cell, child_oid as c_cell_oid from pgpm.part
 where parent_table = 'public.rc355'::regclass and lo = '300' \gset

select is(pgpm.retire('public.rc355', :'c_cell'), false, 'LIVENESS: retire() of B2''s cell returns false (under way)');
select ok((select retiring_oid = :c_cell_oid from pgpm.part where parent_table = 'public.rc355'::regclass and child_name = :'c_cell'),
  'B2''s retirement is not held off by B1''s mark: it marks its own partition');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.rc355 detach partition public.%I concurrently', :'c_cell'),
  'and arms the job with its detach');
select is((select string_agg(action, ',' order by id) from pgpm.log where parent_table = 'public.rc355'::regclass and lo = '300'
             and action in ('retain_detach', 'fail_retain_detach', 'fail_retain_identity', 'retain_drop', 'fail_retain_drop')),
  'retain_detach', 'logged once, retain_detach');
select is((select string_agg(id::text, ',' order by id) from public.rb355 where id >= 7000), '7007',
  'B1''s namesake keeps its row and its place');

-- fixture: no mark of this part outlives it, and the job idles
update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table in ('public.rb355'::regclass, 'public.rc355'::regclass);
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';

-- ============================ PART C: an older retire()'s mark on the namesake, at the upgrade ============================
create table public.rcc355 (id bigint primary key, payload text);
insert into public.rcc355 values (121, 'a'), (122, 'b');
call pgpm.transmute('public.rcc355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rcc355 values (600, 'frontier');
create table public.rcc355_ref (id bigint primary key, f_id bigint references public.rcc355 (id));
insert into public.rcc355_ref values (1, 600);
select child_name as cc_cell, child_oid as cc_cell_oid from pgpm.part
 where parent_table = 'public.rcc355'::regclass and lo = '100' \gset
create schema rcc355_ops;
create table rcc355_ops.:"cc_cell" (id bigint primary key, payload text);
insert into rcc355_ops.:"cc_cell" values (8008, 'operator');
alter table public.rcc355 attach partition rcc355_ops.:"cc_cell" for values from (8000) to (8100);
select to_regclass(format('rcc355_ops.%I', :'cc_cell'))::oid as cc_ops_oid \gset
select is(pgpm.retire('public.rcc355', :'cc_cell'), false, 'LIVENESS: C''s retirement is under way');
-- fixture: the mark as a retire() older than this fix wrote it, the namesake recorded and its detach armed
update pgpm.part set retiring_oid = :cc_ops_oid, detach_dispatched_oid = :cc_ops_oid
 where parent_table = 'public.rcc355'::regclass and child_name = :'cc_cell';
update cron.job set command = pgpm._detach_cmd('public.rcc355', 'rcc355_ops', :'cc_cell') where jobname = 'pgpm_detach';
select ok((select retiring_at is not null and retiring_oid = :cc_ops_oid from pgpm.part
            where parent_table = 'public.rcc355'::regclass and child_name = :'cc_cell')
          and (select command from cron.job where jobname = 'pgpm_detach')
              = pgpm._detach_cmd('public.rcc355', 'rcc355_ops', :'cc_cell'),
  'LIVENESS: C''s mark names the namesake, and the job is armed with its detach');

-- ============================ PART D: the #421 backfill, the namesake listed first ============================
create table public.rd355_dummy (id int) partition by range (id);
create table public.rd355_d1 partition of public.rd355_dummy for values from (0) to (10);
create table public.rd355_d2 partition of public.rd355_dummy for values from (10) to (20);
create table public.rd355 (id bigint primary key, payload text);
insert into public.rd355 values (131, 'a'), (132, 'b');
call pgpm.transmute('public.rd355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rd355 values (600, 'frontier');
select child_name as d_cell, child_oid as d_cell_oid from pgpm.part
 where parent_table = 'public.rd355'::regclass and lo = '100' \gset
drop table public.rd355_dummy;
vacuum pg_inherits;
create schema rd355_ops;
create table rd355_ops.:"d_cell" (id bigint primary key, payload text);
insert into rd355_ops.:"d_cell" values (9009, 'operator');
alter table public.rd355 attach partition rd355_ops.:"d_cell" for values from (9000) to (9100);
select to_regclass(format('rd355_ops.%I', :'d_cell'))::oid as d_ops_oid \gset
-- fixture: the row as an install older than child_oid left it
update pgpm.part set child_oid = null where parent_table = 'public.rd355'::regclass and child_name = :'d_cell';
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rd355'::regclass and inhrelid = :d_ops_oid)
          and exists (select 1 from pg_inherits where inhparent = 'public.rd355'::regclass and inhrelid = :d_cell_oid),
  'LIVENESS: D''s two relations named the cell are both partitions of the parent (which one a relname alone finds first is the heap''s order; part F has the sole namesake)');

-- ============================ PART F: the sole namesake, over another range ============================
create schema rf355_ops;
create table public.rf355 (id bigint primary key, payload text);
insert into public.rf355 values (151, 'a'), (152, 'b');
call pgpm.transmute('public.rf355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rf355 values (600, 'frontier');
select child_name as f_cell from pgpm.part where parent_table = 'public.rf355'::regclass and lo = '100' \gset
-- fixture: the row as an install older than child_oid left it, its partition dropped by hand, and the operator's own
-- table attached under the name in another schema over another range
update pgpm.part set child_oid = null where parent_table = 'public.rf355'::regclass and child_name = :'f_cell';
drop table public.:"f_cell";
create table rf355_ops.:"f_cell" (id bigint primary key, payload text);
insert into rf355_ops.:"f_cell" values (9701, 'operator'), (9702, 'operator');
alter table public.rf355 attach partition rf355_ops.:"f_cell" for values from (9700) to (9800);
select to_regclass(format('rf355_ops.%I', :'f_cell'))::oid as f_ops_oid \gset
select ok((select count(*) = 1 and bool_and(i.inhrelid = :f_ops_oid) from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.rf355'::regclass and c.relname = :'f_cell')
          and (select child_oid is null and attached and lo = '100' and hi = '200' from pgpm.part
                where parent_table = 'public.rf355'::regclass and child_name = :'f_cell'),
  'LIVENESS: F''s unanchored [100, 200) row has one namesake partition, the operator''s, over [9700, 9800)');

-- ============================ PART H: an int4 grid's bare bounds, at the upgrade ============================
create table public.rh355 (id integer primary key, payload text);
insert into public.rh355 values (161, 'a'), (162, 'b');
call pgpm.transmute('public.rh355', 'id', 100, p_obtain => 4, p_paused => true);
insert into public.rh355 values (361, 'c');
select monolith_oid as h_mono_oid from pgpm.config where parent_table = 'public.rh355'::regclass \gset
select string_agg(child_name || '=' || child_oid, ',' order by lo::numeric) as h_anchors from pgpm.part
 where parent_table = 'public.rh355'::regclass and attached \gset
-- fixture: the rows and the config as an install older than child_oid left them
update pgpm.part set child_oid = null where parent_table = 'public.rh355'::regclass;
update pgpm.config set monolith_oid = null where parent_table = 'public.rh355'::regclass;
select ok((select pg_get_expr(c.relpartbound, c.oid) from pg_class c where c.oid = :h_mono_oid) = 'FOR VALUES FROM (100) TO (200)'
          and (select count(*) >= 3 and bool_and(child_oid is null) from pgpm.part
                where parent_table = 'public.rh355'::regclass and attached),
  'LIVENESS: H''s monolith renders its bound bare, and every attached row is unanchored');

-- ============================ PARTS K, L, M: an older retire()'s mark on an unanchored row ============================
-- K: the operator's table in the parent's schema, attached
create table public.rk355 (id bigint primary key, payload text);
insert into public.rk355 values (191, 'a'), (192, 'b');
call pgpm.transmute('public.rk355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rk355 values (600, 'frontier');
select child_name as k_cell from pgpm.part where parent_table = 'public.rk355'::regclass and lo = '100' \gset
update pgpm.part set child_oid = null where parent_table = 'public.rk355'::regclass and child_name = :'k_cell';
drop table public.:"k_cell";
create table public.:"k_cell" (id bigint primary key, payload text);
insert into public.:"k_cell" values (9811, 'operator'), (9812, 'operator');
alter table public.rk355 attach partition public.:"k_cell" for values from (9810) to (9820);
-- the parent is referenced, so retirement takes the detach path
create table public.rk355_ref (id bigint primary key, f_id bigint references public.rk355 (id));
insert into public.rk355_ref values (1, 600);
select to_regclass(format('public.%I', :'k_cell'))::oid as k_ops_oid \gset
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = :k_ops_oid, detach_dispatched_oid = :k_ops_oid
 where parent_table = 'public.rk355'::regclass and child_name = :'k_cell';
update cron.job set command = pgpm._detach_cmd('public.rk355', 'public', :'k_cell') where jobname = 'pgpm_detach';
select ok((select child_oid is null and retiring_oid = :k_ops_oid from pgpm.part
            where parent_table = 'public.rk355'::regclass and child_name = :'k_cell')
          and pgpm._unanchored_stranger('public.rk355', :k_ops_oid, '100', '200'),
  'LIVENESS: K''s unanchored row carries a mark naming the operator''s table in the parent''s schema, a partition over another range');

-- L: the operator's table in another schema, attached; nothing holds the name in the parent's schema
create schema rl355_ops;
create table public.rl355 (id bigint primary key, payload text);
insert into public.rl355 values (191, 'a'), (192, 'b');
call pgpm.transmute('public.rl355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rl355 values (600, 'frontier');
select child_name as l_cell from pgpm.part where parent_table = 'public.rl355'::regclass and lo = '100' \gset
update pgpm.part set child_oid = null where parent_table = 'public.rl355'::regclass and child_name = :'l_cell';
drop table public.:"l_cell";
create table rl355_ops.:"l_cell" (id bigint primary key, payload text);
insert into rl355_ops.:"l_cell" values (9821, 'operator'), (9822, 'operator');
alter table public.rl355 attach partition rl355_ops.:"l_cell" for values from (9820) to (9830);
-- the parent is referenced, so retirement takes the detach path
create table public.rl355_ref (id bigint primary key, f_id bigint references public.rl355 (id));
insert into public.rl355_ref values (1, 600);
select to_regclass(format('rl355_ops.%I', :'l_cell'))::oid as l_ops_oid \gset
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = :l_ops_oid, detach_dispatched_oid = :l_ops_oid
 where parent_table = 'public.rl355'::regclass and child_name = :'l_cell';
select ok(to_regclass(format('public.%I', :'l_cell')) is null
          and pgpm._unanchored_stranger('public.rl355', :l_ops_oid, '100', '200'),
  'LIVENESS: L''s row name resolves to nothing in the parent''s schema, and its mark names a partition over another range');

-- M: as K, after pg_cron ran the armed detach of the operator's table
create table public.rm355 (id bigint primary key, payload text);
insert into public.rm355 values (191, 'a'), (192, 'b');
call pgpm.transmute('public.rm355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rm355 values (600, 'frontier');
select child_name as m_cell from pgpm.part where parent_table = 'public.rm355'::regclass and lo = '100' \gset
update pgpm.part set child_oid = null where parent_table = 'public.rm355'::regclass and child_name = :'m_cell';
drop table public.:"m_cell";
create table public.:"m_cell" (id bigint primary key, payload text);
insert into public.:"m_cell" values (9831, 'operator'), (9832, 'operator');
alter table public.rm355 attach partition public.:"m_cell" for values from (9830) to (9840);
-- the parent is referenced, so retirement takes the detach path
create table public.rm355_ref (id bigint primary key, f_id bigint references public.rm355 (id));
insert into public.rm355_ref values (1, 600);
select to_regclass(format('public.%I', :'m_cell'))::oid as m_ops_oid \gset
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = :m_ops_oid, detach_dispatched_oid = :m_ops_oid
 where parent_table = 'public.rm355'::regclass and child_name = :'m_cell';
select pgpm._detach_cmd('public.rm355', 'public', :'m_cell') \gexec
select ok(not exists (select 1 from pg_inherits where inhrelid = :m_ops_oid)
          and (select count(*) from public.:"m_cell") = 2,
  'LIVENESS: M''s marked table was detached by the armed command and holds its two rows');

-- the job, as the older retire() left it after K's dispatch (the last one armed)
update cron.job set command = pgpm._detach_cmd('public.rk355', 'public', :'k_cell') where jobname = 'pgpm_detach';

-- the upgrade, over C's, D's, F's, H's, K's, L's and M's states
select coalesce(max(id), 0) as log_mark from pgpm.log \gset
\ir :install
set client_min_messages = warning;

select ok((select retiring_at is null and retiring_oid is null and detach_dispatched_oid is null from pgpm.part
            where parent_table = 'public.rcc355'::regclass and child_name = :'cc_cell'),
  'C: the upgrade clears the mark that names the namesake');
select ok((select count(*) = 1 and bool_and(strpos(method, format('recorded oid %s', :cc_ops_oid)) > 0) from pgpm.log
            where parent_table = 'public.rcc355'::regclass and lo = '100' and action = 'retain_disown' and id > :log_mark),
  'C: logged once, retain_disown, naming the namesake''s oid');
select is((select command from cron.job where jobname = 'pgpm_detach'), 'select 1',
  'C: the job no longer holds the namesake''s detach');
select is(pgpm.retire('public.rcc355', :'cc_cell'), false, 'C: retire() starts the retirement over');
select is((select retiring_oid from pgpm.part where parent_table = 'public.rcc355'::regclass and child_name = :'cc_cell'),
  :'cc_cell_oid'::oid, 'C: on the anchored partition');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.rcc355 detach partition public.%I concurrently', :'cc_cell'),
  'C: and arms the job with its detach');
select is(pgpm.retire('public.rcc355', :'cc_cell'), false, 'C: a second call');
select is((select string_agg(action, ',' order by id) from pgpm.log
            where parent_table = 'public.rcc355'::regclass and lo = '100' and id > :log_mark
              and action in ('retain_detach', 'fail_retain_detach', 'fail_retain_identity', 'retain_disown')),
  'retain_disown,retain_detach,retain_detach', 'C: after the upgrade, never refused on identity');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rcc355'::regclass and inhrelid = :cc_ops_oid
                   and not inhdetachpending)
          and (select string_agg(id::text, ',' order by id) from public.rcc355 where id >= 8000) = '8008',
  'C: the namesake is still a partition, serving its row');
-- fixture: C's mark does not outlive it
update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'public.rcc355'::regclass;
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';

select is((select child_oid from pgpm.part where parent_table = 'public.rd355'::regclass and child_name = :'d_cell'),
  :'d_cell_oid'::oid, 'D: the upgrade anchors the row to the partition in the parent''s schema');
select is(pgpm.retire('public.rd355', :'d_cell'), true, 'D: retire() of the aged cell completes');
select ok(not exists (select 1 from pg_class where oid = :d_cell_oid), 'D: the anchored partition is the one dropped');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rd355'::regclass and inhrelid = :d_ops_oid)
          and (select string_agg(id::text, ',' order by id) from public.rd355 where id < 600 or id >= 9000) = '9009',
  'D: the namesake stands with its row, and the cell''s two rows are gone');

select is((select child_oid from pgpm.part where parent_table = 'public.rf355'::regclass and child_name = :'f_cell'),
  null::oid, 'F: the upgrade does not anchor the row to the operator''s table');
select is(pgpm._child_nsp('public.rf355', :'f_cell'), 'public'::name,
  'F: the unanchored row resolves in the parent''s schema, not the namesake''s');
select is(pgpm.retire('public.rf355', :'f_cell'), false, 'F: retire() of the aged cell drops nothing');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rf355'::regclass and inhrelid = :f_ops_oid)
          and (select string_agg(id::text, ',' order by id) from public.rf355 where id >= 9700) = '9701,9702',
  'F: the operator''s table stands, a partition with both its rows');

select is((select string_agg(child_name || '=' || child_oid, ',' order by lo::numeric) from pgpm.part
            where parent_table = 'public.rh355'::regclass and attached),
  :'h_anchors', 'H: the upgrade anchors every row of the int4 grid to its own partition');
select is((select monolith_oid from pgpm.config where parent_table = 'public.rh355'::regclass), :'h_mono_oid'::oid,
  'H: and backfills the monolith from them');

-- ============================ K, L, M after the upgrade ============================
select ok((select bool_and(retiring_at is null and retiring_oid is null and detach_dispatched_oid is null) from pgpm.part
            where (parent_table, child_name) in (('public.rk355'::regclass, :'k_cell'), ('public.rl355'::regclass, :'l_cell'),
                                                 ('public.rm355'::regclass, :'m_cell'))),
  'K, L, M: the upgrade clears each mark');
select is((select string_agg(format('%s=%s', parent_table, strpos(method, format('recorded oid %s', case parent_table
                                     when 'public.rk355'::regclass then :k_ops_oid when 'public.rl355'::regclass then :l_ops_oid
                                     else :m_ops_oid end)) > 0), ',' order by parent_table::text)
             from pgpm.log where parent_table in ('public.rk355'::regclass, 'public.rl355'::regclass, 'public.rm355'::regclass)
              and action = 'retain_disown' and id > :log_mark),
  'rk355=t,rl355=t,rm355=t', 'K, L, M: one retain_disown each, naming the marked table''s oid');
select is((select command from cron.job where jobname = 'pgpm_detach'), 'select 1',
  'K: the job no longer holds the operator''s detach');
select is(pgpm.retire('public.rk355', :'k_cell'), false, 'K: retire() of the aged cell takes nothing');
select is(pgpm.retire('public.rl355', :'l_cell'), false, 'L: nor of L''s');
select is(pgpm.retire('public.rm355', :'m_cell'), false, 'M: nor of M''s');
select command from cron.job where jobname = 'pgpm_detach' and command <> 'select 1' \gexec
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rk355'::regclass and inhrelid = :k_ops_oid and not inhdetachpending)
          and (select string_agg(id::text, ',' order by id) from public.rk355 where id >= 9800) = '9811,9812',
  'K: the operator''s table is still a partition, serving both its rows');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rl355'::regclass and inhrelid = :l_ops_oid and not inhdetachpending)
          and (select string_agg(id::text, ',' order by id) from public.rl355 where id >= 9800) = '9821,9822',
  'L: so is L''s');
select ok(exists (select 1 from pg_class where oid = :m_ops_oid)
          and (select string_agg(id::text, ',' order by id) from public.:"m_cell") = '9831,9832',
  'M: the detached table stands with both its rows');
select is((select count(*)::int from pgpm.log
            where parent_table in ('public.rk355'::regclass, 'public.rl355'::regclass, 'public.rm355'::regclass)
              and action in ('retain_detach', 'retain_drop') and id > :log_mark),
  0, 'K, L, M: nothing detached or dropped after the upgrade');

-- ============================ PART E: _child_nsp for an unanchored row ============================
-- The operator's schema is created before the parent's, so the namesake comes first both in pg_inherits (the freed
-- heap slots) and in pg_class's (relname, relnamespace) index, whichever way a plan reaches it.
create schema re355_ops;
create schema re355_own;
create table re355_own.re355_dummy (id int) partition by range (id);
create table re355_own.re355_d1 partition of re355_own.re355_dummy for values from (0) to (10);
create table re355_own.re355_d2 partition of re355_own.re355_dummy for values from (10) to (20);
create table re355_own.re355 (id bigint primary key, payload text);
insert into re355_own.re355 values (141, 'a'), (142, 'b');
call pgpm.transmute('re355_own.re355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into re355_own.re355 values (600, 'frontier');
select child_name as e_cell, child_oid as e_cell_oid from pgpm.part
 where parent_table = 're355_own.re355'::regclass and lo = '100' \gset
drop table re355_own.re355_dummy;
vacuum pg_inherits;
create table re355_ops.:"e_cell" (id bigint primary key, payload text);
insert into re355_ops.:"e_cell" values (9505, 'operator');
alter table re355_own.re355 attach partition re355_ops.:"e_cell" for values from (9500) to (9600);
select to_regclass(format('re355_ops.%I', :'e_cell'))::oid as e_ops_oid \gset
-- fixture: an unanchored row, as the backfill leaves one it could not resolve
update pgpm.part set child_oid = null where parent_table = 're355_own.re355'::regclass and child_name = :'e_cell';
select ok((select n.nspname from pg_inherits i join pg_class c on c.oid = i.inhrelid
             join pg_namespace n on n.oid = c.relnamespace
            where i.inhparent = 're355_own.re355'::regclass and c.relname = :'e_cell' limit 1) = 're355_ops'
          and exists (select 1 from pg_inherits where inhparent = 're355_own.re355'::regclass and inhrelid = :e_cell_oid),
  'LIVENESS: E''s two relations named the cell are partitions of the parent, the operator''s schema first by name');
select is(pgpm._child_nsp('re355_own.re355', :'e_cell'), 're355_own'::name,
  'E: the unanchored row resolves in the parent''s schema');
select is(pgpm.retire('re355_own.re355', :'e_cell'), true, 'E: retire() of the aged cell completes');
select ok(not exists (select 1 from pg_class where oid = :e_cell_oid)
          and exists (select 1 from pg_inherits where inhparent = 're355_own.re355'::regclass and inhrelid = :e_ops_oid)
          and (select string_agg(id::text, ',' order by id) from re355_own.re355 where id < 600 or id >= 9500) = '9505',
  'E: the partition in the parent''s schema is the one dropped; the namesake stands with its row');

-- ============================ PART G: the namesake in the parent's own schema ============================
create table public.rg355 (id bigint primary key, payload text);
insert into public.rg355 values (181, 'a'), (182, 'b');
call pgpm.transmute('public.rg355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rg355 values (600, 'frontier');
select child_name as g_cell from pgpm.part where parent_table = 'public.rg355'::regclass and lo = '100' \gset
-- fixture: an unanchored row, its partition dropped by hand, the operator's own table created under the name in the
-- parent's schema and attached over another range
update pgpm.part set child_oid = null where parent_table = 'public.rg355'::regclass and child_name = :'g_cell';
drop table public.:"g_cell";
create table public.:"g_cell" (id bigint primary key, payload text);
insert into public.:"g_cell" values (9801, 'operator'), (9802, 'operator');
alter table public.rg355 attach partition public.:"g_cell" for values from (9800) to (9900);
select to_regclass(format('public.%I', :'g_cell'))::oid as g_ops_oid \gset
select ok(pgpm._child_nsp('public.rg355', :'g_cell') = 'public'
          and exists (select 1 from pg_inherits where inhparent = 'public.rg355'::regclass and inhrelid = :g_ops_oid),
  'LIVENESS: G''s unanchored row resolves to the parent''s schema, where the name is the operator''s partition');
select pgpm._install_write_block('public.rg355', :'g_cell');
select ok(not exists (select 1 from pg_trigger where tgrelid = :g_ops_oid and tgname = 'pgpm_write_block')
          and exists (select 1 from pgpm.log where parent_table = 'public.rg355'::regclass and lo = '100'
                       and action = 'fail_write_block_identity'),
  'G: the write block is not put on the operator''s table (fail_write_block_identity)');
select is(pgpm.retire('public.rg355', :'g_cell'), false, 'G: retire() of the aged cell drops nothing');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rg355'::regclass and lo = '100'
                   and action = 'fail_retain_identity'),
  'G: refused as fail_retain_identity');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rg355'::regclass and inhrelid = :g_ops_oid)
          and (select string_agg(id::text, ',' order by id) from public.rg355 where id >= 9800) = '9801,9802',
  'G: the operator''s table stands, a partition with both its rows');
select lives_ok($$insert into public.rg355 values (9803, 'written')$$, 'G: and takes writes');

-- ============================ PART I: a moved int4 parent's unanchored row ============================
create schema ri355_old;
create schema ri355_new;
create table ri355_old.ri355 (id integer primary key, payload text);
insert into ri355_old.ri355 values (171, 'a'), (172, 'b');
call pgpm.transmute('ri355_old.ri355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into ri355_old.ri355 values (600, 'frontier');
select child_name as i_cell, child_oid as i_cell_oid from pgpm.part
 where parent_table = 'ri355_old.ri355'::regclass and lo = '100' \gset
update pgpm.part set child_oid = null where parent_table = 'ri355_old.ri355'::regclass and child_name = :'i_cell';
alter table ri355_old.ri355 set schema ri355_new;
select ok((select pg_get_expr(c.relpartbound, c.oid) from pg_class c where c.oid = :i_cell_oid) = 'FOR VALUES FROM (100) TO (200)'
          and exists (select 1 from pg_inherits where inhparent = 'ri355_new.ri355'::regclass and inhrelid = :i_cell_oid),
  'LIVENESS: I''s unanchored cell, bound bare, is a partition of the moved parent, left in the old schema');
select is(pgpm._child_nsp('ri355_new.ri355', :'i_cell'), 'ri355_old'::name,
  'I: _child_nsp finds it in its own schema by its range');
select is(pgpm.retire('ri355_new.ri355', :'i_cell'), true, 'I: retire() of the aged cell completes');
select ok(not exists (select 1 from pg_class where oid = :i_cell_oid)
          and (select string_agg(id::text, ',' order by id) from ri355_new.ri355) = '600',
  'I: the cell and its two rows are gone, the frontier row kept');

-- ============================ PART J: adopt_partition over a bare bound ============================
create table public.rj355 (id integer primary key, payload text);
insert into public.rj355 values (101, 'a');
call pgpm.transmute('public.rj355', 'id', 100, p_obtain => 4, p_paused => true);
insert into public.rj355 values (381, 'c');
select child_name as j_cell, child_oid as j_cell_oid from pgpm.part
 where parent_table = 'public.rj355'::regclass and lo = '300' \gset
delete from pgpm.part where parent_table = 'public.rj355'::regclass and lo = '300';
select ok((select pg_get_expr(c.relpartbound, c.oid) from pg_class c where c.oid = :j_cell_oid) = 'FOR VALUES FROM (300) TO (400)',
  'LIVENESS: J''s partition renders its bound bare, and pgpm.part has no row for it');
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 'public.rj355', 'public.' || :'j_cell'),
  'J: adopt_partition accepts it');
select is((select format('%s|%s|%s', lo, hi, child_oid = :j_cell_oid) from pgpm.part
            where parent_table = 'public.rj355'::regclass and child_name = :'j_cell'),
  '300|400|t', 'J: and records it over its bounds, by its oid');

-- ============================ PART N: the mark judged by retire() itself ============================
create table public.rn355 (id bigint primary key, payload text);
insert into public.rn355 values (191, 'a'), (192, 'b');
call pgpm.transmute('public.rn355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rn355 values (600, 'frontier');
select child_name as n_cell from pgpm.part where parent_table = 'public.rn355'::regclass and lo = '100' \gset
update pgpm.part set child_oid = null where parent_table = 'public.rn355'::regclass and child_name = :'n_cell';
drop table public.:"n_cell";
create table public.:"n_cell" (id bigint primary key, payload text);
insert into public.:"n_cell" values (9841, 'operator'), (9842, 'operator');
alter table public.rn355 attach partition public.:"n_cell" for values from (9840) to (9850);
-- the parent is referenced, so retirement takes the detach path
create table public.rn355_ref (id bigint primary key, f_id bigint references public.rn355 (id));
insert into public.rn355_ref values (1, 600);
select to_regclass(format('public.%I', :'n_cell'))::oid as n_ops_oid \gset
update pgpm.part set retiring_at = clock_timestamp(), retiring_oid = :n_ops_oid, detach_dispatched_oid = :n_ops_oid
 where parent_table = 'public.rn355'::regclass and child_name = :'n_cell';
update cron.job set command = pgpm._detach_cmd('public.rn355', 'public', :'n_cell') where jobname = 'pgpm_detach';
select coalesce(max(id), 0) as n_mark from pgpm.log \gset
select ok((select retiring_oid = :n_ops_oid from pgpm.part where parent_table = 'public.rn355'::regclass and child_name = :'n_cell'),
  'LIVENESS: N''s unanchored row carries a mark naming the operator''s table, no install run since');
select is(pgpm.retire('public.rn355', :'n_cell'), false, 'N: retire() returns false');
select ok((select retiring_at is null from pgpm.part where parent_table = 'public.rn355'::regclass and child_name = :'n_cell')
          and (select command from cron.job where jobname = 'pgpm_detach') = 'select 1'
          and exists (select 1 from pgpm.log where parent_table = 'public.rn355'::regclass and action = 'retain_disown' and id > :n_mark),
  'N: it disowned the mark (retain_disown) and disarmed the job');
select is(pgpm.retire('public.rn355', :'n_cell'), false, 'N: the next call takes nothing either');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rn355'::regclass and inhrelid = :n_ops_oid and not inhdetachpending)
          and (select string_agg(id::text, ',' order by id) from public.rn355 where id >= 9800) = '9841,9842'
          and not exists (select 1 from pgpm.log where parent_table = 'public.rn355'::regclass
                           and action in ('retain_detach', 'retain_drop') and id > :n_mark),
  'N: the operator''s table is still a partition with both its rows, nothing detached or dropped');
update cron.job set command = 'select 1' where jobname = 'pgpm_detach';

-- ============================ PART O: an unanchored row's own retirement completes ============================
create table public.ro355 (id bigint primary key, payload text);
insert into public.ro355 values (195, 'a'), (196, 'b');
call pgpm.transmute('public.ro355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.ro355 values (600, 'frontier');
create table public.ro355_ref (id bigint primary key, f_id bigint references public.ro355 (id));
insert into public.ro355_ref values (1, 600);
select child_name as o_cell, child_oid as o_cell_oid from pgpm.part
 where parent_table = 'public.ro355'::regclass and lo = '100' \gset
-- fixture: the row unanchored, as one whose partition was out of the parent when the upgrade ran and was attached
-- back on its own bounds since
update pgpm.part set child_oid = null where parent_table = 'public.ro355'::regclass and child_name = :'o_cell';
select coalesce(max(id), 0) as o_mark from pgpm.log \gset
select ok((select child_oid is null from pgpm.part where parent_table = 'public.ro355'::regclass and child_name = :'o_cell')
          and exists (select 1 from pg_inherits where inhparent = 'public.ro355'::regclass and inhrelid = :o_cell_oid),
  'LIVENESS: O''s row is unanchored and its own partition is attached on its range');
select is(pgpm.retire('public.ro355', :'o_cell'), false, 'LIVENESS: O: retire() takes the referenced path');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.ro355 detach partition public.%I concurrently', :'o_cell'),
  'LIVENESS: O: the job is armed with the partition''s own detach');
select is((select child_oid from pgpm.part where parent_table = 'public.ro355'::regclass and child_name = :'o_cell'),
  :'o_cell_oid'::oid, 'O: the mark anchored the row to the partition it retires');
select command from cron.job where jobname = 'pgpm_detach' \gexec
select ok(not exists (select 1 from pg_inherits where inhrelid = :o_cell_oid),
  'LIVENESS: O: the dispatched detach landed');
select is(pgpm.retire('public.ro355', :'o_cell'), true, 'O: the next retire() completes the retirement');
select ok(not exists (select 1 from pg_class where oid = :o_cell_oid)
          and not exists (select 1 from pgpm.part where parent_table = 'public.ro355'::regclass and child_name = :'o_cell'),
  'O: the partition and its row are gone');
select is((select string_agg(action, ',' order by id) from pgpm.log
            where parent_table = 'public.ro355'::regclass and lo = '100' and id > :o_mark
              and action in ('retain_detach', 'retain_drop', 'retain_disown', 'fail_retain_drop', 'fail_retain_identity')),
  'retain_detach,retain_drop', 'O: retain_detach then retain_drop, never disowned or refused');
select is((select string_agg(id::text, ',' order by id) from public.ro355), '600',
  'O: the table keeps its frontier row and retention took the cell''s two');

-- ============================ PART P: regrain's source for an unanchored row ============================
create table public.rp355 (id bigint primary key, payload text);
insert into public.rp355 values (321, 'a'), (322, 'b');
call pgpm.transmute('public.rp355', 'id', 100, p_obtain => 6, p_paused => true);
insert into public.rp355 values (650, 'frontier');
select child_name as p_cell from pgpm.part where parent_table = 'public.rp355'::regclass and lo = '300' and attached \gset
update pgpm.part set child_oid = null where parent_table = 'public.rp355'::regclass and child_name = :'p_cell';
drop table public.:"p_cell";
create table public.:"p_cell" (id bigint primary key, payload text);
insert into public.:"p_cell" values (9851, 'operator'), (9852, 'operator');
alter table public.rp355 attach partition public.:"p_cell" for values from (9850) to (9860);
select to_regclass(format('public.%I', :'p_cell'))::oid as p_ops_oid \gset
select ok((select child_oid is null from pgpm.part where parent_table = 'public.rp355'::regclass and child_name = :'p_cell')
          and exists (select 1 from pg_inherits where inhparent = 'public.rp355'::regclass and inhrelid = :p_ops_oid),
  'LIVENESS: P''s unanchored row''s name denotes the operator''s partition over [9850, 9860)');
select is(pgpm._part_rel('public.rp355', :'p_cell'), null::regclass, 'P: _part_rel withholds it from the row');
-- a refusal (a raise) is a correct outcome too: the assertions are on the operator's table
do $$ begin
  perform pgpm.regrain('public.rp355', (select child_name from pgpm.part
                        where parent_table = 'public.rp355'::regclass and lo = '300' and attached), '50');
exception when others then null;
end $$;
select ok(exists (select 1 from pg_class where oid = :p_ops_oid)
          and exists (select 1 from pg_inherits where inhparent = 'public.rp355'::regclass and inhrelid = :p_ops_oid)
          and (select string_agg(id::text, ',' order by id) from public.rp355 where id >= 9800) = '9851,9852',
  'P: after regrain() of the cell, the operator''s table is still a partition with both its rows');

-- ============================ PART Q: _is_write_blocked for an unanchored row ============================
create table public.rq355 (id bigint primary key, payload text);
insert into public.rq355 values (331, 'a');
call pgpm.transmute('public.rq355', 'id', 100, p_obtain => 6, p_paused => true);
insert into public.rq355 values (650, 'frontier');
select child_name as q_cell from pgpm.part where parent_table = 'public.rq355'::regclass and lo = '300' and attached \gset
update pgpm.part set child_oid = null where parent_table = 'public.rq355'::regclass and child_name = :'q_cell';
drop table public.:"q_cell";
create table public.:"q_cell" (id bigint primary key, payload text);
insert into public.:"q_cell" values (9861, 'operator');
alter table public.rq355 attach partition public.:"q_cell" for values from (9860) to (9870);
create trigger pgpm_write_block before insert or update or delete on public.:"q_cell"
  for each row execute function pgpm._write_block_raise();
alter table public.:"q_cell" enable always trigger pgpm_write_block;
select ok(exists (select 1 from pg_trigger where tgrelid = to_regclass(format('public.%I', :'q_cell'))
                   and tgname = 'pgpm_write_block' and tgenabled = 'A'),
  'LIVENESS: Q''s operator table under the row''s name carries a pgpm_write_block enabled ALWAYS');
select is(pgpm._is_write_blocked('public.rq355', :'q_cell'), false,
  'Q: it is not the row''s block: the row''s own partition is gone');

-- ============================ PART R: the stranger one level down ============================
create table public.rr355 (id bigint primary key, payload text);
insert into public.rr355 values (113, 'a'), (114, 'b');
call pgpm.transmute('public.rr355', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => true);
insert into public.rr355 values (650, 'frontier');
select child_name as r_cell from pgpm.part where parent_table = 'public.rr355'::regclass and lo = '100' and attached \gset
update pgpm.part set child_oid = null where parent_table = 'public.rr355'::regclass and child_name = :'r_cell';
drop table public.:"r_cell";
create table public.rr355_ops (id bigint primary key, payload text) partition by range (id);
alter table public.rr355 attach partition public.rr355_ops for values from (9000) to (10000);
create table public.:"r_cell" partition of public.rr355_ops for values from (9870) to (9880);
insert into public.rr355 values (9871, 'operator'), (9872, 'operator');
select to_regclass(format('public.%I', :'r_cell'))::oid as r_ops_oid \gset
select ok((select child_oid is null from pgpm.part where parent_table = 'public.rr355'::regclass and child_name = :'r_cell')
          and not exists (select 1 from pg_inherits where inhparent = 'public.rr355'::regclass and inhrelid = :r_ops_oid)
          and exists (select 1 from pg_partition_ancestors(:'r_ops_oid'::oid::regclass) a where a.relid = 'public.rr355'::regclass),
  'LIVENESS: R''s unanchored row''s name denotes a partition of the parent one level down, not a direct one');
select is(pgpm._part_rel('public.rr355', :'r_cell'), null::regclass, 'R: _part_rel withholds it from the row');
select is(pgpm.retire('public.rr355', :'r_cell'), false, 'R: retire() of the aged cell drops nothing');
select ok(exists (select 1 from pg_class where oid = :r_ops_oid)
          and (select string_agg(id::text, ',' order by id) from public.rr355 where id >= 9000) = '9871,9872',
  'R: the operator''s table stands under the parent with both its rows');

select * from finish();
