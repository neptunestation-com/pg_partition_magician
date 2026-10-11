-- retain()'s loop over retire() isolates each partition (issue #907).
--
-- THE BUG. retain() walked the eligible partitions oldest first and called retire() on each with no
-- exception scope of its own. retire() isolates its DROP, but not what comes before it: installing the
-- write block (CREATE TRIGGER, SHARE ROW EXCLUSIVE on the partition) raises on a lock timeout under
-- maintain()'s 200 ms lock_timeout. A VACUUM or ANALYZE of one aged partition holds SHARE UPDATE
-- EXCLUSIVE on it alone (autovacuum's included; an anti-wraparound one does not yield), so that raise
-- unwound the whole retain step into maintain()'s single handler and rolled back the DROPs retire() had
-- already completed for the OTHER aged partitions of the same call, which nothing held. One skip_retain
-- with no range was all the log said, and retention for the whole table stood still for as long as the
-- one partition stayed locked. _enforce_write_blocks (#360) and _archive_step (#833) already isolate
-- their children for exactly this reason.
--
-- THE CONTRACT. A raise out of retire() for one partition defers that partition alone: it is logged
-- skip_retain over its own [lo, hi) with the message in method, and every other partition of the call
-- is retired as if the raise had not happened. The next call takes the deferred one again.
--
-- TWO SESSIONS. The lock is held by a real second session (dblink), opened before the tick and committed
-- after the assertions that need it in force; every observation is its own statement, so its own
-- transaction, and none of them takes a lock the tick needs. The holder's lock is asserted both before
-- and after the tick, so the tick provably ran with it in force throughout.
--
-- ASYMMETRIC FIXTURE. Three aged partitions, the MIDDLE one held: [0, 10) holds three rows and is retired
-- before the held one, [20, 30) holds two and is retired after it (the loop goes on past a deferral), and
-- [10, 20) holds one and stays. The pre-fix code drops neither neighbour; a fix that stopped at the held
-- partition would drop [0, 10) but not [20, 30). The rows left say which partitions went, by id.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(14);

set client_min_messages = warning;

-- ======================================= fixture =======================================
-- step 10, retain 30. The monolith is [0, 10); obtain lays [10, 20) to [60, 70) ahead of it.
create table public.rl263 (id bigint primary key, payload text);
insert into public.rl263 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.rl263', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => false);
insert into public.rl263 values (15, 'held'), (21, 'x'), (22, 'y');

select child_name as p0  from pgpm.part where parent_table = 'public.rl263'::regclass and lo = '0'  \gset
select child_name as p10 from pgpm.part where parent_table = 'public.rl263'::regclass and lo = '10' \gset
select child_name as p20 from pgpm.part where parent_table = 'public.rl263'::regclass and lo = '20' \gset
select child_name as p30 from pgpm.part where parent_table = 'public.rl263'::regclass and lo = '30' \gset

-- the frontier moves to 65: horizon floor(65 - 30) = 30, so [0, 10), [10, 20) and [20, 30) are aged and
-- [30, 40) is not
insert into public.rl263 values (65, 'frontier');

select is((select string_agg(lo || '-' || hi, ',' order by lo::bigint) from pgpm.part
            where parent_table = 'public.rl263'::regclass and hi::bigint <= 30 and attached),
  '0-10,10-20,20-30',
  'fixture: three partitions are wholly past the horizon, oldest first: [0, 10), [10, 20), [20, 30)');
select is((select string_agg(tableoid::regclass::text || ':' || id, ',' order by id) from public.rl263),
  format('%s:1,%s:2,%s:3,%s:15,%s:21,%s:22,%s:65', :'p0', :'p0', :'p0', :'p10', :'p20', :'p20',
         (select child_name from pgpm.part where parent_table = 'public.rl263'::regclass and lo = '60')),
  'fixture: rows 1-3 sit in [0, 10), row 15 in [10, 20), rows 21-22 in [20, 30), the frontier row in [60, 70)');

-- =============================== the second session's lock ===============================
-- SHARE UPDATE EXCLUSIVE on [10, 20) alone: what a VACUUM or ANALYZE of that partition holds.
select dblink_connect('h263', 'dbname=' || current_database());
select dblink_exec('h263', 'begin');
select dblink_exec('h263', 'lock table public.' || quote_ident(:'p10') || ' in share update exclusive mode');
select * from dblink('h263', 'select pg_backend_pid()') as t(pid int) \gset h_

select is((select string_agg(relation::regclass::text || ':' || mode || ':' || granted, ',' order by relation::regclass::text)
             from pg_locks
            where pid = :h_pid and locktype = 'relation'
              and relation in ('public.rl263'::regclass, ('public.' || quote_ident(:'p0'))::regclass,
                               ('public.' || quote_ident(:'p10'))::regclass, ('public.' || quote_ident(:'p20'))::regclass)),
  :'p10' || ':ShareUpdateExclusiveLock:true',
  'LIVENESS: the second session holds SHARE UPDATE EXCLUSIVE on [10, 20), and nothing on the parent, [0, 10) or [20, 30)');

-- ======================================= the tick =======================================
call pgpm.maintain('public.rl263');

select is((select string_agg(mode || ':' || granted, ',') from pg_locks
            where pid = :h_pid and locktype = 'relation' and relation = ('public.' || quote_ident(:'p10'))::regclass),
  'ShareUpdateExclusiveLock:true',
  'LIVENESS: the second session still holds its lock after the tick, so the tick ran with it in force throughout');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.rl263'::regclass and action = 'skip_write_block' and hi = '20'
              and method like '%lock timeout%'),
  1, 'LIVENESS: the tick met the lock (the write-block step deferred [10, 20) on a lock timeout)');
select ok((select bool_and(to_regclass('public.' || quote_ident(c)) is null
                         or exists (select 1 from pg_trigger
                                     where tgrelid = to_regclass('public.' || quote_ident(c)) and tgname = 'pgpm_write_block'))
             from unnest(array[:'p0', :'p20']::name[]) c)
          and not exists (select 1 from pgpm.log
                           where parent_table = 'public.rl263'::regclass
                             and action in ('fail_retain_drop', 'fail_retain_identity', 'fail_retain_crossing',
                                            'fail_retain_detach', 'fail_write_block_identity')),
  'LIVENESS: [0, 10) and [20, 30) were write-blocked by the same tick (or dropped after it), and nothing refused either of them');

-- ===================================== the contract =====================================
select is(concat_ws('/',
            coalesce((select 'gone' where to_regclass('public.' || quote_ident(:'p0')) is null), 'there'),
            coalesce((select 'gone' where to_regclass('public.' || quote_ident(:'p10')) is null), 'there'),
            coalesce((select 'gone' where to_regclass('public.' || quote_ident(:'p20')) is null), 'there'),
            coalesce((select 'gone' where to_regclass('public.' || quote_ident(:'p30')) is null), 'there')),
  'gone/there/gone/there',
  'the tick retired [0, 10) and [20, 30), which nothing held, and kept the held [10, 20) and the unaged [30, 40)');
select is((select string_agg(lo, ',' order by id) from pgpm.log
            where parent_table = 'public.rl263'::regclass and action = 'retain_drop'),
  '0,20', 'retain_drop is logged for [0, 10) and for [20, 30), in that order, and for nothing else');
select is((select string_agg(id::text, ',' order by id) from public.rl263),
  '15,65', 'the rows left are the held partition''s (15) and the frontier''s (65): rows 1-3 and 21-22 went with their partitions');
select is((select string_agg(coalesce(lo, '-') || '/' || coalesce(hi, '-') || '/' || (method like '%lock timeout%')::text, ',' order by id)
             from pgpm.log where parent_table = 'public.rl263'::regclass and action = 'skip_retain'),
  '10/20/true',
  'the held partition alone is deferred: one skip_retain over [10, 20) carrying the lock timeout, and no step-level skip_retain');
select is((select attached::text from pgpm.part where parent_table = 'public.rl263'::regclass and lo = '10'),
  'true', 'the deferred partition is still tracked and attached, for the next tick');

-- =========================== released: the deferral is retried ===========================
select dblink_exec('h263', 'commit');
select dblink_disconnect('h263');

call pgpm.maintain('public.rl263');

select is((select string_agg(lo, ',' order by id) from pgpm.log
            where parent_table = 'public.rl263'::regclass and action = 'retain_drop'),
  '0,20,10', 'with the lock gone the next tick retires [10, 20)');
select is((select string_agg(id::text, ',' order by id) from public.rl263),
  '65', 'and only the frontier''s row is left');
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.rl263'::regclass and action = 'skip_retain'),
  1, 'the second tick deferred nothing: the first tick''s skip_retain over [10, 20) is still the only one');

select * from finish();
