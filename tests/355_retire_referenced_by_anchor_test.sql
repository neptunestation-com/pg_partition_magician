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
--           record its oid, the job armed with its detach, every retire() refused fail_retain_identity) is cleared
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
--
-- ASYMMETRIC FIXTURES. A's cell [100, 200) holds ids 101 and 102, the operator's table one row (5005); B's dropped
-- cell held 2 rows, its namesake holds 7007, and the other parent's aged cell holds 3 rows (301, 302, 303). C's cell
-- holds 121 and 122, its namesake 8008; D's cell 131 and 132, its namesake 9009; E's cell 141 and 142, its namesake
-- 9505; F's dropped cell held 151 and 152, its namesake holds 9701 and 9702.
--
-- install.sql is re-run with \ir, relative to this file; the psql variable `install` overrides the path.
\if :{?install}
\else
\set install ../pgpm_core/install.sql
\endif
-- retire() is a function, not a committing procedure; no throws_* here.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(47);

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
select is(pgpm.retire('public.rcc355', :'cc_cell'), false, 'LIVENESS: C''s cell is refused before the upgrade');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rcc355'::regclass and lo = '100'
                   and action = 'fail_retain_identity')
          and (select command from cron.job where jobname = 'pgpm_detach')
              = pgpm._detach_cmd('public.rcc355', 'rcc355_ops', :'cc_cell'),
  'LIVENESS: refused as fail_retain_identity, the job still armed with the namesake''s detach');

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
select ok((select i.inhrelid from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.rd355'::regclass and c.relname = :'d_cell' limit 1) = :d_ops_oid
          and exists (select 1 from pg_inherits where inhparent = 'public.rd355'::regclass and inhrelid = :d_cell_oid),
  'LIVENESS: D''s two relations named the cell are partitions of the parent, the operator''s listed first by name');

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

-- the upgrade, over C's, D's and F's states
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

select * from finish();
