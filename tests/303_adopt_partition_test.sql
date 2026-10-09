-- pgpm.adopt_partition() re-records an attached partition pgpm's catalog has lost track of (issue #1082).
--
-- THE BUG. A partition restored from a dump under its own name is a new relation: same name, same rows, a new
-- oid. pgpm.part still records the old oid, so the write-block, archive and retire steps refuse it on identity
-- (fail_archive_identity) and, at archive_batch 1, retention stops behind it. The documented repair was to
-- delete the stale pgpm.part row. That clears the wedge, but the restored relation stays ATTACHED with its
-- rows and nothing records it any more: retention marches past its range and never archives or retires it,
-- so rows far below the horizon outlive the policy for good, and status().n_partitions stops counting it.
-- The other documented option, putting the intended relation back under the name, is not available after a
-- restore: the name already holds the restored relation, and the recorded one is gone.
--
-- THE CONTRACT.
--   PART A  the issue's own fixture, repaired with adopt_partition instead of the delete: the stale row is
--           re-anchored to the restored relation (same row, same bounds, the new oid), the coverage the OLD
--           relation earned is discarded rather than credited to the new one, and the next ticks archive the
--           restored partition from its own lo and retire it: its rows 1, 2 and 15 go, row 55 stays, and
--           status() counts every partition the table has.
--   PART B  the reproduction's own path: the stale row already DELETED (the old repair), then adopt_partition
--           records the partition afresh from the catalog's bounds, and retention reaches it (4, 6 and 18
--           go, 57 stays).
--   PART C  on a time grid, called under a DateStyle and TimeZone that render bounds unlike pgpm does, the
--           bounds recorded are the instants the catalog holds.
--   PART D  the refusals, each witnessed against an allowed call: a parent pgpm does not manage, a relation
--           that is not a partition of the parent, a partition pgpm already records, a range another row
--           records (until that row goes), a same-named row over another range, and bounds the grid cannot
--           express. A refusal writes no row.
--   PART E  the partition cannot be detached between the judgement and the commit: a second session's
--           DETACH waits on adopt_partition's transaction, and goes through once it commits.
--
-- adopt_partition is a function, not a committing procedure, so its refusals are pinned by message.
-- ASYMMETRIC FIXTURES. A's rows are 1, 2, 15, 25 and 55, B's 4, 6, 18, 22 and 57, so an assertion aimed at
-- the wrong table cannot pass; every check names the rows or the oid, never a count alone.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(32);

-- a partition restored from a dump under its own name: same rows, same write-block trigger, a new oid
create function pg_temp.t303_restore(p_parent regclass, p_child name, p_as name, p_lo text, p_hi text,
                                     p_trigger boolean)
returns void language plpgsql as $$
begin
  execute format('alter table %s detach partition public.%I', p_parent, p_child);
  execute format('create table public.%I (like public.%I including all)', p_child || '_r', p_child);
  execute format('insert into public.%I select * from public.%I', p_child || '_r', p_child);
  execute format('drop table public.%I', p_child);
  execute format('alter table public.%I rename to %I', p_child || '_r', p_as);
  if p_trigger then
    execute format('create trigger pgpm_write_block before insert or update or delete on public.%I
                      for each row execute function pgpm._write_block_raise()', p_as);
    execute format('alter table public.%I enable always trigger pgpm_write_block', p_as);
  end if;
  execute format('alter table %s attach partition public.%I for values from (%L) to (%L)',
                 p_parent, p_as, p_lo, p_hi);
end;
$$;

-- ============================================ PART A ============================================
create table public.t303a (id bigint primary key, payload text);
insert into public.t303a values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.t303a', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.t303a', '60');
insert into public.t303a values (25, 'd'), (55, 'frontier');
select pgpm.set_archive_fn('public.t303a', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
select child_name as a_old, child_oid as a_old_oid from pgpm.part
 where parent_table = 'public.t303a'::regclass and lo = '0' \gset
select pgpm._enforce_write_blocks('public.t303a');
-- coverage the OLD relation earned before the restore: one chunk, [0,2), row 1
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived)
  values ('public.t303a', '0', '2', :'a_old', 1);
select pg_temp.t303_restore('public.t303a', :'a_old', :'a_old', '0', '20', true);
select to_regclass('public.' || :'a_old')::oid as a_new_oid \gset

select pgpm._archive_step('public.t303a');
select is((select count(*)::int from pgpm.log where parent_table = 'public.t303a'::regclass
            and action = 'fail_archive_identity' and lo = '0' and hi = '20'), 1,
  'LIVENESS: A: the archive step is wedged on identity for [0,20)');
select isnt(:a_new_oid::oid, :a_old_oid::oid, 'LIVENESS: A: the restored relation is a new oid under the old name');

select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 'public.t303a', 'public.' || :'a_old'),
  'A: adopt_partition accepts the restored partition');
select is((select string_agg(format('%s|%s|%s|%s', child_name, lo, hi, child_oid = :a_new_oid::oid), ',')
             from pgpm.part where parent_table = 'public.t303a'::regclass and child_name = :'a_old'),
          format('%s|0|20|t', :'a_old'),
  'A: the stale row is re-anchored: same name, same bounds, the restored relation''s oid');
select is((select string_agg(method, ',') from pgpm.log where parent_table = 'public.t303a'::regclass
            and action = 'adopt_partition' and lo = '0' and hi = '20') like '%' || :a_old_oid || '%',
          true, 'A: logged adopt_partition, naming the oid it replaced');

call pgpm.maintain('public.t303a');
call pgpm.maintain('public.t303a');
call pgpm.maintain('public.t303a');
select is((select count(*)::int from pgpm.log where parent_table = 'public.t303a'::regclass
            and action = 'retain_drop' and lo = '20' and hi = '30'), 1,
  'LIVENESS: A: retention ran past [0,20) and dropped [20,30)');
select is((select string_agg(id::text, ',' order by id) from public.t303a), '55',
  'A: rows 1, 2 and 15 of the adopted partition are retired with 25; 55 stays');
select is((select count(*)::int from pgpm.log where parent_table = 'public.t303a'::regclass
            and action = 'retain_drop' and lo = '0' and hi = '20'), 1,
  'A: retention dropped the adopted partition [0,20)');
select is((select string_agg(format('%s:%s:%s', lo, hi, rows_archived), ',' order by lo::numeric)
             from pgpm.archive_ledger where parent_table = 'public.t303a'::regclass and child_name = :'a_old'),
          '0:20:3',
  'A: the restored partition was archived from its own lo, all three rows; the old relation''s [0,2) was not credited');
select is((select n_partitions from pgpm.status() where parent = 'public.t303a'::regclass),
          (select count(*) from pg_inherits where inhparent = 'public.t303a'::regclass),
  'A: status() counts every partition the table has');

-- ============================================ PART B ============================================
create table public.t303b (id bigint primary key, payload text);
insert into public.t303b values (4, 'a'), (6, 'b'), (18, 'c');
call pgpm.transmute('public.t303b', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.t303b', '60');
insert into public.t303b values (22, 'd'), (57, 'frontier');
select pgpm.set_archive_fn('public.t303b', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
select child_name as b_old from pgpm.part where parent_table = 'public.t303b'::regclass and lo = '0' \gset
select pgpm._enforce_write_blocks('public.t303b');
select pg_temp.t303_restore('public.t303b', :'b_old', :'b_old', '0', '20', true);
select pgpm._archive_step('public.t303b');
select is((select count(*)::int from pgpm.log where parent_table = 'public.t303b'::regclass
            and action = 'fail_archive_identity' and lo = '0'), 1,
  'LIVENESS: B: the archive step is wedged on identity for [0,20)');
-- the old repair: the stale row deleted, the restored relation left attached and untracked
delete from pgpm.part where parent_table = 'public.t303b'::regclass and child_name = :'b_old';
select is((select count(*)::int from pgpm.status() s where s.parent = 'public.t303b'::regclass
            and s.n_partitions < (select count(*) from pg_inherits where inhparent = 'public.t303b'::regclass)), 1,
  'LIVENESS: B: with the row deleted, status() undercounts the table''s partitions');

select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 'public.t303b', 'public.' || :'b_old'),
  'B: adopt_partition accepts the untracked partition');
select is((select string_agg(format('%s|%s|%s|%s', child_name, lo, hi,
                                    child_oid = to_regclass('public.' || :'b_old')::oid), ',')
             from pgpm.part where parent_table = 'public.t303b'::regclass and child_name = :'b_old'),
          format('%s|0|20|t', :'b_old'),
  'B: recorded afresh from the catalog''s bounds, anchored to the relation');
call pgpm.maintain('public.t303b');
call pgpm.maintain('public.t303b');
call pgpm.maintain('public.t303b');
select is((select string_agg(id::text, ',' order by id) from public.t303b), '57',
  'B: rows 4, 6 and 18 of the adopted partition are retired with 22; 57 stays');
select is((select n_partitions from pgpm.status() where parent = 'public.t303b'::regclass),
          (select count(*) from pg_inherits where inhparent = 'public.t303b'::regclass),
  'B: status() counts every partition the table has');

-- ============================================ PART C ============================================
create table public.t303c (ts timestamptz primary key);
insert into public.t303c values (now());
call pgpm.transmute('public.t303c', 'ts', interval '1 day');
select child_name as c_old, lo as c_lo, hi as c_hi from pgpm.part
 where parent_table = 'public.t303c'::regclass and lo::timestamptz > now() + interval '2 days'
 order by child_name limit 1 \gset
select pg_temp.t303_restore('public.t303c', :'c_old', :'c_old', :'c_lo', :'c_hi', false);
delete from pgpm.part where parent_table = 'public.t303c'::regclass and child_name = :'c_old';
set datestyle = 'SQL, DMY';
set timezone = 'Asia/Kolkata';
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 'public.t303c', 'public.' || :'c_old'),
  'C: adopt_partition accepts the partition under DateStyle SQL, DMY and TimeZone Asia/Kolkata');
reset datestyle;
reset timezone;
select is((select format('%s|%s|%s', lo::timestamptz = :'c_lo'::timestamptz, hi::timestamptz = :'c_hi'::timestamptz,
                         child_oid = to_regclass('public.' || :'c_old')::oid)
             from pgpm.part where parent_table = 'public.t303c'::regclass and child_name = :'c_old'),
          't|t|t',
  'C: the bounds recorded are the instants the catalog holds, whatever the caller''s DateStyle and TimeZone');

-- ============================================ PART D ============================================
create table public.t303_loose (id bigint primary key);
select throws_like(format('select pgpm.adopt_partition(%L, %L)', 'public.t303_loose', 'public.t303_loose'),
  '%t303_loose is not managed%', 'D: a parent pgpm does not manage is refused');
select throws_like(format('select pgpm.adopt_partition(%L, %L)', 'public.t303a', 'public.t303_loose'),
  '%t303_loose is not a partition of t303a%', 'D: a relation that is not a partition of the parent is refused');
select child_name as d_tracked from pgpm.part where parent_table = 'public.t303a'::regclass and lo = '50' \gset
select throws_like(format('select pgpm.adopt_partition(%L, %L)', 'public.t303a', 'public.' || :'d_tracked'),
  '%already records%', 'D: a partition pgpm already records is refused');

create table public.t303d (id bigint primary key);
insert into public.t303d values (3);
call pgpm.transmute('public.t303d', 'id', 10::bigint);
select pgpm.extend_to('public.t303d', '60');
insert into public.t303d values (13), (33);
select child_name as d_old from pgpm.part where parent_table = 'public.t303d'::regclass and lo = '0' \gset
-- restored under ANOTHER name: the stale row still records [0,10)
select pg_temp.t303_restore('public.t303d', :'d_old', 't303d_restored', '0', '10', false);
select throws_like(format('select pgpm.adopt_partition(%L, %L)', 'public.t303d', 'public.t303d_restored'),
  '%overlaps%' || :'d_old' || '%', 'D: a range another pgpm.part row records is refused, naming that row');
select is((select count(*)::int from pgpm.part where parent_table = 'public.t303d'::regclass
            and child_oid = 'public.t303d_restored'::regclass::oid), 0,
  'D: the refusal recorded nothing');
delete from pgpm.part where parent_table = 'public.t303d'::regclass and child_name = :'d_old';
select lives_ok($$select pgpm.adopt_partition('public.t303d', 'public.t303d_restored')$$,
  'D: once the stale row is gone, the same partition is adopted');
select is((select string_agg(format('%s|%s', lo, hi), ',') from pgpm.part
            where parent_table = 'public.t303d'::regclass and child_oid = 'public.t303d_restored'::regclass::oid),
          '0|10', 'D: adopted under its own name over the catalog''s [0,10)');

-- restored under the SAME name over a NARROWER range than the row records
select child_name as d_narrow from pgpm.part where parent_table = 'public.t303d'::regclass and lo = '10' \gset
select pg_temp.t303_restore('public.t303d', :'d_narrow', :'d_narrow', '10', '15', false);
select throws_like(format('select pgpm.adopt_partition(%L, %L)', 'public.t303d', 'public.' || :'d_narrow'),
  '%records ' || :'d_narrow' || ' over [10, 20)%', 'D: a same-named row over another range is refused');

-- a bound the grid cannot express
create table public.t303d_top (id bigint primary key);
alter table public.t303d attach partition public.t303d_top for values from (1000) to (maxvalue);
select throws_like($$select pgpm.adopt_partition('public.t303d', 'public.t303d_top')$$,
  '%bounds%', 'D: a MAXVALUE bound is refused');
select is((select count(*)::int from pgpm.part where parent_table = 'public.t303d'::regclass
            and child_oid in ('public.t303d_top'::regclass::oid, to_regclass('public.' || :'d_narrow')::oid)), 0,
  'D: neither refusal recorded anything');

-- ============================================ PART E ============================================
-- the partition cannot leave the table while adopt_partition's transaction is open: a second session's
-- DETACH waits on it (and gives up at its lock_timeout), and the same DETACH goes through once it commits
create table public.t303e (id bigint primary key);
insert into public.t303e values (7);
call pgpm.transmute('public.t303e', 'id', 10::bigint);
select pgpm.extend_to('public.t303e', '40');
insert into public.t303e values (24);
select child_name as e_old from pgpm.part where parent_table = 'public.t303e'::regclass and lo = '20' \gset
select pg_temp.t303_restore('public.t303e', :'e_old', :'e_old', '20', '30', false);
delete from pgpm.part where parent_table = 'public.t303e'::regclass and child_name = :'e_old';
select format('set lock_timeout = ''300ms''; alter table public.t303e detach partition public.%I', :'e_old') as e_detach \gset
begin;
select lives_ok(format('select pgpm.adopt_partition(%L, %L)', 'public.t303e', 'public.' || :'e_old'),
  'E: adopt_partition accepts the partition inside an open transaction');
select throws_like(format('select dblink_exec(%L, %L)', 'dbname=' || current_database(), :'e_detach'),
  '%lock timeout%', 'E: a second session''s DETACH of the partition waits on adopt_partition''s transaction');
commit;
select lives_ok(format('select dblink_exec(%L, %L)', 'dbname=' || current_database(), :'e_detach'),
  'LIVENESS: E: the same DETACH goes through once that transaction has committed');
select is((select count(*)::int from pg_inherits where inhparent = 'public.t303e'::regclass
            and inhrelid = to_regclass('public.' || :'e_old')), 0,
  'LIVENESS: E: and the partition did leave the table');

select * from finish();
