-- The hypertable drains never report "converged" from an empty namesake (issue #1356).
--
-- THE BUG. from_hypertable_drain_appends and from_hypertable_drain_delta ask whether anything is left with an EXISTS
-- on the source or the delta, named before the probe waited for its lock, and from_hypertable_drain_appends_step's
-- watermark probe on the source likewise; nothing locked either by oid first (row_security_active takes no lock).
-- A schema renamed aside during that wait, with an EMPTY namesake committed under the old name, made the probe read
-- the namesake: the drains returned converged and the step returned its input watermark ("nothing past it"), while
-- the source and the delta pgpm recorded still held undrained rows.
--
-- THE CONTRACT. Each probe's relation is locked by its oid before the probe names it by its oid's rendering, so the
-- probe follows it to wherever its schema went, and the drain drains the relations pgpm recorded. The documented
-- contract for a read (CHANGELOG, #1335 bullet 10: each read locks its relation by oid first and names it as it is
-- under that lock), and tests/timescale/db/345 part A's for the step: the drain follows, and does not refuse.
--   PART A  from_hypertable_drain_appends behind an ACCESS EXCLUSIVE holder of the source, the schema swapped for one
--           holding an EMPTY namesake source: the drain completes and the copy pgpm recorded receives 50 and 60.
--   PART B  from_hypertable_drain_delta behind a holder of the delta, the schema swapped for one holding an EMPTY
--           namesake delta: the drain completes, the copy pgpm recorded receives the update of key 2 and the delta
--           pgpm recorded is consumed.
--   PART C  from_hypertable_drain_appends_step behind a holder of the source, the same swap: the step returns the
--           new watermark, not its input, and the copy pgpm recorded receives 70 and 80.
--
-- THE INSTRUMENT. Deterministic, as tests/timescale/db/345: session h347 holds the lock the call must wait for,
-- session r347 runs it, and a server-side poll sees r347 waiting before h347 renames, creates and commits.
--
-- ASYMMETRIC FIXTURE. A: copied v 1..4, appended 50 and 60. B: copied ids 1..3, id 2 updated to 222. C: copied
-- v 1..4, appended 70 and 80. Every namesake is empty, the shape that read as converged.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t347.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(19);

select dblink_connect(c, current_setting('t347.connstr')) from unnest(array['h347', 'r347']) c \g /dev/null
select set_config('t347.r_pid', (select pid::text from dblink('r347', 'select pg_backend_pid()') as t(pid int)), false) \g /dev/null

-- r347 is waiting, ungranted, for a lock on relation p_oid: one sample per statement, the snapshot cleared
create function pg_temp.waits_for(p_oid oid) returns boolean language plpgsql as $f$
begin
  for i in 1 .. 3000 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'relation' and l.relation = p_oid
                  and l.pid = current_setting('t347.r_pid')::int) then
      return true;
    end if;
    perform pg_sleep(0.01);
  end loop;
  return false;
end $f$;

-- ======================= (A) the append drain's residual probe on the source =======================
create schema a347s;
create table a347s.a (ts timestamptz not null, v int not null);
select create_hypertable('a347s.a', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into a347s.a select now() - g * interval '5 hours', g from generate_series(1, 4) g;
call pgpm.from_hypertable_copy('a347s.a'::regclass, 'ts');
insert into a347s.a values (now() + interval '1 hour', 50), (now() + interval '2 hours', 60);
select 'a347s.a'::regclass::oid as a_oid \gset
select c.relname as a_dest_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'a_oid'::oid and s.kind = 'hypertable_dest' \gset
select is((select array_agg(v order by v) from a347s.:"a_dest_name"), array[1, 2, 3, 4],
  'fixture: A: the copy holds v 1..4, and 50 and 60 are past its watermark');

select dblink_exec('h347', 'begin') \g /dev/null
select dblink_exec('h347', 'lock table a347s.a in access exclusive mode') \g /dev/null
select dblink_send_query('r347', 'call pgpm.from_hypertable_drain_appends(''a347s.a'', ''ts'', 100, 0)') \g /dev/null
select ok(pg_temp.waits_for(:'a_oid'::oid), 'LIVENESS: A: the drain waits for the source''s oid, behind the ACCESS EXCLUSIVE holder');
select dblink_exec('h347', 'alter schema a347s rename to a347s_aside') \g /dev/null
select dblink_exec('h347', 'create schema a347s') \g /dev/null
select dblink_exec('h347', 'create table a347s.a (ts timestamptz, v int)') \g /dev/null
select o as a_squat from dblink('h347', 'select ''a347s.a''::regclass::oid') as t(o oid) \gset
select dblink_exec('h347', 'commit') \g /dev/null
select count(*) as a_rows from dblink_get_result('r347', false) as t(x text) \gset
select is(dblink_error_message('r347'), 'OK', 'A: the drain completes');
select count(*) as a_tail from dblink_get_result('r347', false) as t(x text) \gset
select ok(:'a_squat'::oid <> :'a_oid'::oid, 'LIVENESS: A: the source''s old name denotes the empty namesake now');
select is((select array_agg(v order by v) from a347s_aside.:"a_dest_name"), array[1, 2, 3, 4, 50, 60],
  'A: the copy pgpm recorded received 50 and 60 from the source pgpm recorded: the drain did not stop at the namesake');
select is((select array_agg(v) from a347s.a), null, 'A: the namesake source is untouched, still empty');

-- ======================= (B) the delta drain's residual probe on the delta =======================
create schema b347s;
create table b347s.k (id int not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('b347s.k', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into b347s.k select g, now() - g * interval '5 hours', g from generate_series(1, 3) g;
call pgpm.from_hypertable_copy('b347s.k'::regclass, 'ts', p_track_changes => true);
update b347s.k set v = 222 where id = 2;
select 'b347s.k'::regclass::oid as b_oid \gset
select s.obj as b_delta, c.relname as b_delta_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'b_oid'::oid and s.kind = 'hypertable_delta' \gset
select c.relname as b_dest_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'b_oid'::oid and s.kind = 'hypertable_dest' \gset
select is((select array_agg(distinct id) from b347s.:"b_delta_name"), array[2], 'fixture: B: the delta holds the captured key 2');

select dblink_exec('h347', 'begin') \g /dev/null
select dblink_exec('h347', format('lock table b347s.%I in access exclusive mode', :'b_delta_name')) \g /dev/null
select dblink_send_query('r347', 'call pgpm.from_hypertable_drain_delta(''b347s.k'', ''ts'', 100, 0)') \g /dev/null
select ok(pg_temp.waits_for(:'b_delta'::oid), 'LIVENESS: B: the drain waits for the delta''s oid, behind the ACCESS EXCLUSIVE holder');
select dblink_exec('h347', 'alter schema b347s rename to b347s_aside') \g /dev/null
select dblink_exec('h347', 'create schema b347s') \g /dev/null
select dblink_exec('h347', format('create table b347s.%I (like b347s_aside.%I including all)', :'b_delta_name', :'b_delta_name')) \g /dev/null
select o as b_squat from dblink('h347', format('select %L::regclass::oid', 'b347s.' || quote_ident(:'b_delta_name'))) as t(o oid) \gset
select dblink_exec('h347', 'commit') \g /dev/null
select count(*) as b_rows from dblink_get_result('r347', false) as t(x text) \gset
select is(dblink_error_message('r347'), 'OK', 'B: the drain completes');
select count(*) as b_tail from dblink_get_result('r347', false) as t(x text) \gset
select ok(:'b_squat'::oid <> :'b_delta'::oid, 'LIVENESS: B: the delta''s old name denotes the empty namesake now');
select is((select array_agg(id || ':' || v order by id) from b347s_aside.:"b_dest_name"), array['1:1', '2:222', '3:3'],
  'B: the copy pgpm recorded received the update of key 2 (222): the drain did not stop at the namesake');
select is((select count(*)::int from b347s_aside.:"b_delta_name"), 0, 'B: the delta pgpm recorded is consumed');
select is((select count(*)::int from b347s.:"b_delta_name"), 0, 'B: the namesake delta is untouched, still empty');

-- ======================= (C) the append step's watermark probe on the source =======================
create schema c347s;
create table c347s.c (ts timestamptz not null, v int not null);
select create_hypertable('c347s.c', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into c347s.c select now() - g * interval '5 hours', g from generate_series(1, 4) g;
call pgpm.from_hypertable_copy('c347s.c'::regclass, 'ts');
insert into c347s.c values (now() + interval '1 hour', 70), (now() + interval '2 hours', 80);
select 'c347s.c'::regclass::oid as c_oid \gset
select c.relname as c_dest_name from pgpm.scratch s join pg_class c on c.oid = s.obj
 where s.parent_oid = :'c_oid'::oid and s.kind = 'hypertable_dest' \gset
select pgpm._from_hypertable_ctl_text(max(ts)) as c_wm from c347s.:"c_dest_name" \gset
select pgpm._from_hypertable_ctl_text(ts) as c_wm80 from c347s.c where v = 80 \gset
select is((select array_agg(v order by v) from c347s.c where ts > :'c_wm'::timestamptz), array[70, 80],
  'fixture: C: the source holds 70 and 80 past the copy''s watermark');

select dblink_exec('h347', 'begin') \g /dev/null
select dblink_exec('h347', 'lock table c347s.c in access exclusive mode') \g /dev/null
select dblink_send_query('r347', format('select pgpm.from_hypertable_drain_appends_step(%L, %L, 100, %L)', 'c347s.c', 'ts', :'c_wm')) \g /dev/null
select ok(pg_temp.waits_for(:'c_oid'::oid), 'LIVENESS: C: the step waits for the source''s oid, behind the ACCESS EXCLUSIVE holder');
select dblink_exec('h347', 'alter schema c347s rename to c347s_aside') \g /dev/null
select dblink_exec('h347', 'create schema c347s') \g /dev/null
select dblink_exec('h347', 'create table c347s.c (ts timestamptz, v int)') \g /dev/null
select o as c_squat from dblink('h347', 'select ''c347s.c''::regclass::oid') as t(o oid) \gset
select dblink_exec('h347', 'commit') \g /dev/null
select coalesce((select x from dblink_get_result('r347', false) as t(x text)), 'null') as c_out \gset
select is(dblink_error_message('r347'), 'OK', 'C: the step completes');
select count(*) as c_tail from dblink_get_result('r347', false) as t(x text) \gset
select ok(:'c_squat'::oid <> :'c_oid'::oid, 'LIVENESS: C: the source''s old name denotes the empty namesake now');
select is(:'c_out'::text, :'c_wm80'::text, 'C: the step returns the watermark of what it copied (80''s), not its input');
select is((select array_agg(v order by v) from c347s_aside.:"c_dest_name"), array[1, 2, 3, 4, 70, 80],
  'C: the copy pgpm recorded received 70 and 80');

select dblink_disconnect(c) from unnest(array['h347', 'r347']) c \g /dev/null
select * from finish();
