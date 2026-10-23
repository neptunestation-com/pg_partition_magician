-- The hypertable module's statements on what pgpm recorded reach it by oid after a lock wait (issue #1366).
--
-- THE BUG. A statement that names a relation or function pgpm identified by oid, through a name rendered before
-- the statement waits for a lock, resolves the name again once the lock is granted. A lock pins a relation's own
-- name, never its schema's (ALTER SCHEMA ... RENAME takes no lock on what the schema holds), and a function's
-- rename is committed by whoever held it. So a rename aside with a namesake committed during the wait was what
-- the statement reached: the cutover and the copy's re-run dropped the operator's function and left pgpm's capture
-- function behind with no record (F10-02, F12-04, F10-03); the delta step reconciled a batch from a namesake source
-- (F6-03); the append drain locked and read the watermark of an empty namesake copy, and its NULL watermark made
-- the step copy every source row into the recorded copy a second time (F6-04). And the cutover read the baseline
-- of its conservation check from the copy by the name read at its start (part E).
--
-- THE CONTRACT. A function pgpm recorded is dropped by its oid's rendering and the oid must be gone after it, or the
-- call is refused, rolled back whole. A relation the module reads or writes is locked by its oid first and named by
-- its oid's rendering under that lock, so the statement follows it to wherever its schema went.
--   PART A  from_hypertable_cutover, its capture function renamed aside and a namesake created under its name while
--           the DROP waits for the function: refused, the namesake kept, pgpm's function kept and recorded, the
--           hypertable whole.
--   PART B  from_hypertable_copy's re-run, the previous capture function in a schema of its own, that schema renamed
--           aside and a namesake schema and function put in its place during the DROP's wait: refused, the
--           namesake kept, the previous function still recorded and still firing on the hypertable.
--   PART C  from_hypertable_drain_delta_step behind an ACCESS EXCLUSIVE holder of the source, the source's schema
--           swapped for one holding a namesake source: the step reconciles key 2 from the recorded source (222),
--           nothing from the namesake (999).
--   PART D  from_hypertable_drain_appends behind a holder of the copy, the schema swapped for one holding an EMPTY
--           namesake copy: the recorded copy holds each source row once, plus the appends.
--   PART E  from_hypertable_cutover of a keyless table behind a holder of the copy, the schema swapped for one
--           holding an EMPTY namesake copy and swapped back while the cutover waits for the source: the migrated
--           table holds each source row once (the baseline read from the namesake made the catch-up re-insert
--           every copied row, and the conservation check agreed).
--   PART F  from_hypertable_cutover of a tracking copy behind a holder of the delta, the schema swapped for one
--           holding a namesake source and a namesake copy of the shape the conservation check agrees with, and
--           swapped back while the cutover waits to drop an incoming key: the migrated table holds key 2 as the
--           source held it (222), and the namesake copy is untouched (the catch-up by name reconciled the namesake
--           and the swap committed the stale row).
--   The stretch from the source's DROP to the swap's COMMIT is not driven: there TimescaleDB's own rename hook
--   waits for the cutover (ALTER SCHEMA ... RENAME updates the catalog row of the hypertable the DROP deleted).
--
-- THE INSTRUMENT. Deterministic: session h346 holds the lock the call under test must wait for, session r346 runs
-- the call, and a server-side poll sees r346 waiting before h346 renames, creates and commits. They connect to the
-- container's bridge address, as tests/timescale/db/57 explains.
--
-- ASYMMETRIC FIXTURE. A: ids 1..3, the namesake function returns null. B: ids 1..5. C: copied ids 1..3, id 2 updated
-- to 222, the namesake source holds (2, 999) and (7, 777). D: copied v 1..4, appended 50 and 60. E: copied v 1..4,
-- appended 50 and 60. F: copied ids 1..3, id 2 updated to 222, the namesake copy holding (2, 2). Each check names rows
-- or objects by identity.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t346.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(38);

select dblink_connect(c, current_setting('t346.connstr')) from unnest(array['h346', 'r346', 'g346']) c \g /dev/null
select set_config('t346.r_pid', (select pid::text from dblink('r346', 'select pg_backend_pid()') as t(pid int)), false) \g /dev/null

-- r346 is waiting, ungranted, for p_mode on relation p_oid: one sample per statement, the snapshot cleared
create function pg_temp.waits_for(p_oid oid, p_mode text) returns boolean language plpgsql as $f$
begin
  for i in 1 .. 3000 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'relation' and l.relation = p_oid and (p_mode is null or l.mode = p_mode)
                  and l.pid = current_setting('t346.r_pid')::int) then
      return true;
    end if;
    perform pg_sleep(0.01);
  end loop;
  return false;
end $f$;
-- ...and for ACCESS EXCLUSIVE on function p_fn (a DROP FUNCTION's object lock)
create function pg_temp.waits_for_fn(p_fn oid) returns boolean language plpgsql as $f$
begin
  for i in 1 .. 3000 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'object' and l.classid = 'pg_proc'::regclass and l.objid = p_fn
                  and l.mode = 'AccessExclusiveLock' and l.pid = current_setting('t346.r_pid')::int) then
      return true;
    end if;
    perform pg_sleep(0.01);
  end loop;
  return false;
end $f$;

-- ======================= (A) the cutover's drop of the capture function =======================
create schema a346s;
create table a346s.h (id int not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('a346s.h', 'ts', chunk_time_interval => interval '1 day') \g /dev/null
insert into a346s.h select g, now() - g * interval '5 hours', g * 10 from generate_series(1, 3) g;
call pgpm.from_hypertable_copy('a346s.h'::regclass, 'ts', p_track_changes => true);
select 'a346s.h'::regclass::oid as a_oid \gset
select s.obj as a_fn, p.proname as a_fn_name from pgpm.scratch s join pg_proc p on p.oid = s.obj
 where s.parent_oid = :'a_oid'::oid and s.kind = 'hypertable_delta_fn' \gset

select dblink_exec('h346', 'begin') \g /dev/null
select dblink_exec('h346', format('comment on function a346s.%I() is %L', :'a_fn_name', 'held')) \g /dev/null
select dblink_send_query('r346', 'call pgpm.from_hypertable_cutover(''a346s.h'', ''ts'', interval ''1 day'', p_predrain => false, p_lock_timeout => ''60s'')') \g /dev/null
select ok(pg_temp.waits_for_fn(:'a_fn'::oid),
  'LIVENESS: A: the cutover waits for ACCESS EXCLUSIVE on the recorded capture function, behind its holder');
select dblink_exec('h346', format('alter function a346s.%I() rename to %I', :'a_fn_name', :'a_fn_name' || '_aside')) \g /dev/null
select dblink_exec('h346', format('create function a346s.%I() returns trigger language plpgsql as %L', :'a_fn_name', 'begin return null; end')) \g /dev/null
select o as a_squat from dblink('h346', format('select to_regprocedure(%L)::oid', 'a346s.' || quote_ident(:'a_fn_name') || '()')) as t(o oid) \gset
select dblink_exec('h346', 'commit') \g /dev/null
select count(*) as a_rows from dblink_get_result('r346', false) as t(x text) \gset
select dblink_error_message('r346') as a_err \gset
select count(*) as a_tail from dblink_get_result('r346', false) as t(x text) \gset
select ok(:'a_squat'::oid <> :'a_fn'::oid, 'LIVENESS: A: the capture function''s name denotes the namesake now');
select alike(:'a_err'::text, '%from_hypertable_cutover(a346s.h), dropping the capture function, reached another function than the one pgpm recorded%',
  'A: the cutover refuses, its DROP having reached the namesake');
select ok(exists (select 1 from pg_proc where oid = :'a_squat'::oid), 'A: the operator''s namesake function survives');
select ok(exists (select 1 from pg_proc where oid = :'a_fn'::oid)
          and exists (select 1 from pgpm.scratch where parent_oid = :'a_oid'::oid and kind = 'hypertable_delta_fn' and obj = :'a_fn'::oid),
  'A: pgpm''s capture function is still there, and still recorded');
select is((select array_agg(id order by id) from a346s.h), array[1, 2, 3],
  'A: the hypertable is whole: the swap rolled back');
select ok(exists (select 1 from timescaledb_information.hypertables where hypertable_schema = 'a346s' and hypertable_name = 'h'),
  'A: and it is still a hypertable');

-- ======================= (B) the copy's re-run drops the previous capture function =======================
create schema b346s;
create schema b346cap;
create table b346s.h (id int not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('b346s.h', 'ts', chunk_time_interval => interval '1 day') \g /dev/null
insert into b346s.h select g, now() - g * interval '5 hours', g * 10 from generate_series(1, 5) g;
call pgpm.from_hypertable_copy('b346s.h'::regclass, 'ts', p_track_changes => true);
select 'b346s.h'::regclass::oid as b_oid \gset
select format('alter function %s set schema b346cap', s.obj::regprocedure)
  from pgpm.scratch s where s.parent_oid = :'b_oid'::oid and s.kind = 'hypertable_delta_fn' \gexec
select s.obj as b_fn, p.proname as b_fn_name from pgpm.scratch s join pg_proc p on p.oid = s.obj
 where s.parent_oid = :'b_oid'::oid and s.kind = 'hypertable_delta_fn' \gset
select is((select pronamespace::regnamespace::text from pg_proc where oid = :'b_fn'::oid), 'b346cap',
  'fixture: B: the recorded capture function sits in a schema of its own');

select dblink_exec('h346', 'begin') \g /dev/null
select dblink_exec('h346', format('comment on function b346cap.%I() is %L', :'b_fn_name', 'held')) \g /dev/null
select dblink_send_query('r346', 'call pgpm.from_hypertable_copy(''b346s.h'', ''ts'', p_track_changes => true)') \g /dev/null
select ok(pg_temp.waits_for_fn(:'b_fn'::oid),
  'LIVENESS: B: the re-run copy waits for ACCESS EXCLUSIVE on the previous capture function, behind its holder');
select dblink_exec('h346', 'alter schema b346cap rename to b346cap_aside') \g /dev/null
select dblink_exec('h346', 'create schema b346cap') \g /dev/null
select dblink_exec('h346', format('create function b346cap.%I() returns int language sql as %L', :'b_fn_name', 'select 1')) \g /dev/null
select o as b_squat from dblink('h346', format('select to_regprocedure(%L)::oid', 'b346cap.' || quote_ident(:'b_fn_name') || '()')) as t(o oid) \gset
select dblink_exec('h346', 'commit') \g /dev/null
select count(*) as b_rows from dblink_get_result('r346', false) as t(x text) \gset
select dblink_error_message('r346') as b_err \gset
select count(*) as b_tail from dblink_get_result('r346', false) as t(x text) \gset
select ok(:'b_squat'::oid <> :'b_fn'::oid, 'LIVENESS: B: the function''s old name denotes the namesake now');
select alike(:'b_err'::text, '%from_hypertable_copy(b346s.h), dropping the previous capture function, reached another function than the one pgpm recorded%',
  'B: the re-run copy refuses, its DROP having reached the namesake');
select ok(exists (select 1 from pg_proc where oid = :'b_squat'::oid), 'B: the operator''s namesake function survives');
select ok(exists (select 1 from pgpm.scratch where parent_oid = :'b_oid'::oid and kind = 'hypertable_delta_fn' and obj = :'b_fn'::oid),
  'B: the previous capture function is still recorded');
select is((select array_agg(t.tgname::text) from pg_trigger t where t.tgrelid = :'b_oid'::oid and t.tgfoid = :'b_fn'::oid),
  array['h_pgpm_delta_trg'], 'B: and still fires on the hypertable: its trigger''s drop rolled back with the refusal');

-- ======================= (C) the delta step's source read =======================
create schema c346s;
create table c346s.k (id int not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('c346s.k', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into c346s.k select g, date_trunc('second', now()) - g * interval '5 hours', g from generate_series(1, 3) g;
call pgpm.from_hypertable_copy('c346s.k'::regclass, 'ts', p_track_changes => true);
update c346s.k set v = 222 where id = 2;
select 'c346s.k'::regclass::oid as c_oid \gset
select pgpm._from_hypertable_ctl_text(ts) as c_ts2 from c346s.k where id = 2 \gset
select c.relname as c_dest_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'c_oid'::oid and s.kind = 'hypertable_dest' \gset
select c.relname as c_delta_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'c_oid'::oid and s.kind = 'hypertable_delta' \gset
select is((select array_agg(distinct id) from c346s.:"c_delta_name"), array[2],
  'fixture: C: the delta holds the captured key 2');

select dblink_exec('h346', 'begin') \g /dev/null
select dblink_exec('h346', 'lock table c346s.k in access exclusive mode') \g /dev/null
select dblink_send_query('r346', format('select pgpm.from_hypertable_drain_delta_step(%L, %L, 100)', 'c346s.k', 'ts')) \g /dev/null
select ok(pg_temp.waits_for(:'c_oid'::oid, 'AccessShareLock'),
  'LIVENESS: C: the step waits for ACCESS SHARE on the source''s oid, behind the ACCESS EXCLUSIVE holder');
select dblink_exec('h346', 'alter schema c346s rename to c346s_aside') \g /dev/null
select dblink_exec('h346', 'create schema c346s') \g /dev/null
select dblink_exec('h346', 'create table c346s.k (id int, ts timestamptz, v int)') \g /dev/null
select dblink_exec('h346', format('insert into c346s.k values (2, %L, 999), (7, %L, 777)', :'c_ts2', :'c_ts2')) \g /dev/null
select o as c_squat from dblink('h346', 'select ''c346s.k''::regclass::oid') as t(o oid) \gset
select dblink_exec('h346', 'commit') \g /dev/null
select count(*) as c_rows from dblink_get_result('r346', false) as t(x text) \gset
select is(dblink_error_message('r346'), 'OK', 'C: the step completes, having followed the source by its oid');
select count(*) as c_tail from dblink_get_result('r346', false) as t(x text) \gset
select ok(:'c_squat'::oid <> :'c_oid'::oid, 'LIVENESS: C: the source''s old name denotes the namesake now');
select is((select array_agg(id || ':' || v order by id) from c346s_aside.:"c_dest_name"), array['1:1', '2:222', '3:3'],
  'C: the copy pgpm recorded holds the source''s row for key 2 (222), and nothing of the namesake''s (999, 777)');
select is((select array_agg(v order by v) from c346s.k), array[777, 999], 'C: the namesake source keeps its rows');

-- ======================= (D) the append drain's copy lock and watermark =======================
create schema d346s;
create table d346s.a (ts timestamptz not null, v int not null);
select create_hypertable('d346s.a', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into d346s.a select now() - g * interval '5 hours', g from generate_series(1, 4) g;
call pgpm.from_hypertable_copy('d346s.a'::regclass, 'ts');
insert into d346s.a values (now() + interval '1 hour', 50), (now() + interval '2 hours', 60);
select 'd346s.a'::regclass::oid as d_oid \gset
select s.obj as d_dest, c.relname as d_dest_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'d_oid'::oid and s.kind = 'hypertable_dest' \gset
select is((select array_agg(v order by v) from d346s.:"d_dest_name"), array[1, 2, 3, 4],
  'fixture: D: the copy holds v 1..4, and 50 and 60 are past its watermark');

select dblink_exec('h346', 'begin') \g /dev/null
select dblink_exec('h346', format('lock table d346s.%I in access exclusive mode', :'d_dest_name')) \g /dev/null
select dblink_send_query('r346', 'call pgpm.from_hypertable_drain_appends(''d346s.a''::regclass, ''ts'')') \g /dev/null
select ok(pg_temp.waits_for(:'d_dest'::oid, null),
  'LIVENESS: D: the drain waits for a lock on the copy''s oid, behind the holder');
select dblink_exec('h346', 'alter schema d346s rename to d346s_aside') \g /dev/null
select dblink_exec('h346', 'create schema d346s') \g /dev/null
select dblink_exec('h346', 'create table d346s.a (ts timestamptz, v int)') \g /dev/null
select dblink_exec('h346', format('create table d346s.%I (ts timestamptz, v int)', :'d_dest_name')) \g /dev/null
select o as d_squat from dblink('h346', format('select %L::regclass::oid', 'd346s.' || quote_ident(:'d_dest_name'))) as t(o oid) \gset
select dblink_exec('h346', 'commit') \g /dev/null
select count(*) as d_rows from dblink_get_result('r346', false) as t(x text) \gset
select is(dblink_error_message('r346'), 'OK', 'D: the drain completes, having followed the copy by its oid');
select count(*) as d_tail from dblink_get_result('r346', false) as t(x text) \gset
select ok(:'d_squat'::oid <> :'d_dest'::oid, 'LIVENESS: D: the copy''s old name denotes the empty namesake now');
select is((select array_agg(v order by v) from d346s_aside.:"d_dest_name"), array[1, 2, 3, 4, 50, 60],
  'D: the copy pgpm recorded holds each source row once: 1..4 as copied, plus the appends 50 and 60');
select is((select array_agg(v) from d346s.:"d_dest_name"), null, 'D: the namesake copy received nothing');

-- ======================= (E) the cutover's baseline read of the copy =======================
-- A keyless table, so the catch-up has no key to anti-join by. h346 holds the copy, so the cutover waits for its
-- SHARE lock there; meanwhile the schema is renamed aside and a namesake schema with an EMPTY namesake copy put in
-- its place. g346 holds the source, so the cutover then waits for its ACCESS EXCLUSIVE; meanwhile the schemas are
-- swapped back, so the cutover's name checks under that lock find the hypertable and the copy where they were.
create schema e346s;
create table e346s.a (ts timestamptz not null, v int not null);
select create_hypertable('e346s.a', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into e346s.a select now() - g * interval '5 hours', g from generate_series(1, 4) g;
call pgpm.from_hypertable_copy('e346s.a'::regclass, 'ts');
insert into e346s.a values (now() + interval '1 hour', 50), (now() + interval '2 hours', 60);
select 'e346s.a'::regclass::oid as e_oid \gset
select s.obj as e_dest, c.relname as e_dest_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'e_oid'::oid and s.kind = 'hypertable_dest' \gset
select is((select array_agg(v order by v) from e346s.:"e_dest_name"), array[1, 2, 3, 4],
  'fixture: E: the copy holds v 1..4, and 50 and 60 are past its watermark');

select dblink_exec('h346', 'begin') \g /dev/null
select dblink_exec('h346', format('lock table e346s.%I in access exclusive mode', :'e_dest_name')) \g /dev/null
select dblink_exec('g346', 'begin') \g /dev/null
select dblink_exec('g346', 'lock table e346s.a in access share mode') \g /dev/null
select dblink_send_query('r346', 'call pgpm.from_hypertable_cutover(''e346s.a'', ''ts'', interval ''1 day'', p_predrain => false, p_lock_timeout => ''60s'')') \g /dev/null
select ok(pg_temp.waits_for(:'e_dest'::oid, 'ShareLock'),
  'LIVENESS: E: the cutover waits for SHARE on the copy''s oid, behind the holder');
select dblink_exec('h346', 'alter schema e346s rename to e346s_aside') \g /dev/null
select dblink_exec('h346', 'create schema e346s') \g /dev/null
select dblink_exec('h346', format('create table e346s.%I (ts timestamptz, v int)', :'e_dest_name')) \g /dev/null
select dblink_exec('h346', 'commit') \g /dev/null
select ok(pg_temp.waits_for(:'e_oid'::oid, 'AccessExclusiveLock'),
  'LIVENESS: E: the cutover has read the copy and waits for ACCESS EXCLUSIVE on the source, behind the second holder');
select dblink_exec('g346', 'alter schema e346s rename to e346s_squat') \g /dev/null
select dblink_exec('g346', 'alter schema e346s_aside rename to e346s') \g /dev/null
select dblink_exec('g346', 'commit') \g /dev/null
select count(*) as e_rows from dblink_get_result('r346', false) as t(x text) \gset
select is(dblink_error_message('r346'), 'OK', 'E: the cutover completes');
select count(*) as e_tail from dblink_get_result('r346', false) as t(x text) \gset
select is((select array_agg(v order by v) from e346s.a), array[1, 2, 3, 4, 50, 60],
  'E: the migrated table holds each source row once: 1..4 as copied, plus the appends 50 and 60');

-- ======================= (F) the cutover's change-tracking catch-up and its conservation check =======================
-- h346 holds the delta, so the cutover, holding the source and the copy, waits for the delta; meanwhile the schema is
-- renamed aside and a namesake schema put in its place, holding a namesake source with the source's current rows and a
-- namesake copy with the stale version of key 2 (the shape whose catch-up the conservation check agrees with). g346
-- holds f346r.r, which references the hypertable, so the cutover then waits to drop that incoming key; meanwhile the
-- schemas are swapped back, so the DROP and the RENAME find the source and the copy where they were.
create schema f346s;
create schema f346r;
create table f346s.k (id int not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('f346s.k', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into f346s.k select g, date_trunc('second', now()) - g * interval '5 hours', g from generate_series(1, 3) g;
create table f346r.r (id int, ts timestamptz, foreign key (id, ts) references f346s.k (id, ts));
insert into f346r.r select id, ts from f346s.k where id = 1;
call pgpm.from_hypertable_copy('f346s.k'::regclass, 'ts', p_track_changes => true);
update f346s.k set v = 222 where id = 2;
select 'f346s.k'::regclass::oid as f_oid, 'f346r.r'::regclass::oid as f_ref \gset
select s.obj as f_delta, c.relname as f_delta_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'f_oid'::oid and s.kind = 'hypertable_delta' \gset
select c.relname as f_dest_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'f_oid'::oid and s.kind = 'hypertable_dest' \gset
select string_agg(format('(%s, %L, %s)', id, pgpm._from_hypertable_ctl_text(ts), v), ', ' order by id) as f_rows,
       format('(2, %L, 2)', pgpm._from_hypertable_ctl_text(max(ts) filter (where id = 2))) as f_stale
  from f346s.k \gset
select is((select array_agg(id || ':' || v order by id) from f346s.:"f_dest_name"), array['1:1', '2:2', '3:3'],
  'fixture: F: the copy holds key 2 stale (2), the source holds it updated (222), and the delta holds key 2');

select dblink_exec('h346', 'begin') \g /dev/null
select dblink_exec('h346', format('lock table f346s.%I in access exclusive mode', :'f_delta_name')) \g /dev/null
select dblink_exec('g346', 'begin') \g /dev/null
select dblink_exec('g346', 'lock table f346r.r in access share mode') \g /dev/null
select dblink_send_query('r346', 'call pgpm.from_hypertable_cutover(''f346s.k'', ''ts'', interval ''1 day'', p_predrain => false, p_lock_timeout => ''60s'')') \g /dev/null
select ok(pg_temp.waits_for(:'f_delta'::oid, 'AccessExclusiveLock'),
  'LIVENESS: F: the cutover, holding the source and the copy, waits for ACCESS EXCLUSIVE on the delta');
select dblink_exec('h346', 'alter schema f346s rename to f346s_aside') \g /dev/null
select dblink_exec('h346', 'create schema f346s') \g /dev/null
select dblink_exec('h346', 'create table f346s.k (id int, ts timestamptz, v int)') \g /dev/null
select dblink_exec('h346', 'insert into f346s.k values ' || :'f_rows') \g /dev/null
select dblink_exec('h346', format('create table f346s.%I (id int, ts timestamptz, v int)', :'f_dest_name')) \g /dev/null
select dblink_exec('h346', format('insert into f346s.%I values ', :'f_dest_name') || :'f_stale') \g /dev/null
select o as f_squat from dblink('h346', 'select ''f346s.k''::regclass::oid') as t(o oid) \gset
select dblink_exec('h346', 'commit') \g /dev/null
select ok(pg_temp.waits_for(:'f_ref'::oid, 'AccessExclusiveLock'),
  'LIVENESS: F: the cutover, past its catch-up and its conservation check, waits to drop the incoming key');
select ok(:'f_squat'::oid <> :'f_oid'::oid, 'LIVENESS: F: the source''s name denoted the namesake through that stretch');
select dblink_exec('g346', 'alter schema f346s rename to f346s_squat') \g /dev/null
select dblink_exec('g346', 'alter schema f346s_aside rename to f346s') \g /dev/null
select dblink_exec('g346', 'commit') \g /dev/null
select count(*) as f_rows_out from dblink_get_result('r346', false) as t(x text) \gset
select is(dblink_error_message('r346'), 'OK', 'F: the cutover completes');
select count(*) as f_tail from dblink_get_result('r346', false) as t(x text) \gset
select is((select array_agg(id || ':' || v order by id) from f346s.k), array['1:1', '2:222', '3:3'],
  'F: the migrated table holds key 2 as the source held it (222): the catch-up reconciled the copy pgpm recorded');
select is((select array_agg(id || ':' || v order by id) from f346s_squat.:"f_dest_name"), array['2:2'],
  'F: the namesake copy is untouched');

select dblink_disconnect(c) from unnest(array['h346', 'r346', 'g346']) c \g /dev/null
select * from finish();
