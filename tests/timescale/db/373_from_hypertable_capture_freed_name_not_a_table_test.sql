-- from_hypertable_copy's change capture follows its delta when the freed name goes to a relation LOCK TABLE
-- cannot take (issue #1061, the hypertable twin).
--
-- THE DEFECT. The capture function's fast path (#1057) takes `lock table only <minted name> in row exclusive
-- mode` through the name the writer is about to use, and on undefined_table, invalid_schema_name or
-- insufficient_privilege falls through to the oid path, which renders the recorded delta's current name. A
-- writer that queued on that lock while an operator's transaction renamed the delta and gave the freed name to
-- a MATERIALIZED VIEW or a SEQUENCE met, once the rename committed, LOCK TABLE re-resolving the name to that
-- relation and raising wrong_object_type (42809, 'cannot lock relation ...'), which nothing caught: the write
-- to the live hypertable died instead of being captured in the renamed delta, where docs/reference.md says a
-- write that waits behind a pending rename "then writes the delta where it now is". Now the handler catches
-- 42809 too, in the fast path and in the oid path's retry.
--
-- THE LEVER, deterministic, as tests/timescale/db/57's (whose bridge-address note applies): a second session
-- (the operator) renames the recorded delta and, in the same transaction, waits until it sees the writer
-- queued on the delta's lock; only then does it create its relation under the freed name and commit. The
-- writer (a third session) is sent only once the operator is seen holding ACCESS EXCLUSIVE on the delta.
--
-- ASYMMETRIC FIXTURE. Two hypertables with a tracking copy each, values device_id * 10.
--   m373 (5 devices): rename + a materialized view under the freed name; the write updates device 2.
--   s373 (3 devices): rename + a sequence under the freed name; the write deletes device 3 and inserts 300001.
-- Each delta's keys are asserted by identity, and each cutover by the rows it leaves, by device and value.
-- bench/hypertable_capture_freed_name_not_a_table.sh runs this file against the mutant that drops 42809 from
-- the fast path's handler again (hypertable_capture_lock_wrong_type_uncaught), so it is required to FAIL there.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t373.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(14);

select mk_keyed_hypertable('m373', 5, '1 day', '4 days');
select mk_keyed_hypertable('s373', 3, '1 day', '4 days');
update m373 set temp = device_id * 10;
update s373 set temp = device_id * 10;
call pgpm.from_hypertable_copy('m373'::regclass, 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('s373'::regclass, 'ts', p_track_changes => true);

select is(pgpm._from_hypertable_scratch('m373'::regclass, 'hypertable_delta')::text
          || ',' || pgpm._from_hypertable_scratch('s373'::regclass, 'hypertable_delta')::text,
          'm373_pgpm_delta,s373_pgpm_delta',
          'LIVENESS: each tracking copy minted and recorded its delta under its own name');

-- The recorded oids, before anything is renamed, so every later read is by identity.
create table public.r373_delta (parent text primary key, delta oid);
insert into public.r373_delta
  select t, s.obj from unnest(array['m373', 's373']) t
    join pgpm.scratch s on s.parent_oid = t::regclass::oid and s.kind = 'hypertable_delta';
create table public.r373_seen (parent text primary key, writer_pid int);
create table public.r373_outcome (parent text, who text, state text, msg text, primary key (parent, who));

-- One race (see tests/290's pg_temp.race): each side sends ONE statement, because dblink_get_result returns
-- the first result of a multi-statement string and an error in a later one would go unread. p_take is the DDL
-- that takes the freed name, %1$I standing for it.
create function pg_temp.race(p_parent text, p_take text, p_writer_sql text) returns void language plpgsql as $f$
declare
  v_delta oid := (select delta from public.r373_delta where parent = p_parent);
  v_wpid int; v_opid int; v_held boolean := false;
begin
  perform dblink_connect('r373_op', current_setting('t373.connstr'));
  perform dblink_connect('r373_w', current_setting('t373.connstr'));
  select pid into v_opid from dblink('r373_op', 'select pg_backend_pid()') as t(pid int);
  select pid into v_wpid from dblink('r373_w', 'select pg_backend_pid()') as t(pid int);
  perform dblink_send_query('r373_op', format($op$
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
      insert into public.r373_seen values (%5$L, %3$s);
      %6$s;
    end $x$
    $op$, p_parent || '_pgpm_delta', p_parent || '_renamed_delta', v_wpid, v_delta, p_parent,
          format(p_take, p_parent || '_pgpm_delta')));
  for i in 1 .. 4000 loop
    v_held := exists (select 1 from pg_locks where pid = v_opid and relation = v_delta
                       and mode = 'AccessExclusiveLock' and granted);
    exit when v_held;
    perform pg_sleep(0.005);
  end loop;
  if v_held then
    perform dblink_send_query('r373_w', p_writer_sql);
  end if;
  begin
    perform * from dblink_get_result('r373_op') as t(x text);
    insert into public.r373_outcome values (p_parent, 'operator', '00000', null);
  exception when others then
    insert into public.r373_outcome values (p_parent, 'operator', sqlstate, left(sqlerrm, 200));
  end;
  if v_held then
    begin
      perform * from dblink_get_result('r373_w') as t(x text);
      insert into public.r373_outcome values (p_parent, 'writer', '00000', null);
    exception when others then
      insert into public.r373_outcome values (p_parent, 'writer', sqlstate, left(sqlerrm, 200));
    end;
  else
    insert into public.r373_outcome values (p_parent, 'writer', 'never sent', 'the operator was never seen holding the delta');
  end if;
  perform dblink_disconnect('r373_op');
  perform dblink_disconnect('r373_w');
end $f$;

select pg_temp.race('m373', 'create materialized view public.%1$I as select 1::bigint as device_id',
  $w$update public.m373 set temp = 777 where device_id = 2$w$);
select pg_temp.race('s373', 'create sequence public.%1$I',
  $w$do $d$ begin
       delete from public.s373 where device_id = 3;
       insert into public.s373 (ts, device_id, temp) values (now() - interval '1 hour', 300001, 1.0);
     end $d$$w$);

-- ==================== the witnesses: each race happened as the defect needs it ====================
select is((select string_agg(s.parent || ':' || (s.writer_pid is not null)::text, ',' order by s.parent) from public.r373_seen s),
  'm373:true,s373:true', 'LIVENESS: in each race the operator saw the writer queued on the delta before it committed');
select is((select string_agg(o.parent || ':' || o.state || coalesce(' ' || o.msg, ''), ',' order by o.parent)
             from public.r373_outcome o where o.who = 'operator'),
  'm373:00000,s373:00000', 'GUARD: each operator''s rename and take of the name committed');
select is((select string_agg(d.parent || '=' || c.relname, ',' order by d.parent) from public.r373_delta d join pg_class c on c.oid = d.delta),
  'm373=m373_renamed_delta,s373=s373_renamed_delta',
  'LIVENESS: each recorded delta is the same relation, renamed');
select is((select string_agg(c.relname || ':' || c.relkind::text, ',' order by c.relname) from pg_class c
            where c.oid in (to_regclass('public.m373_pgpm_delta'), to_regclass('public.s373_pgpm_delta'))),
  'm373_pgpm_delta:m,s373_pgpm_delta:S',
  'LIVENESS: the freed names now name a materialized view and a sequence, which LOCK TABLE cannot take');
create function pg_temp.lock_code(p_name text) returns text language plpgsql as $f$
begin
  execute format('lock table only %s in row exclusive mode', p_name);
  return '00000';
exception when others then
  return sqlstate;
end $f$;
select is(pg_temp.lock_code('public.m373_pgpm_delta') || ',' || pg_temp.lock_code('public.s373_pgpm_delta'), '42809,42809',
  'LIVENESS: the lock the capture takes through the freed name raises wrong_object_type on each of them');

-- ==================== the contract: every write goes on, into the recorded delta ====================
select is((select state || coalesce(' ' || msg, '') from public.r373_outcome where parent = 'm373' and who = 'writer'),
  '00000', 'm373: the write that queued behind the rename and the materialized view succeeds (#1061)');
select is((select state || coalesce(' ' || msg, '') from public.r373_outcome where parent = 's373' and who = 'writer'),
  '00000', 's373: the write that queued behind the rename and the sequence succeeds');
select is((select string_agg(device_id::text, ',' order by device_id, pgpm_seq) from public.m373_renamed_delta), '2,2',
  'm373: the update''s keys are captured in the recorded (renamed) delta');
select is((select string_agg(device_id::text, ',' order by device_id, pgpm_seq) from public.s373_renamed_delta), '3,300001',
  's373: the delete''s and the insert''s keys are captured in the recorded (renamed) delta');

-- ==================== the cutover honours every captured write, by row ====================
call pgpm.from_hypertable_cutover('m373'::regclass, 'ts', interval '1 day', p_paused => true);
call pgpm.from_hypertable_cutover('s373'::regclass, 'ts', interval '1 day', p_paused => true);
select is((select string_agg(relkind::text, '/' order by relname) from pg_class where oid in ('m373'::regclass, 's373'::regclass)),
  'p/p', 'LIVENESS: each hypertable was cut over to a partitioned table');
select is((select string_agg(device_id || '=' || temp, ',' order by device_id) from m373),
  '1=10,2=777,3=30,4=40,5=50', 'm373 keeps the committed update of device 2 after the cutover');
select is((select string_agg(device_id || '=' || temp, ',' order by device_id) from s373),
  '1=10,2=20,300001=1', 's373 keeps the delete of device 3 and the insert of 300001 after the cutover');
select is((select string_agg(c.relname || ':' || c.relkind::text, ',' order by c.relname) from pg_class c
            where c.oid in (to_regclass('public.m373_pgpm_delta'), to_regclass('public.s373_pgpm_delta'))),
  'm373_pgpm_delta:m,s373_pgpm_delta:S', 'the operator''s materialized view and sequence survive the cutover untouched');

select * from finish();
