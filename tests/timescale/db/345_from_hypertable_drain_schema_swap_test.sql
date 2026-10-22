-- A drain step's statements are checked against the relations they were meant for (issue #1335 bullet 10).
--
-- THE BUG. A drain step names the hypertable and its copy by name (`<schema>.<rel>`, `<schema>.<rel>_pgpm_dest`),
-- and the delta step names the delta by its rendering. The step locks the copy by oid (pgpm._lock_oid) and so pins
-- the copy's own name, but nothing pins a SCHEMA's name: ALTER SCHEMA ... RENAME takes no relation lock. Each
-- statement of the step resolves its names again once its own lock is granted, so a schema renamed aside while one
-- of them waits (behind an ACCESS EXCLUSIVE holder of the source, or of the delta), with a schema of the old name
-- holding namesakes of those tables committed in its place, sends the step to the namesakes: it consumes rows from a
-- table pgpm was never handed and writes them into another.
--
-- THE CONTRACT. The step locks the copy, the source and the delta by oid before its first statement on them, and
-- names them by their oids' renderings at each statement, so no statement waits for its own target and each reaches
-- the relation pgpm recorded, wherever its schema now is.
--   PART A  from_hypertable_drain_appends_step, a keyless hypertable with two appends past the copy's watermark: the
--           source's schema renamed, and a namesake source (one row past the watermark) and copy put in its place,
--           while the step waits for the source: the step completes, the copy pgpm recorded receives 50 and 60, the
--           namesakes are untouched.
--   PART B  from_hypertable_drain_delta_step, a tracked keyed hypertable with one captured update: the same while the
--           step waits for the delta, the namesake delta holding one captured key: the step completes, the copy pgpm
--           recorded receives the update, the namesake delta and copy are untouched.
--
-- THE INSTRUMENT. Deterministic: session h345 holds ACCESS EXCLUSIVE on the relation the step must wait for, session
-- r345 runs the step, and a server-side poll sees r345 waiting for it before h345 renames, creates and commits. They
-- connect to the container's bridge address, as tests/timescale/db/57 explains.
--
-- ASYMMETRIC FIXTURE. A: copied v 1..4, appended 50 and 60, the namesake source 777. B: copied ids 1..3, id 2
-- updated to 222; the namesake delta holds id 9, the namesake copy id 8. Each check names rows by value.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t345.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(15);

select dblink_connect(c, current_setting('t345.connstr')) from unnest(array['h345', 'r345']) c \g /dev/null
select set_config('t345.r_pid', (select pid::text from dblink('r345', 'select pg_backend_pid()') as t(pid int)), false) \g /dev/null

-- the step in r345 is waiting, ungranted, for p_mode on p_oid: one sample per statement, the snapshot cleared
create function pg_temp.waits_for(p_oid oid, p_mode text) returns boolean language plpgsql as $f$
begin
  for i in 1 .. 2000 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'relation' and l.relation = p_oid and (p_mode is null or l.mode = p_mode)
                  and l.pid = current_setting('t345.r_pid')::int) then
      return true;
    end if;
    perform pg_sleep(0.01);
  end loop;
  return false;
end $f$;

-- ======================= (A) the appends step =======================
create schema a345s;
create table a345s.a (ts timestamptz not null, v int not null);
select create_hypertable('a345s.a', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into a345s.a select now() - g * interval '5 hours', g from generate_series(1, 4) g;
call pgpm.from_hypertable_copy('a345s.a'::regclass, 'ts');
insert into a345s.a values (now() + interval '1 hour', 50), (now() + interval '2 hours', 60);
select 'a345s.a'::regclass::oid as a_oid \gset
select s.obj as a_dest, c.relname as a_dest_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'a_oid'::oid and s.kind = 'hypertable_dest' \gset
select pgpm._from_hypertable_ctl_text(max(ts)) as a_wm from a345s.:"a_dest_name" \gset
select is((select array_agg(v order by v) from a345s.:"a_dest_name"), array[1, 2, 3, 4],
  'fixture: A''s copy holds v 1..4, and 50 and 60 are past its watermark');

select dblink_exec('h345', 'begin') \g /dev/null
select dblink_exec('h345', 'lock table a345s.a in access exclusive mode') \g /dev/null
select dblink_send_query('r345', format('select pgpm.from_hypertable_drain_appends_step(%L, %L, 100, %L)', 'a345s.a', 'ts', :'a_wm')) \g /dev/null
select ok(pg_temp.waits_for(:'a_oid'::oid, 'AccessShareLock'),
  'LIVENESS: A: the step waits for the source, by its oid, behind the ACCESS EXCLUSIVE holder');
select dblink_exec('h345', 'alter schema a345s rename to a345s_aside') \g /dev/null
select dblink_exec('h345', 'create schema a345s') \g /dev/null
select dblink_exec('h345', 'create table a345s.a (ts timestamptz, v int)') \g /dev/null
select dblink_exec('h345', 'insert into a345s.a values (now() + interval ''3 hours'', 777)') \g /dev/null
select dblink_exec('h345', format('create table a345s.%I (ts timestamptz, v int)', :'a_dest_name')) \g /dev/null
select o as a_squat from dblink('h345', 'select ''a345s.a''::regclass::oid') as t(o oid) \gset
select dblink_exec('h345', 'commit') \g /dev/null
select count(*) as a_rows from dblink_get_result('r345', false) as t(x text) \gset
select is(dblink_error_message('r345'), 'OK',
  'A: the step completes, having locked the source by oid and followed it to the renamed schema');
select count(*) as a_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(:'a_squat'::oid <> :'a_oid'::oid, 'LIVENESS: A: the source''s name denotes the namesake now');
select is((select array_agg(v) from a345s.:"a_dest_name"), null,
  'A: the namesake copy received nothing');
select is((select array_agg(v) from a345s.a), array[777], 'A: the namesake source keeps its row 777');
select is((select array_agg(v order by v) from a345s_aside.:"a_dest_name"), array[1, 2, 3, 4, 50, 60],
  'A: the copy pgpm recorded received the source''s appends 50 and 60, and nothing of the namesake''s');

-- ======================= (B) the delta step =======================
create schema b345s;
create table b345s.k (id int not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('b345s.k', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into b345s.k select g, now() - g * interval '5 hours', g from generate_series(1, 3) g;
call pgpm.from_hypertable_copy('b345s.k'::regclass, 'ts', p_track_changes => true);
update b345s.k set v = 222 where id = 2;
select 'b345s.k'::regclass::oid as b_oid \gset
select s.obj as b_delta, c.relname as b_delta_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'b_oid'::oid and s.kind = 'hypertable_delta' \gset
select c.relname as b_dest_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'b_oid'::oid and s.kind = 'hypertable_dest' \gset
select is((select array_agg(distinct id) from b345s.:"b_delta_name"), array[2],
  'fixture: B''s delta holds the captured key 2');

select dblink_exec('h345', 'begin') \g /dev/null
select dblink_exec('h345', format('lock table b345s.%I in access exclusive mode', :'b_delta_name')) \g /dev/null
select dblink_send_query('r345', format('select pgpm.from_hypertable_drain_delta_step(%L, %L, 100)', 'b345s.k', 'ts')) \g /dev/null
select ok(pg_temp.waits_for(:'b_delta'::oid, null),
  'LIVENESS: B: the step waits for a lock on the delta''s oid, behind the ACCESS EXCLUSIVE holder');
select dblink_exec('h345', 'alter schema b345s rename to b345s_aside') \g /dev/null
select dblink_exec('h345', 'create schema b345s') \g /dev/null
select dblink_exec('h345', 'create table b345s.k (id int, ts timestamptz, v int)') \g /dev/null
select dblink_exec('h345', 'insert into b345s.k values (9, now(), 999)') \g /dev/null
select dblink_exec('h345', format('create table b345s.%I (id int, ts timestamptz, v int)', :'b_dest_name')) \g /dev/null
select dblink_exec('h345', format('insert into b345s.%I values (8, now(), 888)', :'b_dest_name')) \g /dev/null
select dblink_exec('h345', format('create table b345s.%I (like b345s_aside.%I including all)', :'b_delta_name', :'b_delta_name')) \g /dev/null
select dblink_exec('h345', format('insert into b345s.%I (id, ts) values (9, now())', :'b_delta_name')) \g /dev/null
select o as b_squat from dblink('h345', format('select %L::regclass::oid', 'b345s.' || quote_ident(:'b_delta_name'))) as t(o oid) \gset
select dblink_exec('h345', 'commit') \g /dev/null
select count(*) as b_rows from dblink_get_result('r345', false) as t(x text) \gset
select is(dblink_error_message('r345'), 'OK',
  'B: the step completes, having locked the delta and the source by oid and followed them');
select count(*) as b_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(:'b_squat'::oid <> :'b_delta'::oid, 'LIVENESS: B: the delta''s name denotes the namesake now');
select is((select array_agg(id) from b345s.:"b_delta_name"), array[9], 'B: the namesake delta keeps its row, id 9');
select is((select array_agg(v) from b345s.:"b_dest_name"), array[888], 'B: the namesake copy is untouched, 888 only');
select is((select array_agg(v order by id) from b345s_aside.:"b_dest_name" where id = 2), array[222],
  'B: the copy pgpm recorded received the captured update of key 2, from the delta pgpm recorded');
select is((select count(*)::int from b345s_aside.:"b_delta_name"), 0,
  'B: and the delta pgpm recorded is consumed whole: the batch''s bound was read from it, not from the namesake');

select dblink_disconnect(c) from unnest(array['h345', 'r345']) c \g /dev/null
select * from finish();
