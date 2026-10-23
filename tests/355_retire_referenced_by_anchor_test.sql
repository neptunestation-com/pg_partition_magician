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
--
-- ASYMMETRIC FIXTURES. A's cell [100, 200) holds ids 101 and 102, the operator's table one row (5005); B's dropped
-- cell held 2 rows, its namesake holds 7007, and the other parent's aged cell holds 3 rows (301, 302, 303).
-- retire() is a function, not a committing procedure; no throws_* here.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(21);

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

select * from finish();
