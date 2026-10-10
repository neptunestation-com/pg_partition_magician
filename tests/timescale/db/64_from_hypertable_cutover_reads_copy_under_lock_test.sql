-- from_hypertable_cutover reads the copy only under a lock that keeps every drain out of it until the swap,
-- and a drain takes the copy first, so the two never deadlock (issue #1158).
--
-- THE DEFECT. The cutover read the copy's catch-up watermark and its conservation baseline (count and content
-- fingerprint) BEFORE it locked anything, on the stated assumption that the copy was private from there to
-- the lock. The drains, which the reference says may be driven directly during the two-phase window, take no
-- lock the cutover took. So a drain batch that committed between that read and the swap lock was in the copy
-- twice over on a keyless hypertable: the catch-up re-inserted everything past the stale watermark (a strict
-- `>`, no anti-join), the baseline plus the catch-up agreed with the source by count and by fingerprint, and
-- the swap went ahead with those rows doubled. On a tracking copy the same window left the baseline stale and
-- the conservation check refused a cutover with nothing wrong in it.
--
-- THE CONTRACT. The cutover takes SHARE on the copy before it reads it and holds it to the swap (SHARE
-- excludes every writer and nothing that only reads), so a drain batch in flight is waited for and read, and
-- a drain called later waits for the swap and then fails, the copy gone. A drain takes the copy (ROW
-- EXCLUSIVE) before it reads or writes anything else in a transaction, so it never holds the source or the
-- delta while it waits for the copy, which is what the cutover needs next.
--
-- THE INSTRUMENT. Deterministic, not timed. The drain (session b64) and the cutover (a64) are dblink sessions,
-- and a third session (c64) holds a read of the source when the cutover has to be stopped part-way. Each step
-- waits until the session before it is SEEN in pg_locks waiting for, or holding, what the step needs. They
-- connect to the container's bridge address, as tests/timescale/db/57 explains.
--
-- ASYMMETRIC FIXTURE. Four hypertables, each cut over with p_predrain => false so the drain under test is the
-- only one.
--   (K) k64, keyless, no index: 4 rows copied, 100 and 101 appended; a drain step copies those two and holds
--       its transaction open until the cutover is seen waiting; 102 is appended after it. The cutover keeps
--       1,2,3,4,100,101,102, each once.
--   (T) t64, keyed, tracking: 6 devices copied, then device 2 updated, device 3 deleted and 9001 inserted; a
--       delta drain step reconciles those three keys and holds its transaction open the same way. The cutover
--       goes through (no stale baseline to refuse on) and keeps each write.
--   (D) d64, keyless, no index: 3 rows copied, 200 and 201 appended; the cutover is held at the source's
--       lock by c64's read, then from_hypertable_drain_appends is called. The drain waits for the copy, the
--       cutover goes through with 1,2,3,200,201 each once, and the drain then fails 42P01 (the copy is gone).
--   (E) e64, keyed, tracking: 5 devices copied, device 4 updated; the same as (D) with
--       from_hypertable_drain_delta_step. Its delta deletes must not come before its wait for the copy, or the
--       cutover deadlocks on the delta.
-- bench/hypertable_cutover_reads_copy_under_lock.sh runs this file against the mutants that put the defect
-- back (hypertable_cutover_reads_copy_unlocked) and that let a drain read before it takes the copy
-- (hypertable_drain_appends_reads_before_copy_lock, hypertable_drain_delta_step_takes_delta_first), so it is
-- required to FAIL there.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t64.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(21);

-- ==================== fixtures ====================
create table k64 (ts timestamptz not null, v int not null);
select create_hypertable('k64', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into k64 select now() - g * interval '5 hours', g from generate_series(1, 4) g;
create table d64 (ts timestamptz not null, v int not null);
select create_hypertable('d64', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false) \g /dev/null
insert into d64 select now() - g * interval '5 hours', g from generate_series(1, 3) g;
select mk_keyed_hypertable('t64', 6, '1 day', '4 days');
select mk_keyed_hypertable('e64', 5, '1 day', '4 days');
update t64 set temp = device_id * 10;
update e64 set temp = device_id * 10;
call pgpm.from_hypertable_copy('k64'::regclass, 'ts');
call pgpm.from_hypertable_copy('d64'::regclass, 'ts');
call pgpm.from_hypertable_copy('t64'::regclass, 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('e64'::regclass, 'ts', p_track_changes => true);
-- the writes of the online window, each past the copy (in control order on the keyless ones)
insert into k64 values (now() - interval '30 minutes', 100), (now() - interval '20 minutes', 101);
insert into d64 values (now() - interval '30 minutes', 200), (now() - interval '20 minutes', 201);
update t64 set temp = 777 where device_id = 2;
delete from t64 where device_id = 3;
insert into t64 (ts, device_id, temp) values (now() - interval '1 hour', 9001, 1);
update e64 set temp = 444 where device_id = 4;

-- Each table's source and recorded copy, by oid, before anything is swapped.
create table public.r64_rel (parent text primary key, src oid, dest oid);
insert into public.r64_rel
  select t, t::regclass::oid, s.obj from unnest(array['k64', 't64', 'd64', 'e64']) t
    join pgpm.scratch s on s.parent_oid = t::regclass::oid and s.kind = 'hypertable_dest';
create table public.r64_pid (conn text primary key, pid int);
create table public.r64_seen (what text primary key, saw text);

select dblink_connect(c, current_setting('t64.connstr')) from unnest(array['a64', 'b64', 'c64']) c \g /dev/null
insert into public.r64_pid select c, p.pid from unnest(array['a64', 'b64', 'c64']) c,
  lateral dblink(c, 'select pg_backend_pid()') as p(pid int);

-- What one session is seen waiting for, polled until it is seen or p_done says it finished without waiting.
-- pg_locks is read afresh on every call (it is not a statistics snapshot), and this statement takes no lock
-- on any table the sessions use.
create function pg_temp.waiting(p_conn text, p_what text) returns text language plpgsql as $f$
declare v_pid int := (select pid from public.r64_pid where conn = p_conn); v_saw text;
begin
  for i in 1 .. 6000 loop
    select l.mode || ' on ' || coalesce(r.parent || case when l.relation = r.src then '' else '_copy' end,
                                        l.relation::regclass::text)
      into v_saw
      from pg_locks l left join public.r64_rel r on l.relation in (r.src, r.dest)
     where l.pid = v_pid and not l.granted and l.locktype = 'relation'
     limit 1;
    exit when v_saw is not null;
    if dblink_is_busy(p_conn) = 0 then v_saw := 'nothing (it finished)'; exit; end if;
    perform pg_sleep(0.005);
  end loop;
  insert into public.r64_seen values (p_what, coalesce(v_saw, 'nothing (timed out)'));
  return v_saw;
end $f$;

-- The outcome of a statement sent with dblink_send_query: its SQLSTATE, and the message on an error.
create function pg_temp.outcome(p_conn text) returns text language plpgsql as $f$
begin
  perform * from dblink_get_result(p_conn) as t(x text);
  perform * from dblink_get_result(p_conn) as t(x text);   -- the empty result that ends the query
  return '00000';
exception when others then
  declare v_out text := sqlstate || ' ' || left(sqlerrm, 160);
  begin
    begin
      perform * from dblink_get_result(p_conn) as t(x text);   -- the same end-of-query result, after an error
    exception when others then null;
    end;
    return v_out;
  end;
end $f$;

-- ==================== (K) a keyless drain batch in flight when the cutover starts ====================
select set_config('t64.k_wm', (select pgpm._from_hypertable_ctl_text(max(ts)) from k64_pgpm_dest), false) \g /dev/null
select dblink_exec('b64', 'begin') \g /dev/null
select set_config('t64.k_step', w, false)
  from dblink('b64', format('select pgpm.from_hypertable_drain_appends_step(%L::regclass, %L, 1000, %L)',
                            'public.k64', 'ts', current_setting('t64.k_wm'))) as t(w text) \g /dev/null
insert into k64 values (now() - interval '10 minutes', 102);
select dblink_send_query('a64', $q$call pgpm.from_hypertable_cutover('public.k64'::regclass, 'ts', interval '1 day',
  p_predrain => false, p_lock_timeout => '60s')$q$) \g /dev/null
select pg_temp.waiting('a64', 'K: the cutover, with the drain batch uncommitted') \g /dev/null
select dblink_exec('b64', 'commit') \g /dev/null
select set_config('t64.k_out', pg_temp.outcome('a64'), false) \g /dev/null

select ok(current_setting('t64.k_step')::timestamptz > current_setting('t64.k_wm')::timestamptz,
  'LIVENESS: (K) the drain batch copied the appends into the copy (its watermark moved past the copy''s)');
select is((select saw from public.r64_seen where what = 'K: the cutover, with the drain batch uncommitted'),
  'ShareLock on k64_copy',
  '(K) the cutover waited for the copy (SHARE) while the drain batch was uncommitted, before reading it');
select is(current_setting('t64.k_out'), '00000', '(K) the cutover went through');
select is((select string_agg(v::text, ',' order by v) from k64), '1,2,3,4,100,101,102',
  '(K) the migrated table holds each row once: the drained batch is not caught up a second time');

-- ==================== (T) a tracking drain batch in flight when the cutover starts ====================
select dblink_exec('b64', 'begin') \g /dev/null
select set_config('t64.t_step', n::text, false)
  from dblink('b64', 'select pgpm.from_hypertable_drain_delta_step(''public.t64''::regclass, ''ts'', 5000)') as t(n bigint) \g /dev/null
select dblink_send_query('a64', $q$call pgpm.from_hypertable_cutover('public.t64'::regclass, 'ts', interval '1 day',
  p_predrain => false, p_lock_timeout => '60s')$q$) \g /dev/null
select pg_temp.waiting('a64', 'T: the cutover, with the drain batch uncommitted') \g /dev/null
select dblink_exec('b64', 'commit') \g /dev/null
select set_config('t64.t_out', pg_temp.outcome('a64'), false) \g /dev/null

select is(current_setting('t64.t_step'), '3',
  'LIVENESS: (T) the drain batch reconciled the three keys the window wrote (2, 3 and 9001)');
select is((select saw from public.r64_seen where what = 'T: the cutover, with the drain batch uncommitted'),
  'ShareLock on t64_copy',
  '(T) the cutover waited for the copy (SHARE) while the drain batch was uncommitted, before reading it');
select is(current_setting('t64.t_out'), '00000', '(T) the cutover went through (its baseline holds the drained batch)');
select is((select string_agg(device_id || '=' || temp, ',' order by device_id) from t64),
  '1=10,2=777,4=40,5=50,6=60,9001=1', '(T) the migrated table keeps the update, the delete and the insert');

-- ==================== (D) from_hypertable_drain_appends called while the cutover holds the copy ====================
select dblink_exec('c64', 'begin') \g /dev/null
select n from dblink('c64', 'select count(*) from public.d64') as t(n bigint) \g /dev/null
select dblink_send_query('a64', $q$call pgpm.from_hypertable_cutover('public.d64'::regclass, 'ts', interval '1 day',
  p_predrain => false, p_lock_timeout => '60s')$q$) \g /dev/null
select pg_temp.waiting('a64', 'D: the cutover, behind the reader') \g /dev/null
select dblink_send_query('b64', $q$call pgpm.from_hypertable_drain_appends('public.d64'::regclass, 'ts')$q$) \g /dev/null
select pg_temp.waiting('b64', 'D: the drain, with the cutover holding the copy') \g /dev/null
select dblink_exec('c64', 'commit') \g /dev/null
select set_config('t64.d_out_a', pg_temp.outcome('a64'), false) \g /dev/null
select set_config('t64.d_out_b', pg_temp.outcome('b64'), false) \g /dev/null

select is((select saw from public.r64_seen where what = 'D: the cutover, behind the reader'),
  'AccessExclusiveLock on d64',
  'LIVENESS: (D) the cutover was held at the source''s lock by the reader, with the copy read');
select is((select saw from public.r64_seen where what = 'D: the drain, with the cutover holding the copy'),
  'RowExclusiveLock on d64_copy',
  '(D) the drain waited for the copy before it read anything');
select is(current_setting('t64.d_out_a'), '00000', '(D) the cutover went through (no deadlock with the drain)');
select is(left(current_setting('t64.d_out_b'), 5), '42P01', '(D) the drain then failed: the copy it waited for is gone');
select is((select string_agg(v::text, ',' order by v) from d64), '1,2,3,200,201',
  '(D) the migrated table holds each row once');

-- ==================== (E) from_hypertable_drain_delta_step called while the cutover holds the copy ====================
select dblink_exec('c64', 'begin') \g /dev/null
select n from dblink('c64', 'select count(*) from public.e64') as t(n bigint) \g /dev/null
select dblink_send_query('a64', $q$call pgpm.from_hypertable_cutover('public.e64'::regclass, 'ts', interval '1 day',
  p_predrain => false, p_lock_timeout => '60s')$q$) \g /dev/null
select pg_temp.waiting('a64', 'E: the cutover, behind the reader') \g /dev/null
select dblink_send_query('b64', $q$select pgpm.from_hypertable_drain_delta_step('public.e64'::regclass, 'ts', 5000)$q$) \g /dev/null
select pg_temp.waiting('b64', 'E: the drain, with the cutover holding the copy') \g /dev/null
select dblink_exec('c64', 'commit') \g /dev/null
select set_config('t64.e_out_a', pg_temp.outcome('a64'), false) \g /dev/null
select set_config('t64.e_out_b', pg_temp.outcome('b64'), false) \g /dev/null

select is((select saw from public.r64_seen where what = 'E: the cutover, behind the reader'),
  'AccessExclusiveLock on e64',
  'LIVENESS: (E) the cutover was held at the source''s lock by the reader, with the copy read');
select is((select saw from public.r64_seen where what = 'E: the drain, with the cutover holding the copy'),
  'RowExclusiveLock on e64_copy',
  '(E) the drain step waited for the copy before it touched the delta');
select is(current_setting('t64.e_out_a'), '00000', '(E) the cutover went through (no deadlock on the delta)');
select is(left(current_setting('t64.e_out_b'), 5), '42P01', '(E) the drain step then failed: the copy it waited for is gone');
select is((select string_agg(device_id || '=' || temp, ',' order by device_id) from e64),
  '1=10,2=20,3=30,4=444,5=50', '(E) the migrated table keeps the update');

-- ==================== every cutover swapped in the recorded copy ====================
select is((select string_agg(r.parent || '=' || c.relkind::text || ':' || (to_regclass('public.' || r.parent) = r.dest::regclass)::text, ',' order by r.parent)
             from public.r64_rel r join pg_class c on c.oid = to_regclass('public.' || r.parent)),
  'd64=p:false,e64=p:false,k64=p:false,t64=p:false',
  'LIVENESS: each hypertable was cut over to a partitioned table (its copy now the monolith under it)');
select is((select string_agg(r.parent, ',' order by r.parent) from public.r64_rel r
            where exists (select 1 from pg_inherits i where i.inhrelid = r.dest and i.inhparent = to_regclass('public.' || r.parent))),
  'd64,e64,k64,t64', 'each recorded copy is the monolith partition of the table that took its hypertable''s name');
select ok(not exists (select 1 from pg_class c join public.r64_rel r on c.oid = r.src),
  'each hypertable is gone');

select dblink_disconnect(c) from unnest(array['a64', 'b64', 'c64']) c \g /dev/null
select * from finish();
