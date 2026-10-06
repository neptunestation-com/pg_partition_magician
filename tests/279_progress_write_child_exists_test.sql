-- progress() names as the write child only a partition that is built (issue #982).
--
-- THE BUG. progress() picked write_child, write_ceiling, freeze_margin and freeze_in from the pgpm.part row
-- alone. After the forward cell holding the frontier was dropped by hand (the #908 state: the partition
-- gone, its row still attached), it went on naming that partition as the one taking writes, with a healthy
-- freeze margin, while every write into the range was refused and status() (fixed by #908) no longer
-- counted it. reference.md: write_child is "null if the grid has fallen behind the frontier".
--
-- THE CONTRACT. progress() reads the rows status() reads (pgpm._part_built, one predicate for both).
--   1. A dropped cell that is NOT the frontier's leaves write_child where it was, by name, with its ceiling:
--      the filter removes the dead row, not every row.
--   2. With the frontier's own cell dropped, write_child, write_ceiling, freeze_margin and freeze_in are all
--      null.
--   3. With the frontier's cell DETACHED by hand instead (#956), the same: it no longer takes writes either.
-- A one-second grid, so the cell under now() is an empty forward cell obtain built, and the assertions run
-- in one transaction, so now() (a time grid's frontier) is one instant throughout.
create extension if not exists pgtap;
set client_min_messages = warning;

create table public.pg279 (ts timestamptz not null, body text);
insert into public.pg279 select now() - interval '1 hour', 'x';
call pgpm.transmute('public.pg279', 'ts', interval '1 second', 30, p_paused => false);
select pg_sleep(1.5);

begin;
select plan(14);

create temporary table cell279 on commit drop as
  select p.child_name, p.child_oid, p.lo, p.hi from pgpm.part p
   where p.parent_table = 'public.pg279'::regclass and p.attached
     and p.lo::timestamptz <= now() and now() < p.hi::timestamptz;
create temporary table next279 on commit drop as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.pg279'::regclass and p.attached
     and p.lo = (select hi from cell279);

select ok((select count(*) = 1 from cell279)
          and exists (select 1 from pg_inherits i join cell279 c on c.child_oid = i.inhrelid
                       where i.inhparent = 'public.pg279'::regclass),
  'LIVENESS: an obtain-built partition holds the frontier''s cell');
select ok(exists (select 1 from pg_inherits i join next279 c on c.child_oid = i.inhrelid),
  'LIVENESS: and the cell after it is built too');
select ok(not exists (select 1 from public.pg279 where ts >= now() - interval '1 second'),
  'LIVENESS: the frontier''s cell is empty, a forward cell');
select is((select write_child from pgpm.progress('public.pg279')), (select child_name from cell279),
  'LIVENESS: before anything is dropped, progress() names the frontier''s cell as the write child');

-- 1. the NEXT cell dropped by hand: the frontier's cell still takes writes
select format('drop table public.%I', child_name) from next279 \gexec
select ok(not exists (select 1 from pg_class c join next279 x on x.child_oid = c.oid),
  'LIVENESS: the next cell''s partition is gone');
select is((select write_child from pgpm.progress('public.pg279')), (select child_name from cell279),
  'with another cell dropped, progress() still names the frontier''s cell');
select is((select write_ceiling from pgpm.progress('public.pg279')), (select hi from cell279),
  'and its ceiling');

-- 2. the frontier's own cell dropped by hand
savepoint before_drop;
select format('drop table public.%I', child_name) from cell279 \gexec
select ok(not exists (select 1 from pg_class c join cell279 x on x.child_oid = c.oid)
          and exists (select 1 from pgpm.part p join cell279 x on x.child_oid = p.child_oid where p.attached),
  'LIVENESS: the frontier''s partition is gone, its pgpm.part row still attached');
select is((select write_child from pgpm.progress('public.pg279')), null,
  'progress() does not report a dropped partition as the write child');
select is((select array[write_ceiling, freeze_margin, freeze_in::text] from pgpm.progress('public.pg279')),
  array[null, null, null]::text[], 'nor its ceiling, freeze margin or freeze_in');
rollback to savepoint before_drop;

-- 3. the frontier's own cell detached by hand instead
select format('alter table public.pg279 detach partition public.%I', child_name) from cell279 \gexec
select ok(not exists (select 1 from pg_inherits i join cell279 x on x.child_oid = i.inhrelid)
          and exists (select 1 from pg_class c join cell279 x on x.child_oid = c.oid),
  'LIVENESS: the frontier''s partition is detached, its table kept');
select is((select retiring_at from pgpm.part p join cell279 x on x.child_oid = p.child_oid where p.attached), null,
  'LIVENESS: no retirement of pgpm''s own is in flight on it');
select is((select write_child from pgpm.progress('public.pg279')), null,
  'progress() does not report a hand-detached partition as the write child');
select is((select write_ceiling from pgpm.progress('public.pg279')), null,
  'nor its ceiling');

select * from finish();
rollback;
