-- retire() leaves a partition pending an operator's concurrent detach alone (issue #705, the pending-detach
-- site at retire()).
--
-- THE BUG. retire()'s #652 refusal (a partition detached by something other than retirement is the operator's
-- table: neither write-blocked nor dropped) asked pg_inherits whether the child was still a partition of the
-- parent without asking inhdetachpending. A DETACH PARTITION ... CONCURRENTLY sets that flag in a first
-- transaction that commits before it waits for the parent's older lockers, and a detacher whose session dies in
-- that wait leaves the partition there, pending, its rows already invisible through the parent. retire() took
-- it for attached: when retention had already write-blocked it, _install_write_block issued no ALTER (which
-- PostgreSQL refuses on an incomplete detach), and the next pgpm.maintain(parent) tick DROPPED the table the
-- operator was detaching to keep, rows and all (one-step path, part A). With an incoming FK it marked the
-- operator's detach as its own retirement (retiring_at), so once the detach was finished the next tick dropped
-- it all the same (referenced path, part B).
--
-- THE CONTRACT. A partition pending a concurrent detach that pgpm did not issue is never retired: retire()
-- returns false, logs skip_retain over its range with a method naming the pending detach and the remedy, and
-- changes nothing (no retiring_at, no drop). _detach_reap keeps its documented behaviour: it finishes the
-- abandoned detach and leaves the table standing, and from then on retire()'s #652 refusal (fail_retain_drop)
-- takes over. Parts A and B.
--
-- A RETIREMENT MARK VOUCHES ONLY WITH THE RECORD OF PGPM'S OWN DISPATCH (pgpm.part.detach_dispatched_oid, written
-- in the transaction in which the dispatch armed the pgpm_detach job). A mark without it on a pending or detached
-- partition is disowned (cleared, retain_disown): by retire() (parts D and G), by _detach_reap before it finishes the
-- detach (part E), by _retain_recall instead of re-attaching (part J), and by the pass every install runs (parts H,
-- C and K to M), which on an upgrade from an install older than the record disowns every such mark, pgpm's own
-- included (part C), whatever that install's retain_detach rows or pg_cron's run history say (K to M). A mark
-- with the record is pgpm's own retirement and is completed (part F), the operator's detach of such a partition
-- included (part I, #652's contract).
--
-- THE LOCK BEFORE THE QUESTION (#705 bullet 3). retire() locks the partition before it asks the catalog, so a
-- detach that starts while retire() is in flight cannot set its flag under it (part R).
--
-- Every poll is server-side, clears the pg_stat_activity snapshot each turn, and names its backends by
-- application_name within this database. bench/retire_pending_detach.sh runs this file against the mutations
-- that put each defect back.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

select plan(111);

-- The ids in a table, read by name and NULL when no such table exists, so an assertion about a relation the
-- defect dropped reports instead of killing the file.
create function pg_temp.rp327_ids(p_name text) returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  if to_regclass(format('public.%I', p_name)) is null then return null; end if;
  execute format('select array_agg(id order by id) from public.%I', p_name) into v;
  return v;
end $f$;

-- An operator's DETACH ... CONCURRENTLY of p_child (or p_cmd, the command pgpm's job is armed with), parked in
-- its wait phase on a REPEATABLE READ reader of the parent. Returns whether the detacher reached that wait (its
-- flag committed). The reader stays open on connection p_tag || '_r' and the detacher on p_tag || '_d', both
-- for rp327_kill_detach.
create function pg_temp.rp327_park_detach(p_parent text, p_child text, p_tag text, p_cmd text default null)
returns boolean language plpgsql as $f$
begin
  perform dblink_connect(p_tag || '_r', 'dbname=' || current_database() || ' application_name=' || p_tag || '_reader');
  perform dblink_connect(p_tag || '_d', 'dbname=' || current_database() || ' application_name=' || p_tag || '_detach');
  perform dblink_exec(p_tag || '_r', 'begin isolation level repeatable read');
  perform * from dblink(p_tag || '_r', format('select count(*) from public.%I', p_parent)) as t(n bigint);
  perform dblink_send_query(p_tag || '_d',
    coalesce(p_cmd, format('alter table public.%I detach partition public.%I concurrently', p_parent, p_child)));
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity
                where datname = current_database() and application_name = p_tag || '_detach'
                  and wait_event_type = 'Lock' and wait_event = 'virtualxid') then
      return true;
    end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $f$;

-- Kill the parked detacher, wait for its backend to leave, then end the reader. Returns whether it left: an
-- abandoned detach, not a live one.
create function pg_temp.rp327_kill_detach(p_tag text) returns boolean language plpgsql as $f$
declare v_gone boolean := false;
begin
  perform pg_terminate_backend(pid) from pg_stat_activity
    where datname = current_database() and application_name = p_tag || '_detach';
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if not exists (select 1 from pg_stat_activity
                    where datname = current_database() and application_name = p_tag || '_detach') then
      v_gone := true;
      exit;
    end if;
    perform pg_sleep(0.05);
  end loop;
  perform dblink_disconnect(p_tag || '_d');
  perform dblink_exec(p_tag || '_r', 'commit');
  perform dblink_disconnect(p_tag || '_r');
  return v_gone;
end $f$;

-- An operator's DETACH ... CONCURRENTLY that runs to completion, in a session of its own (it cannot run inside the
-- transaction block a pgTAP assertion is). Returns 'completed' or the error.
create function pg_temp.rp327_detach_concurrently(p_parent text, p_child text) returns text language plpgsql as $f$
begin
  perform dblink_connect('rp327_dc', 'dbname=' || current_database() || ' application_name=rp327_dc');
  perform dblink_exec('rp327_dc', format('alter table public.%I detach partition public.%I concurrently', p_parent, p_child));
  perform dblink_disconnect('rp327_dc');
  return 'completed';
exception when others then
  perform dblink_disconnect('rp327_dc');
  return 'ERROR: ' || sqlerrm;
end $f$;

-- ============================ (A) the one-step path, through pgpm.maintain(parent) ============================
-- [0, 100) holds 7, 42, 88; [100, 200) holds 150, 160 and is the one the operator detaches; [200, 300) holds 250.
create table public.rp327a (id bigint primary key, payload text);
insert into public.rp327a values (7, 'a'), (42, 'b'), (88, 'c');
call pgpm.transmute('public.rp327a', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327a values (150, 'kept1'), (160, 'kept2'), (250, 'f');
update pgpm.config set retain_batch = 1 where parent_table = 'public.rp327a'::regclass;
select child_name as a0   from pgpm.part where parent_table = 'public.rp327a'::regclass and lo = '0'   \gset
select child_name as a100 from pgpm.part where parent_table = 'public.rp327a'::regclass and lo = '100' \gset
select child_name as a200 from pgpm.part where parent_table = 'public.rp327a'::regclass and lo = '200' \gset

-- the frontier moves to 600, so retention reaches [0, 300); the tick write-blocks all three and, paced by
-- retain_batch, drops the oldest
insert into public.rp327a values (600, 'frontier');
call pgpm.maintain('public.rp327a');
select ok(to_regclass(format('public.%I', :'a0')) is null
          and pgpm._is_write_blocked('public.rp327a', :'a100') and pgpm._is_write_blocked('public.rp327a', :'a200'),
  'LIVENESS: A: [0, 100) was retired, [100, 200) and [200, 300) are write-blocked and wait their turn');

select ok(pg_temp.rp327_park_detach('rp327a', :'a100', 'rp327a'),
  'LIVENESS: A: the operator''s concurrent detach of [100, 200) is parked in its wait phase');
select ok(pg_temp.rp327_kill_detach('rp327a'),
  'LIVENESS: A: and its session is gone: an interrupted detach');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rp327a'::regclass
                   and inhrelid = to_regclass(format('public.%I', :'a100')) and inhdetachpending)
          and (select retiring_at is null from pgpm.part
                where parent_table = 'public.rp327a'::regclass and child_name = :'a100'),
  'LIVENESS: A: [100, 200) is left pending detach, and no retirement of pgpm''s is in flight on it');

-- the next per-table tick attempts both: the pending one first (oldest), then [200, 300)
update pgpm.config set retain_batch = 2 where parent_table = 'public.rp327a'::regclass;
call pgpm.maintain('public.rp327a');

select ok(to_regclass(format('public.%I', :'a200')) is null
          and exists (select 1 from pgpm.log where parent_table = 'public.rp327a'::regclass
                       and action = 'retain_drop' and lo = '200'),
  'LIVENESS: A: the same tick retired [200, 300), the partition behind the pending one');
select is(pg_temp.rp327_ids(:'a100'), array[150, 160]::bigint[],
  'A: the partition the operator was detaching is not dropped: rows 150 and 160 are still in it');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rp327a'::regclass
                   and inhrelid = to_regclass(format('public.%I', :'a100')) and inhdetachpending),
  'A: and it is still pending detach under rp327a: retirement changed nothing about it');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327a'::regclass
            and action = 'skip_retain' and lo = '100' and hi = '200'
            and method like '%pending a concurrent detach%_detach_reap%FINALIZE%'),
  1, 'A: the tick logged skip_retain over [100, 200), naming the pending detach and its remedy');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327a'::regclass
            and action = 'retain_drop' and lo = '100'),
  0, 'A: and no retain_drop for [100, 200)');

-- a direct retire(), the path an external assistant takes, refuses it the same way
select is(pgpm.retire('public.rp327a', :'a100'), false, 'A: a direct retire() of the pending partition returns false');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327a'::regclass
            and action = 'skip_retain' and lo = '100' and method like '%pending a concurrent detach%'),
  2, 'A: and logs its skip_retain again');
select is(pg_temp.rp327_ids(:'a100'), array[150, 160]::bigint[], 'A: rows 150 and 160 are still there');

-- _detach_reap finishes the abandoned detach and leaves the table standing; from then on it is the operator's
-- table, which #652's refusal leaves alone
select is(pgpm._detach_reap(), 1, 'A: _detach_reap finishes the abandoned detach');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327a'::regclass
            and action = 'detach_reap' and lo = '100'),
  1, 'A: logged detach_reap over [100, 200)');
select is((select relkind::text || '/' || relispartition::text from pg_class
            where oid = to_regclass(format('public.%I', :'a100'))), 'r/false',
  'A: the finished partition stands on its own');
call pgpm.maintain('public.rp327a');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327a'::regclass
            and action = 'fail_retain_drop' and lo = '100'
            and method like 'detached from the parent by something other than retirement%'),
  1, 'LIVENESS: A: the next tick reached it again, now refused as detached by hand (#652)');
select is(pg_temp.rp327_ids(:'a100'), array[150, 160]::bigint[],
  'A: and the operator''s table still holds rows 150 and 160');
select is(pg_temp.rp327_ids('rp327a'), array[600]::bigint[],
  'A: while the parent holds only the frontier row: [0, 100) and [200, 300) were retired, [100, 200) left it');

-- ============================ (B) the referenced path (an incoming FK) ============================
-- [100, 200) holds 110, 120, 130 and is the one the operator detaches; [200, 300) holds 210 and 220. A table
-- references the parent, so retire() takes the concurrent-detach path, which (no pgpm_detach job in this
-- database) marks retiring_at and logs fail_retain_detach.
create table public.rp327b (id bigint primary key, payload text);
insert into public.rp327b values (110, 'k1'), (120, 'k2'), (130, 'k3');
call pgpm.transmute('public.rp327b', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327b values (210, 'g'), (220, 'h');
create table public.rp327b_ref (id bigint primary key, b_id bigint references public.rp327b (id));
update pgpm.config set retain_batch = 2 where parent_table = 'public.rp327b'::regclass;
select child_name as b100 from pgpm.part where parent_table = 'public.rp327b'::regclass and lo = '100' \gset
select child_name as b200 from pgpm.part where parent_table = 'public.rp327b'::regclass and lo = '200' \gset
insert into public.rp327b values (600, 'frontier');
insert into public.rp327b_ref values (1, 600);   -- references the frontier row, past no horizon: no crossing

-- retention's write-block step runs ahead of the operator's detach, as maintain()'s does
select pgpm._enforce_write_blocks('public.rp327b');
select ok(pgpm._is_write_blocked('public.rp327b', :'b100') and pgpm._is_write_blocked('public.rp327b', :'b200'),
  'LIVENESS: B: [100, 200) and [200, 300) are write-blocked');

select ok(pg_temp.rp327_park_detach('rp327b', :'b100', 'rp327b'),
  'LIVENESS: B: the operator''s concurrent detach of [100, 200) is parked in its wait phase');
select ok(pg_temp.rp327_kill_detach('rp327b'),
  'LIVENESS: B: and its session is gone: an interrupted detach');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rp327b'::regclass
                   and inhrelid = to_regclass(format('public.%I', :'b100')) and inhdetachpending),
  'LIVENESS: B: [100, 200) is left pending detach');

call pgpm.maintain('public.rp327b');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rp327b'::regclass
            and action = 'fail_retain_detach'),
  'LIVENESS: B: the tick took retire()''s referenced path (its dispatch, with no pgpm_detach job here, failed)');
select is((select array_agg(lo order by lo::bigint) from pgpm.log where parent_table = 'public.rp327b'::regclass
            and action = 'fail_retain_detach'),
  array['200'], 'B: for [200, 300), the partition behind the pending one, and not for [100, 200)');
select is((select retiring_at is null from pgpm.part
            where parent_table = 'public.rp327b'::regclass and child_name = :'b100'),
  true, 'B: the operator''s pending detach is not taken for a retirement of pgpm''s (no retiring_at)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327b'::regclass
            and action = 'skip_retain' and lo = '100' and method like '%pending a concurrent detach%'),
  1, 'B: the tick logged skip_retain over [100, 200)');

-- the abandoned detach is finished, and the next tick leaves the operator's table standing
select is(pgpm._detach_reap(), 1, 'B: _detach_reap finishes the abandoned detach');
call pgpm.maintain('public.rp327b');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327b'::regclass
            and action = 'fail_retain_drop' and lo = '100'),
  1, 'LIVENESS: B: the next tick reached it again, now refused as detached by hand (#652)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327b'::regclass
            and action = 'retain_drop' and lo = '100'),
  0, 'B: and no retain_drop for [100, 200)');
select is(pg_temp.rp327_ids(:'b100'), array[110, 120, 130]::bigint[],
  'B: the operator''s table still holds rows 110, 120 and 130');
select is((select relkind::text || '/' || relispartition::text from pg_class
            where oid = to_regclass(format('public.%I', :'b100'))), 'r/false',
  'B: standing on its own');

-- ======================= (D) a mark with no dispatch record: retire() disowns it =======================
-- The state a pgpm older than the pending-detach refusal leaves on the referenced path (part B's defect): the
-- operator's pending detach stamped retiring_at as pgpm's own retirement, with no record of a dispatch of pgpm's
-- (pgpm.part.detach_dispatched_oid, which such an install did not have). [100, 200) holds 101 and 102, the operator's.
create table public.rp327d (id bigint primary key, payload text);
insert into public.rp327d values (101, 'd1'), (102, 'd2');
call pgpm.transmute('public.rp327d', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327d values (205, 'g'), (600, 'frontier');
create table public.rp327d_ref (id bigint primary key, d_id bigint references public.rp327d (id));
insert into public.rp327d_ref values (1, 600);
update pgpm.config set retain_batch = 1 where parent_table = 'public.rp327d'::regclass;
select child_name as d100 from pgpm.part where parent_table = 'public.rp327d'::regclass and lo = '100' \gset
select pgpm._enforce_write_blocks('public.rp327d');
select ok(pg_temp.rp327_park_detach('rp327d', :'d100', 'rp327d') and pg_temp.rp327_kill_detach('rp327d'),
  'LIVENESS: D: the operator''s concurrent detach of [100, 200) was parked in its wait phase and interrupted');
update pgpm.part set retiring_at = now() - interval '1 hour', retiring_oid = child_oid
 where parent_table = 'public.rp327d'::regclass and child_name = :'d100';
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rp327d'::regclass
                   and inhrelid = to_regclass(format('public.%I', :'d100')) and inhdetachpending)
          and (select retiring_at is not null from pgpm.part
                where parent_table = 'public.rp327d'::regclass and child_name = :'d100'),
  'LIVENESS: D: [100, 200) is pending the operator''s detach and carries a retirement mark');

call pgpm.maintain('public.rp327d');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327d'::regclass
            and action = 'retain_disown' and lo = '100' and method like 'retire() found%recorded no dispatch%'),
  1, 'D: the per-table tick disowned the mark (retain_disown, by retire())');
select is((select retiring_at is null and retiring_oid is null from pgpm.part
            where parent_table = 'public.rp327d'::regclass and child_name = :'d100'),
  true, 'D: and the mark is gone from pgpm.part');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327d'::regclass
            and action = 'skip_retain' and lo = '100'),
  1, 'D: the partition was refused, skip_retain');
select is(pgpm._detach_reap(), 1, 'LIVENESS: D: _detach_reap finishes the operator''s detach');
call pgpm.maintain('public.rp327d');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327d'::regclass
            and action = 'fail_retain_drop' and lo = '100'),
  1, 'LIVENESS: D: the next tick reached it again, now refused as detached by hand (#652)');
select is(pg_temp.rp327_ids(:'d100'), array[101, 102]::bigint[],
  'D: the operator''s table still holds rows 101 and 102');

-- ======================= (E) the same mark met by _detach_reap first, on the one-step path =======================
-- maintain_all reaps before its per-parent loop, so the reap must not finish the operator's detach under a mark
-- retire() would then honour. No incoming FK: the one-step path. [100, 200) holds 131, 132 and 133.
create table public.rp327e (id bigint primary key, payload text);
insert into public.rp327e values (131, 'e1'), (132, 'e2'), (133, 'e3');
call pgpm.transmute('public.rp327e', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327e values (600, 'frontier');
select child_name as e100 from pgpm.part where parent_table = 'public.rp327e'::regclass and lo = '100' \gset
select pgpm._enforce_write_blocks('public.rp327e');
select ok(pg_temp.rp327_park_detach('rp327e', :'e100', 'rp327e') and pg_temp.rp327_kill_detach('rp327e'),
  'LIVENESS: E: the operator''s concurrent detach of [100, 200) was parked in its wait phase and interrupted');
update pgpm.part set retiring_at = now() - interval '1 hour', retiring_oid = child_oid
 where parent_table = 'public.rp327e'::regclass and child_name = :'e100';
select is(pgpm._detach_reap(), 1, 'LIVENESS: E: _detach_reap finished the detach');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327e'::regclass
            and action = 'retain_disown' and lo = '100' and method like '\_detach\_reap found%recorded no dispatch%'),
  1, 'E: the reap disowned the mark before it finished the detach (retain_disown, by _detach_reap)');
call pgpm.maintain('public.rp327e');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327e'::regclass
            and action = 'fail_retain_drop' and lo = '100'),
  1, 'LIVENESS: E: the next tick reached it, refused as detached by hand (#652)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327e'::regclass
            and action = 'retain_drop' and lo = '100'),
  0, 'E: and did not drop it');
select is(pg_temp.rp327_ids(:'e100'), array[131, 132, 133]::bigint[],
  'E: the operator''s table still holds rows 131, 132 and 133');

-- ======================= (R) a detach that starts while retire() is in flight (#705 bullet 3) =======================
-- A direct retire() of [100, 200) is parked behind the regrain lock a regrain step of the same table holds, past
-- its catalog checks and before its DROP; an operator's DETACH ... CONCURRENTLY of the same partition starts
-- meanwhile. retire() holds SHARE UPDATE EXCLUSIVE on the partition from before its checks, so the detach's first
-- transaction cannot set its flag under it. Each then waits on the other, PostgreSQL cancels one, and either way
-- no partition pending a detach is dropped. [100, 200) holds 170 and 180.
create table public.rp327r (id bigint primary key, payload text);
insert into public.rp327r values (7, 'a');
call pgpm.transmute('public.rp327r', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327r values (170, 'r1'), (180, 'r2'), (600, 'frontier');
select child_name as r100 from pgpm.part where parent_table = 'public.rp327r'::regclass and lo = '100' \gset
select pgpm._enforce_write_blocks('public.rp327r');
create function pg_temp.rp327_waits(p_app text) returns boolean language plpgsql as $f$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where datname = current_database() and application_name = p_app
                  and wait_event_type = 'Lock') then
      return true;
    end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $f$;
create function pg_temp.rp327_result(p_conn text) returns text language plpgsql as $f$
declare v text;
begin
  select t.r into v from dblink_get_result(p_conn) as t(r text);
  return coalesce(v, '<no row>');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $f$;
insert into pgpm.regrain_lock (parent_table) values ('public.rp327r'::regclass) on conflict do nothing;
select dblink_connect('rb', 'dbname=' || current_database() || ' application_name=rp327r_regrain');
select dblink_exec('rb', 'begin');
select * from dblink('rb', $q$ select 1 from pgpm.regrain_lock where parent_table = 'public.rp327r'::regclass for update $q$) as t(x int);
select dblink_connect('ra', 'dbname=' || current_database() || ' application_name=rp327r_retire');
select dblink_send_query('ra', format($q$ select pgpm.retire('public.rp327r', %L)::text $q$, :'r100'));
select ok(pg_temp.rp327_waits('rp327r_retire'),
  'LIVENESS: R: retire() is parked on the regrain lock, past its catalog checks and before its DROP');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rp327r'::regclass
                   and inhrelid = to_regclass(format('public.%I', :'r100')) and not inhdetachpending),
  'LIVENESS: R: [100, 200) was attached, not pending, when retire() made its checks');
select dblink_connect('rc', 'dbname=' || current_database() || ' application_name=rp327r_detach');
select dblink_send_query('rc', format('alter table public.rp327r detach partition public.%I concurrently', :'r100'));
select ok(pg_temp.rp327_waits('rp327r_detach'), 'LIVENESS: R: the operator''s detach is waiting');
select (exists (select 1 from pg_inherits where inhparent = 'public.rp327r'::regclass
                 and inhrelid = to_regclass(format('public.%I', :'r100')) and inhdetachpending))::text as r_pending,
       (exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                 where a.datname = current_database() and a.application_name = 'rp327r_detach'
                   and l.locktype = 'relation' and l.relation = to_regclass(format('public.%I', :'r100'))::oid
                   and not l.granted))::text as r_blocked \gset
select ok(:'r_pending'::boolean or :'r_blocked'::boolean,
  format('LIVENESS: R: the detach contends with the retirement in flight (pending: %s, blocked on the partition: %s)',
         :'r_pending', :'r_blocked'));
select is(:'r_pending'::boolean, false,
  'R: the detach could not set its flag under the retirement in flight (it waits on the partition retire() locked)');
select dblink_exec('rb', 'commit');
select dblink_disconnect('rb');
select pg_temp.rp327_result('ra') as r_retire \gset
select pg_temp.rp327_result('rc') as r_detach \gset
select dblink_disconnect('ra');
select dblink_disconnect('rc');
select ok(:'r_retire' in ('true', 'false') or :'r_retire' like 'ERROR:%',
  format('LIVENESS: R: retire() ended (%s), and the detach ended (%s)', :'r_retire', :'r_detach'));
-- whichever was cancelled: never a table dropped under a flag
select ok(case when to_regclass(format('public.%I', :'r100')) is null
               then not :'r_pending'::boolean and :'r_retire' = 'true' and :'r_detach' like 'ERROR:%'
                    and exists (select 1 from pgpm.log where parent_table = 'public.rp327r'::regclass
                                 and action = 'retain_drop' and lo = '100')
               else pg_temp.rp327_ids(:'r100') = array[170, 180]::bigint[] end,
  format('R: either retire() dropped [100, 200) before any flag was set and the detach failed, or the table stands with rows 170 and 180 (table: %s, retire: %s, detach: %s)',
         coalesce(to_regclass(format('public.%I', :'r100'))::text, 'gone'), :'r_retire', :'r_detach'));

-- ======================= (G) a failed dispatch, then the operator's detach completes (no pg_cron) =======================
-- retire() stamps the mark before it dispatches, and with no pg_cron here the dispatch fails (fail_retain_detach):
-- pgpm asked nothing to detach the partition. The operator's DETACH ... CONCURRENTLY, to keep it, then completes,
-- leaving it detached under the mark, which must not read as pgpm's detach having landed. [100, 200) holds 161,
-- 162 and 163.
create table public.rp327g (id bigint primary key, payload text);
insert into public.rp327g values (161, 'g1'), (162, 'g2'), (163, 'g3');
call pgpm.transmute('public.rp327g', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327g values (600, 'frontier');
create table public.rp327g_ref (id bigint primary key, g_id bigint references public.rp327g (id));
insert into public.rp327g_ref values (1, 600);
update pgpm.config set retain_batch = 1 where parent_table = 'public.rp327g'::regclass;
select child_name as g100 from pgpm.part where parent_table = 'public.rp327g'::regclass and lo = '100' \gset
-- parts B and D left marks of their own on rp327b and rp327d, and one detach is in flight at a time database-wide
update pgpm.part set retiring_at = null, retiring_oid = null where parent_table <> 'public.rp327g'::regclass;
call pgpm.maintain('public.rp327g');
select ok((select retiring_at is not null from pgpm.part where parent_table = 'public.rp327g'::regclass and child_name = :'g100')
          and exists (select 1 from pgpm.log where parent_table = 'public.rp327g'::regclass and action = 'fail_retain_detach' and lo = '100')
          and not exists (select 1 from pgpm.log where parent_table = 'public.rp327g'::regclass and action = 'retain_detach'),
  'LIVENESS: G: retire() stamped [100, 200) and its dispatch failed: pgpm issued no detach');
select is(pg_temp.rp327_detach_concurrently('rp327g', :'g100'), 'completed',
  'LIVENESS: G: the operator''s concurrent detach of [100, 200) completes');
select ok((select not relispartition from pg_class where oid = to_regclass(format('public.%I', :'g100')))
          and (select retiring_at is not null from pgpm.part where parent_table = 'public.rp327g'::regclass and child_name = :'g100'),
  'LIVENESS: G: [100, 200) is detached under the mark');
call pgpm.maintain('public.rp327g');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327g'::regclass
            and action = 'retain_disown' and lo = '100' and method like 'retire() found%detached under a retirement mark%'),
  1, 'G: retire() disowned the mark: nothing records that pgpm''s dispatch took it out');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327g'::regclass
            and action = 'fail_retain_drop' and lo = '100'),
  1, 'G: and refused the partition as detached by hand (#652)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327g'::regclass
            and action = 'retain_drop' and lo = '100'),
  0, 'G: no retain_drop for [100, 200)');
select is(pg_temp.rp327_ids(:'g100'), array[161, 162, 163]::bigint[],
  'G: the operator''s table still holds rows 161, 162 and 163');

-- ======================= (H) marks an older pgpm left on detached partitions: the install's pass =======================
-- The upgrade from an install older than the refusal: an older pgpm adopted the operator's pending detach of each
-- partition (stamped it; its dispatch failed, no pg_cron), and the detach was finished before the upgrade, so the
-- partition is DETACHED under the mark. One of the two rows has no recorded oid, as a row the #421 backfill could not
-- anchor. The install's pass (pgpm._disown_unvouched_retirements, which install.sql runs) must disown both.
-- [100, 200) holds 171 and 172; [200, 300) holds 271, 272 and 273.
create table public.rp327h (id bigint primary key, payload text);
insert into public.rp327h values (171, 'h1'), (172, 'h2');
call pgpm.transmute('public.rp327h', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327h values (271, 'i1'), (272, 'i2'), (273, 'i3'), (600, 'frontier');
create table public.rp327h_ref (id bigint primary key, h_id bigint references public.rp327h (id));
insert into public.rp327h_ref values (1, 600);
select child_name as h100 from pgpm.part where parent_table = 'public.rp327h'::regclass and lo = '100' \gset
select child_name as h200 from pgpm.part where parent_table = 'public.rp327h'::regclass and lo = '200' \gset
update pgpm.part set retiring_at = now() - interval '1 hour', retiring_oid = child_oid
 where parent_table = 'public.rp327h'::regclass and lo in ('100', '200');
insert into pgpm.log (parent_table, action, lo, hi, method)
  select 'public.rp327h'::regclass, 'fail_retain_detach', lo, hi, 'relation "cron.job" does not exist'
    from pgpm.part where parent_table = 'public.rp327h'::regclass and lo in ('100', '200');
select format('alter table public.rp327h detach partition public.%I', :'h100') \gexec
select format('alter table public.rp327h detach partition public.%I', :'h200') \gexec
update pgpm.part set child_oid = null where parent_table = 'public.rp327h'::regclass and lo = '200';
select ok((select count(*) = 2 from pgpm.part p join pg_class c on c.relname = p.child_name
            where p.parent_table = 'public.rp327h'::regclass and p.retiring_at is not null and not c.relispartition)
          and (select child_oid is null from pgpm.part where parent_table = 'public.rp327h'::regclass and lo = '200'),
  'LIVENESS: H: both partitions are detached under a mark, and [200, 300)''s row has no recorded oid');
select is(pgpm._disown_unvouched_retirements(), 2, 'H: the install''s pass disowns both marks');
select is((select array_agg(lo order by lo::int) from pgpm.log where parent_table = 'public.rp327h'::regclass
            and action = 'retain_disown' and method like '%is detached from the parent under a retirement mark for which pgpm recorded no dispatch%'),
  array['100', '200'], 'H: logged retain_disown once for each, by range');
update pgpm.config set retain_batch = null where parent_table = 'public.rp327h'::regclass;
call pgpm.maintain('public.rp327h');
select is((select array_agg(lo order by lo::int) from pgpm.log where parent_table = 'public.rp327h'::regclass
            and action = 'fail_retain_drop'),
  array['100', '200'], 'LIVENESS: H: the next tick reached both, refused as detached by hand (#652)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327h'::regclass and action = 'retain_drop'),
  0, 'H: and dropped neither');
select is(pg_temp.rp327_ids(:'h100') || pg_temp.rp327_ids(:'h200'), array[171, 172, 271, 272, 273]::bigint[],
  'H: the tables still hold rows 171, 172 and 271 to 273');

-- ======================= (C) pgpm's own pending retirement, and the upgrade that cannot vouch for it =======================
-- From here the database has a stand-in for pg_cron's job table and its run history, as tests/194 has, so retire()
-- arms the pgpm_detach job and records its dispatch (pgpm.part.detach_dispatched_oid).
create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');
create table cron.job_run_details (jobid bigint, runid bigserial, command text, status text, start_time timestamptz);
-- part B left [200, 300) of rp327b marked as a retirement in flight (its dispatch failed), and one detach is in
-- flight at a time database-wide, so rp327c's would yield to it; it is taken out of the way
update pgpm.part set retiring_at = null, retiring_oid = null where parent_table = 'public.rp327b'::regclass;

-- [100, 200) holds 141 to 144; an incoming FK puts it on the referenced path. retire() stamps it, arms the job with
-- its detach and records the dispatch, and the run of that command is interrupted in its wait phase.
create table public.rp327c (id bigint primary key, payload text);
insert into public.rp327c values (141, 'c1'), (142, 'c2'), (143, 'c3'), (144, 'c4');
call pgpm.transmute('public.rp327c', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327c values (251, 'f1'), (252, 'f2'), (600, 'frontier');   -- [200, 300) is part F's
create table public.rp327c_ref (id bigint primary key, c_id bigint references public.rp327c (id));
insert into public.rp327c_ref values (1, 600);
update pgpm.config set retain_batch = 1 where parent_table = 'public.rp327c'::regclass;
select child_name as c100 from pgpm.part where parent_table = 'public.rp327c'::regclass and lo = '100' \gset
call pgpm.maintain('public.rp327c');
select command as c_cmd from cron.job where jobname = 'pgpm_detach' \gset
select ok(:'c_cmd' = pgpm._detach_cmd('public.rp327c', 'public', :'c100')
          and (select retiring_at is not null and detach_dispatched_oid = to_regclass(format('public.%I', :'c100'))::oid
                 from pgpm.part where parent_table = 'public.rp327c'::regclass and child_name = :'c100'),
  'LIVENESS: C: [100, 200) carries a retirement mark, its dispatch recorded by oid and the job armed with it');
select ok(pg_temp.rp327_park_detach('rp327c', :'c100', 'rp327c', :'c_cmd') and pg_temp.rp327_kill_detach('rp327c'),
  'LIVENESS: C: the armed detach was parked in its wait phase and interrupted');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.rp327c'::regclass
                   and inhrelid = to_regclass(format('public.%I', :'c100')) and inhdetachpending),
  'LIVENESS: C: [100, 200) is pending, its mark and its dispatch record carried');

-- on an install that records dispatches, the record vouches for the mark: nothing is disowned
select is(pgpm._disown_unvouched_retirements(), 0, 'C: a current install''s pass disowns no mark whose dispatch it recorded');
call pgpm.maintain('public.rp327c');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327c'::regclass
            and action in ('retain_disown', 'skip_retain') and lo = '100'),
  0, 'C: and retire() takes the pending detach for its own (no retain_disown, no skip_retain)');

-- the upgrade from an install older than the record: the column it adds is empty on every row, which is what
-- this sets, and install.sql then runs the pass. pgpm's own retirement and an adopted operator's detach cannot be
-- told apart by anything such an install wrote, so the mark is disowned and the table left to the operator.
update pgpm.part set detach_dispatched_oid = null where parent_table = 'public.rp327c'::regclass and child_name = :'c100';
select is(pgpm._disown_unvouched_retirements(), 1, 'C: the upgrade''s pass disowns the mark it has no record for');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327c'::regclass
            and action = 'retain_disown' and lo = '100'
            and method like '%pending a concurrent detach under a retirement mark for which pgpm recorded no dispatch%drop the table by hand%attach it back%'),
  1, 'C: logged once, retain_disown, with the remedy');
select is((select command from cron.job where jobname = 'pgpm_detach'), 'select 1',
  'C: the pgpm_detach job is disarmed, so it does not run the detach again');
select is(pgpm._detach_reap(), 1, 'LIVENESS: C: _detach_reap finished the detach');
call pgpm.maintain('public.rp327c');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327c'::regclass
            and action = 'fail_retain_drop' and lo = '100'),
  1, 'LIVENESS: C: the next tick reached it, refused as detached by hand (#652)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327c'::regclass
            and action = 'retain_drop' and lo = '100'),
  0, 'C: no tick dropped it');
select is(pg_temp.rp327_ids(:'c100'), array[141, 142, 143, 144]::bigint[],
  'C: the table still holds rows 141 to 144');

-- ======================= (F) pgpm's own interrupted detach is still completed =======================
-- The control for (C), (D) and (E): the same pending state under a mark whose dispatch is recorded, with no upgrade
-- in between, is pgpm's own retirement and ends in the DROP, whatever pg_cron's run history says of the interrupted
-- run (here: failed, as a terminated backend or a restart leaves it). [200, 300) of rp327c holds 251 and 252.
select child_name as c200 from pgpm.part where parent_table = 'public.rp327c'::regclass and lo = '200' \gset
update pgpm.config set retain_batch = 2 where parent_table = 'public.rp327c'::regclass;
call pgpm.maintain('public.rp327c');
select command as f_cmd from cron.job where jobname = 'pgpm_detach' \gset
select ok(:'f_cmd' = pgpm._detach_cmd('public.rp327c', 'public', :'c200'),
  'LIVENESS: F: retire() armed the pgpm_detach job with [200, 300)''s detach');
select ok(pg_temp.rp327_park_detach('rp327c', :'c200', 'rp327f', :'f_cmd') and pg_temp.rp327_kill_detach('rp327f'),
  'LIVENESS: F: pgpm''s own detach was parked in its wait phase and interrupted');
-- pg_cron records the interrupted run failed, as a terminated backend or a restart leaves it
insert into cron.job_run_details (jobid, command, status, start_time) values (1, :'f_cmd', 'failed', clock_timestamp());
select ok((select count(*) = 1 and bool_and(status = 'failed') from cron.job_run_details where command = :'f_cmd')
          and (select detach_dispatched_oid = to_regclass(format('public.%I', :'c200'))::oid from pgpm.part
                where parent_table = 'public.rp327c'::regclass and child_name = :'c200'),
  'LIVENESS: F: its run is recorded failed, and its dispatch recorded by the partition''s oid');
call pgpm.maintain('public.rp327c');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327c'::regclass
            and action in ('retain_disown', 'skip_retain') and lo = '200'),
  0, 'F: a tick while it is pending neither disowns nor refuses it');
select is(pgpm._detach_reap(), 1, 'LIVENESS: F: _detach_reap finished it');
call pgpm.maintain('public.rp327c');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327c'::regclass
            and action = 'retain_drop' and lo = '200'),
  1, 'F: the next tick completed pgpm''s own retirement: retain_drop for [200, 300)');
select ok(to_regclass(format('public.%I', :'c200')) is null, 'F: the partition is gone');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327c'::regclass
            and action = 'retain_disown' and lo = '200'),
  0, 'F: and nothing disowned it');

-- ======================= (I) the operator detaches a partition pgpm had already dispatched a detach for =======================
-- After the fix that is intervening in pgpm's own retirement, #652's contract: the partition is dropped when the
-- retirement completes. Whatever pg_cron's run history says (here every run failed): it is not read.
-- [100, 200) holds 181 and 182.
create table public.rp327i (id bigint primary key, payload text);
insert into public.rp327i values (181, 'i1'), (182, 'i2');
call pgpm.transmute('public.rp327i', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327i values (600, 'frontier');
create table public.rp327i_ref (id bigint primary key, i_id bigint references public.rp327i (id));
insert into public.rp327i_ref values (1, 600);
update pgpm.config set retain_batch = 1 where parent_table = 'public.rp327i'::regclass;
select child_name as i100 from pgpm.part where parent_table = 'public.rp327i'::regclass and lo = '100' \gset
call pgpm.maintain('public.rp327i');
select command as i_cmd from cron.job where jobname = 'pgpm_detach' \gset
select ok(:'i_cmd' = pgpm._detach_cmd('public.rp327i', 'public', :'i100')
          and (select detach_dispatched_oid is not null from pgpm.part
                where parent_table = 'public.rp327i'::regclass and child_name = :'i100'),
  'LIVENESS: I: retire() stamped [100, 200), armed the job with its detach and recorded the dispatch');
insert into cron.job_run_details (jobid, command, status, start_time)
  values (1, :'i_cmd', 'failed', clock_timestamp()), (1, :'i_cmd', 'failed', clock_timestamp());
select is(pg_temp.rp327_detach_concurrently('rp327i', :'i100'), 'completed',
  'LIVENESS: I: the operator''s concurrent detach of [100, 200) completes');
call pgpm.maintain('public.rp327i');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327i'::regclass
            and action = 'retain_drop' and lo = '100'),
  1, 'I: pgpm''s retirement completed: retain_drop for [100, 200)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327i'::regclass
            and action = 'retain_disown' and lo = '100'),
  0, 'I: and nothing disowned it');

-- ======================= (J) _retain_recall does not re-attach a detach pgpm did not dispatch =======================
-- A mark with no dispatch record (as an upgrade from an install older than the record leaves every mark) on a
-- partition the operator detached, and retention then stops reaching it (set_retain loosens it): the recall's
-- "dispatched detach landed" branch used to re-attach it into the table. [100, 200) holds 191, 192 and 193.
create table public.rp327j (id bigint primary key, payload text);
insert into public.rp327j values (191, 'j1'), (192, 'j2'), (193, 'j3');
call pgpm.transmute('public.rp327j', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327j values (600, 'frontier');
create table public.rp327j_ref (id bigint primary key, j_id bigint references public.rp327j (id));
insert into public.rp327j_ref values (1, 600);
update pgpm.config set retain_batch = 1 where parent_table = 'public.rp327j'::regclass;
select child_name as j100 from pgpm.part where parent_table = 'public.rp327j'::regclass and lo = '100' \gset
call pgpm.maintain('public.rp327j');
select command as j_cmd from cron.job where jobname = 'pgpm_detach' \gset
update pgpm.part set detach_dispatched_oid = null where parent_table = 'public.rp327j'::regclass and child_name = :'j100';
select ok(:'j_cmd' = pgpm._detach_cmd('public.rp327j', 'public', :'j100')
          and (select retiring_at is not null and detach_dispatched_oid is null from pgpm.part
                where parent_table = 'public.rp327j'::regclass and child_name = :'j100'),
  'LIVENESS: J: [100, 200) carries a mark with no dispatch record, the job armed with its detach');
select lives_ok(format('alter table public.rp327j detach partition public.%I', :'j100'),
  'LIVENESS: J: the operator detaches [100, 200)');
select pgpm.set_retain('public.rp327j', '1000');
call pgpm.maintain('public.rp327j');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rp327j'::regclass and action = 'retain_disown'
                   and lo = '100' and method like 'retention no longer reaches%'),
  'J: the recall disowned the mark');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327j'::regclass
            and action = 'retain_reattach' and lo = '100'),
  0, 'J: and did not re-attach the operator''s table');
select is((select relispartition::text from pg_class where oid = to_regclass(format('public.%I', :'j100'))), 'false',
  'J: which stands on its own');
select is(pg_temp.rp327_ids(:'j100'), array[191, 192, 193]::bigint[], 'J: holding rows 191, 192 and 193');

-- ======================= (K, L, M) an adopted mark, finished before the upgrade: nothing old vouches =======================
-- The state an install older than the dispatch record leaves when it adopted an operator's pending detach of a
-- referenced partition: retiring_at stamped, the job armed with the detach and retain_detach logged in that
-- transaction (exactly as for its own), the operator's detach then finished. The upgrade adds the record empty.
-- Whatever pg_cron's run history holds, the pass disowns the mark:
--   K  no history at all (cron.log_run off, or purged);
--   L  history that records the failed runs, but cannot be read by the maintainer (here: not there to read);
--   M  history that records the failed runs under the command's text, and the parent renamed since.
create table public.rp327k (id bigint primary key, payload text);
insert into public.rp327k values (101, 'k1'), (102, 'k2'), (103, 'k3');
call pgpm.transmute('public.rp327k', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327k values (600, 'frontier');
create table public.rp327k_ref (id bigint primary key, k_id bigint references public.rp327k (id));
insert into public.rp327k_ref values (1, 600);
create table public.rp327l (id bigint primary key, payload text);
insert into public.rp327l values (111, 'l1'), (112, 'l2');
call pgpm.transmute('public.rp327l', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327l values (600, 'frontier');
create table public.rp327l_ref (id bigint primary key, l_id bigint references public.rp327l (id));
insert into public.rp327l_ref values (1, 600);
create table public.rp327m (id bigint primary key, payload text);
insert into public.rp327m values (121, 'm1'), (122, 'm2'), (123, 'm3'), (124, 'm4');
call pgpm.transmute('public.rp327m', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327m values (600, 'frontier');
create table public.rp327m_ref (id bigint primary key, m_id bigint references public.rp327m (id));
insert into public.rp327m_ref values (1, 600);
update pgpm.config set retain_batch = 1 where parent_table in ('public.rp327k'::regclass, 'public.rp327l'::regclass, 'public.rp327m'::regclass);
select child_name as k100 from pgpm.part where parent_table = 'public.rp327k'::regclass and lo = '100' \gset
select child_name as l100 from pgpm.part where parent_table = 'public.rp327l'::regclass and lo = '100' \gset
select child_name as m100 from pgpm.part where parent_table = 'public.rp327m'::regclass and lo = '100' \gset
-- each retired in turn as far as the dispatch (one detach in flight at a time), then detached by hand, so the next
-- can be dispatched; each record then emptied, as the upgrade's added column leaves it
select ok(not pgpm.retire('public.rp327k', :'k100'), 'fixture: K: dispatched');
select format('alter table public.rp327k detach partition public.%I', :'k100') \gexec
select ok(not pgpm.retire('public.rp327l', :'l100'), 'fixture: L: dispatched');
select command as l_cmd from cron.job where jobname = 'pgpm_detach' \gset
select format('alter table public.rp327l detach partition public.%I', :'l100') \gexec
select ok(not pgpm.retire('public.rp327m', :'m100'), 'fixture: M: dispatched');
select command as m_cmd from cron.job where jobname = 'pgpm_detach' \gset
select format('alter table public.rp327m detach partition public.%I', :'m100') \gexec
update pgpm.part set detach_dispatched_oid = null
 where parent_table in ('public.rp327k'::regclass, 'public.rp327l'::regclass, 'public.rp327m'::regclass) and lo = '100';
insert into cron.job_run_details (jobid, command, status, start_time)
  values (1, :'l_cmd', 'failed', clock_timestamp()), (1, :'m_cmd', 'failed', clock_timestamp());
select ok((select count(*) = 3 from pgpm.part p join pg_class c on c.relname = p.child_name
            where p.parent_table in ('public.rp327k'::regclass, 'public.rp327l'::regclass, 'public.rp327m'::regclass)
              and p.lo = '100' and p.retiring_at is not null and p.detach_dispatched_oid is null and not c.relispartition)
          and (select count(*) = 3 from pgpm.log where action = 'retain_detach' and lo = '100'
                and parent_table in ('public.rp327k'::regclass, 'public.rp327l'::regclass, 'public.rp327m'::regclass)),
  'LIVENESS: K, L, M: each partition is detached under a mark with retain_detach logged and no dispatch record');
select is((select count(*)::int from cron.job_run_details where command = :'l_cmd' or command = :'m_cmd'), 2,
  'LIVENESS: L, M: the history records a failed run of each of their detaches');
alter table cron.job_run_details rename to job_run_details_hidden;   -- L: not there to read
alter table public.rp327m rename to rp327m_renamed;                  -- M: the parent renamed since
select is(pgpm._disown_unvouched_retirements(), 3, 'K, L, M: the upgrade''s pass disowns all three marks');
alter table cron.job_run_details_hidden rename to job_run_details;
select is((select array_agg(parent_table::text order by parent_table::text) from pgpm.log
            where action = 'retain_disown' and lo = '100'
              and parent_table in ('public.rp327k'::regclass, 'public.rp327l'::regclass, 'public.rp327m_renamed'::regclass)),
  array['rp327k', 'rp327l', 'rp327m_renamed'], 'K, L, M: logged retain_disown once for each');
call pgpm.maintain('public.rp327k');
call pgpm.maintain('public.rp327l');
call pgpm.maintain('public.rp327m_renamed');
select is((select count(*)::int from pgpm.log where action = 'retain_drop' and lo = '100'
            and parent_table in ('public.rp327k'::regclass, 'public.rp327l'::regclass, 'public.rp327m_renamed'::regclass)),
  0, 'K, L, M: no tick dropped any of them');
select is((select count(*)::int from pgpm.log where action = 'fail_retain_drop' and lo = '100'
            and parent_table in ('public.rp327k'::regclass, 'public.rp327l'::regclass, 'public.rp327m_renamed'::regclass)),
  3, 'LIVENESS: K, L, M: the ticks reached all three, refused as detached by hand (#652)');
select is(pg_temp.rp327_ids(:'k100') || pg_temp.rp327_ids(:'l100') || pg_temp.rp327_ids(:'m100'),
  array[101, 102, 103, 111, 112, 121, 122, 123, 124]::bigint[],
  'K, L, M: the operators'' tables hold rows 101 to 103, 111, 112 and 121 to 124');

-- ======================= (N) pgpm's own dispatch still in flight, ATTACHED, at the upgrade =======================
-- An older install dispatched the detach (the job armed with it) and pg_cron has yet to run it when the upgrade adds
-- the record, empty. The partition is still attached, which an adopted operator's detach never is, so the pass gives
-- the mark its record and the detach that then lands is completed as pgpm's own. [100, 200) holds 131 and 132.
create table public.rp327n (id bigint primary key, payload text);
insert into public.rp327n values (131, 'n1'), (132, 'n2');
call pgpm.transmute('public.rp327n', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.rp327n values (600, 'frontier');
create table public.rp327n_ref (id bigint primary key, n_id bigint references public.rp327n (id));
insert into public.rp327n_ref values (1, 600);
update pgpm.config set retain_batch = 1 where parent_table = 'public.rp327n'::regclass;
select child_name as n100 from pgpm.part where parent_table = 'public.rp327n'::regclass and lo = '100' \gset
call pgpm.maintain('public.rp327n');
select command as n_cmd from cron.job where jobname = 'pgpm_detach' \gset
update pgpm.part set detach_dispatched_oid = null where parent_table = 'public.rp327n'::regclass and child_name = :'n100';
select ok(:'n_cmd' = pgpm._detach_cmd('public.rp327n', 'public', :'n100')
          and (select retiring_at is not null and detach_dispatched_oid is null from pgpm.part
                where parent_table = 'public.rp327n'::regclass and child_name = :'n100')
          and exists (select 1 from pg_inherits where inhparent = 'public.rp327n'::regclass
                       and inhrelid = to_regclass(format('public.%I', :'n100')) and not inhdetachpending),
  'LIVENESS: N: [100, 200) is attached under a mark with no record, the job armed with its detach');
select is(pgpm._disown_unvouched_retirements(), 0, 'N: the upgrade''s pass disowns nothing');
select is((select detach_dispatched_oid from pgpm.part where parent_table = 'public.rp327n'::regclass and child_name = :'n100'),
  to_regclass(format('public.%I', :'n100'))::oid, 'N: and gives the in-flight mark its record, by the partition''s oid');
select command from cron.job where jobname = 'pgpm_detach' \gexec
select ok(not exists (select 1 from pg_inherits where inhparent = 'public.rp327n'::regclass
                       and inhrelid = to_regclass(format('public.%I', :'n100'))),
  'LIVENESS: N: pg_cron''s run of the armed detach landed');
call pgpm.maintain('public.rp327n');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327n'::regclass
            and action = 'retain_drop' and lo = '100'),
  1, 'N: the next tick completed pgpm''s own retirement: retain_drop for [100, 200)');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rp327n'::regclass
            and action = 'retain_disown'),
  0, 'N: and nothing disowned it');

select * from finish();
