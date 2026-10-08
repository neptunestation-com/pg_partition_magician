-- from_hypertable_copy's change capture writes its delta only under a lock that pins the delta to the name it
-- uses (issue #1057, bullet 3): the hypertable twin of tests/290.
--
-- THE DEFECT. #1037 made the capture function from_hypertable_copy mints reach the delta by the oid the copy
-- recorded, with a fast path: while the minted name still led to the recorded oid, the static
-- `insert into <rel>_pgpm_delta` ran. The check was a to_regclass, which takes no lock, and the insert then
-- looked the name up AGAIN, after queueing on the delta's lock. So a writer arriving while an operator's
-- transaction held the delta to rename it passed the check, queued, and once the rename committed wrote its
-- keys into whatever held the minted name by then: a table the operator created under the freed name in the
-- same transaction (which the cutover never reads, so the cutover reverted the committed write), or nothing,
-- and the write was refused with 42P01.
--
-- THE LEVER, deterministic, not timed: as in tests/290. A second session (the operator) renames the recorded
-- delta and, in the same transaction, waits until it sees the writer queued on the delta's lock; only then
-- does it create its table under the freed name (or not) and commit. The writer (a third session) is sent
-- only once the operator is seen holding ACCESS EXCLUSIVE on the delta.
--
-- WHY THE BRIDGE ADDRESS. The second and third sessions are dblink connections, and this track's image has
-- no superuser: dblink lets a non-superuser connect only when the server asks for a password, which this
-- image does off loopback alone (127.0.0.1 and ::1 are trusted). So the file connects to the container's own
-- bridge address (its first IPv4 one), which psql reads from `hostname -i` on the client side (the file always
-- runs in the container, under run_timescale and its bench wrapper alike), with the password the harness
-- gives postgres.
--
-- ASYMMETRIC FIXTURE. Three hypertables with a tracking copy each.
--   a57 (6 devices): rename + a table under the freed name; the owner's write updates device 2.
--   c57 (5 devices): rename only; the owner's write deletes device 3 and inserts device 100001.
--   b57 (4 devices), the control: its delta left alone, takes one write (insert device 200001).
-- Each delta's keys are asserted by identity, the operator's table is asserted empty, and each cutover by the
-- rows it leaves, by device and value. bench/hypertable_capture_delta_held.sh runs this file against the
-- mutant that puts the unlocked fast path back (hypertable_capture_fast_path_unlocked), so it is required to
-- FAIL there.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t57.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(20);

select mk_keyed_hypertable('a57', 6, '1 day', '4 days');
select mk_keyed_hypertable('b57', 4, '1 day', '4 days');
select mk_keyed_hypertable('c57', 5, '1 day', '4 days');
update a57 set temp = device_id * 10;
update b57 set temp = device_id * 10;
update c57 set temp = device_id * 10;
call pgpm.from_hypertable_copy('a57'::regclass, 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('b57'::regclass, 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('c57'::regclass, 'ts', p_track_changes => true);

select is(pgpm._from_hypertable_scratch('a57'::regclass, 'hypertable_delta')::text
          || ',' || pgpm._from_hypertable_scratch('b57'::regclass, 'hypertable_delta')::text
          || ',' || pgpm._from_hypertable_scratch('c57'::regclass, 'hypertable_delta')::text,
          'a57_pgpm_delta,b57_pgpm_delta,c57_pgpm_delta',
          'LIVENESS: each tracking copy minted and recorded its delta under its own name');

-- The recorded oids, before anything is renamed, so every later read is by identity.
create table public.r57_delta (parent text primary key, delta oid);
insert into public.r57_delta
  select t, s.obj from unnest(array['a57', 'b57', 'c57']) t
    join pgpm.scratch s on s.parent_oid = t::regclass::oid and s.kind = 'hypertable_delta';
create table public.r57_seen (parent text primary key, writer_pid int);
create table public.r57_outcome (parent text, who text, state text, msg text, primary key (parent, who));

-- One race (see tests/290's pg_temp.race): each side sends ONE statement, because dblink_get_result returns
-- the first result of a multi-statement string and an error in a later one would go unread.
create function pg_temp.race(p_parent text, p_take_name boolean, p_writer_sql text) returns void language plpgsql as $f$
declare
  v_delta oid := (select delta from public.r57_delta where parent = p_parent);
  v_wpid int; v_opid int; v_held boolean := false;
begin
  perform dblink_connect('r57_op', current_setting('t57.connstr'));
  perform dblink_connect('r57_w', current_setting('t57.connstr'));
  select pid into v_opid from dblink('r57_op', 'select pg_backend_pid()') as t(pid int);
  select pid into v_wpid from dblink('r57_w', 'select pg_backend_pid()') as t(pid int);
  perform dblink_send_query('r57_op', format($op$
    do $x$
    begin
      alter table public.%1$I rename to %2$I;
      for i in 1 .. 4000 loop
        exit when exists (select 1 from pg_locks where pid = %3$s and relation = %4$s and not granted);
        perform pg_sleep(0.005);
      end loop;
      if not exists (select 1 from pg_locks where pid = %3$s and relation = %4$s and not granted) then
        raise exception 'the writer never queued on the delta';
      end if;
      insert into public.r57_seen values (%5$L, %3$s);
      if %6$L then
        create table public.%1$I (device_id bigint, ts timestamptz);
      end if;
    end $x$
    $op$, p_parent || '_pgpm_delta', p_parent || '_renamed_delta', v_wpid, v_delta, p_parent, p_take_name));
  for i in 1 .. 4000 loop
    v_held := exists (select 1 from pg_locks where pid = v_opid and relation = v_delta
                       and mode = 'AccessExclusiveLock' and granted);
    exit when v_held;
    perform pg_sleep(0.005);
  end loop;
  if v_held then
    perform dblink_send_query('r57_w', p_writer_sql);
  end if;
  begin
    perform * from dblink_get_result('r57_op') as t(x text);
    insert into public.r57_outcome values (p_parent, 'operator', '00000', null);
  exception when others then
    insert into public.r57_outcome values (p_parent, 'operator', sqlstate, left(sqlerrm, 200));
  end;
  if v_held then
    begin
      perform * from dblink_get_result('r57_w') as t(x text);
      insert into public.r57_outcome values (p_parent, 'writer', '00000', null);
    exception when others then
      insert into public.r57_outcome values (p_parent, 'writer', sqlstate, left(sqlerrm, 200));
    end;
  else
    insert into public.r57_outcome values (p_parent, 'writer', 'never sent', 'the operator was never seen holding the delta');
  end if;
  perform dblink_disconnect('r57_op');
  perform dblink_disconnect('r57_w');
end $f$;

select pg_temp.race('a57', true, $w$update public.a57 set temp = 777 where device_id = 2$w$);
select pg_temp.race('c57', false,
  $w$do $d$ begin
       delete from public.c57 where device_id = 3;
       insert into public.c57 (ts, device_id, temp) values (now() - interval '1 hour', 100001, 1.0);
     end $d$$w$);
insert into b57 (ts, device_id, temp) values (now() - interval '2 hours', 200001, 2.0);

-- ==================== the witnesses: each race happened as the defect needs it ====================
select is((select string_agg(s.parent || ':' || (s.writer_pid is not null)::text, ',' order by s.parent) from public.r57_seen s),
  'a57:true,c57:true', 'LIVENESS: in each race the operator saw the writer queued on the delta before it committed');
select is((select string_agg(o.parent || ':' || o.state || coalesce(' ' || o.msg, ''), ',' order by o.parent)
             from public.r57_outcome o where o.who = 'operator'),
  'a57:00000,c57:00000', 'GUARD: each operator''s rename (and take of the name) committed');
select is((select string_agg(d.parent || '=' || c.relname, ',' order by d.parent) from public.r57_delta d join pg_class c on c.oid = d.delta),
  'a57=a57_renamed_delta,b57=b57_pgpm_delta,c57=c57_renamed_delta',
  'LIVENESS: each recorded delta is the same relation, renamed where an operator renamed it');
select ok(to_regclass('public.a57_pgpm_delta') is not null
          and to_regclass('public.a57_pgpm_delta') <> (select delta from public.r57_delta where parent = 'a57')::regclass,
  'LIVENESS: a table of the operator''s now holds the name a57''s delta gave up');
select ok(to_regclass('public.c57_pgpm_delta') is null, 'LIVENESS: nothing holds the name c57''s delta gave up');

-- ==================== the contract: every write goes on, into the recorded delta ====================
select is((select state || coalesce(' ' || msg, '') from public.r57_outcome where parent = 'a57' and who = 'writer'),
  '00000', 'a57: the write that queued behind the rename and the take of its name succeeds');
select is((select state || coalesce(' ' || msg, '') from public.r57_outcome where parent = 'c57' and who = 'writer'),
  '00000', 'c57: the write that queued behind the rename succeeds (not 42P01)');
select is((select string_agg(device_id::text, ',' order by device_id, pgpm_seq) from public.a57_renamed_delta), '2,2',
  'a57: the update''s keys are captured in the recorded (renamed) delta');
select is((select string_agg(device_id::text, ',' order by device_id, pgpm_seq) from public.c57_renamed_delta), '3,100001',
  'c57: the delete''s and the insert''s keys are captured in the recorded (renamed) delta');
select is((select coalesce(string_agg(device_id::text, ','), '') from public.a57_pgpm_delta), '',
  'a57: the operator''s table under the freed name takes none');
select is((select string_agg(device_id::text, ',' order by device_id, pgpm_seq) from public.b57_pgpm_delta), '200001',
  'the control: b57''s capture, its delta left alone, logs its write');
insert into public.a57_pgpm_delta (device_id, ts) values (-1, now());
select ok(exists (select 1 from public.a57_pgpm_delta where device_id = -1),
  'LIVENESS: the operator''s table under a57''s freed name accepts a row of the capture''s shape');
delete from public.a57_pgpm_delta where device_id = -1;

-- ==================== the cutover honours every captured write, by row ====================
call pgpm.from_hypertable_cutover('a57'::regclass, 'ts', interval '1 day', p_paused => true);
call pgpm.from_hypertable_cutover('b57'::regclass, 'ts', interval '1 day', p_paused => true);
call pgpm.from_hypertable_cutover('c57'::regclass, 'ts', interval '1 day', p_paused => true);
select is((select string_agg(relkind::text, '/' order by relname) from pg_class where oid in ('a57'::regclass, 'b57'::regclass, 'c57'::regclass)),
  'p/p/p', 'LIVENESS: each hypertable was cut over to a partitioned table');
select is((select string_agg(device_id || '=' || temp, ',' order by device_id) from a57),
  '1=10,2=777,3=30,4=40,5=50,6=60', 'a57 keeps the committed update of device 2 after the cutover');
select is((select string_agg(device_id || '=' || temp, ',' order by device_id) from c57),
  '1=10,2=20,4=40,5=50,100001=1', 'c57 keeps the delete of device 3 and the insert of 100001 after the cutover');
select is((select string_agg(device_id || '=' || temp, ',' order by device_id) from b57),
  '1=10,2=20,3=30,4=40,200001=2', 'the control: b57 keeps its four devices and its insert');
select ok(not exists (select 1 from pg_class c join public.r57_delta d on d.delta = c.oid),
  'the cutover dropped each recorded delta, renamed or not');
select is((select count(*)::int from public.a57_pgpm_delta), 0,
  'the operator''s table under a57''s freed name survives the cutover, empty');
select is((select count(*)::int from pg_trigger t where t.tgname in ('a57_pgpm_delta_trg', 'b57_pgpm_delta_trg', 'c57_pgpm_delta_trg')), 0,
  'and no capture trigger is left anywhere');

select * from finish();
