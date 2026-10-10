-- untransmute refuses while a partition of the parent is pending a concurrent detach (issue #1157).
--
-- THE BUG. A DETACH PARTITION ... CONCURRENTLY sets pg_inherits.inhdetachpending in a first transaction
-- that commits before it waits for older lockers of the parent, and from that commit on the partition's
-- rows are invisible through the parent. A detacher whose session dies in that wait leaves the partition
-- there, pending, for _detach_reap or the operator's FINALIZE. untransmute's one-way-door gate reads only
-- through the parent, so it saw no row outside the monolith and passed; the DROP of the parent then took
-- the pending partition with it, its rows destroyed, and pgpm.log recorded a plain 'untransmute'.
--
-- THE CONTRACT. untransmute refuses while any partition of the parent is pending detach, naming it and
-- the remedy (finish the detach, after which the partition is a table of the operator's), and leaves
-- everything as it was. Asked twice, like the gate: unlocked, and again under the ACCESS EXCLUSIVE it
-- takes on the parent, which is the answer acted on (a detach's first transaction needs SHARE UPDATE
-- EXCLUSIVE on the parent, so under that lock the flag can neither appear nor clear).
--
--   (A) the abandoned detach (the issue's reproduction): refused, rows kept, then the remedy works.
--   (B) a detach whose flag lands while untransmute waits for its lock, ordered by held locks only:
--       untransmute passes its unlocked checks, queues for ACCESS EXCLUSIVE behind a holder of SHARE
--       UPDATE EXCLUSIVE and behind the detach queued on that same lock; the holder commits, the detach
--       sets its flag and commits its first transaction, then waits on untransmute's own lock; untransmute
--       is granted its lock and must refuse there. bench/untransmute_pending_detach.sh runs this file
--       against the mutations that drop both checks (A) and only the one under the lock (B).
--
-- Every poll is server-side, clears the pg_stat_activity snapshot each turn, and names its backends by
-- application_name within this database, so a file running beside this one cannot satisfy it.
create extension if not exists pgtap;
create extension if not exists dblink;

select plan(27);

-- The ids in a table, read by name and NULL when no such table exists, so an assertion about a relation the
-- defect dropped reports instead of killing the file.
create function pg_temp.pd312_ids(p_name text) returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  if to_regclass(format('public.%I', p_name)) is null then return null; end if;
  execute format('select array_agg(id order by id) from public.%I', p_name) into v;
  return v;
end $f$;

-- ============================ (A) an abandoned concurrent detach ============================
create table public.pd312a (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.pd312a select i, now() - i * interval '1 hour' from generate_series(1, 20) i;
call pgpm.transmute('public.pd312a', 'ts', interval '1 day', p_obtain => 3);

-- the newest forward partition, and two rows written into it (two there, twenty in the monolith)
select child_name as fwd_a, lo as fwd_a_lo from pgpm.part
 where parent_table = 'public.pd312a'::regclass
   and child_oid <> (select monolith_oid from pgpm.config where parent_table = 'public.pd312a'::regclass)
 order by lo::timestamptz desc limit 1 \gset
insert into public.pd312a values (1001, :'fwd_a_lo'::timestamptz + interval '1 hour'),
                                 (1002, :'fwd_a_lo'::timestamptz + interval '2 hours');

-- an operator's DETACH ... CONCURRENTLY of it, parked in its wait phase on a reader's vxid, then killed
select dblink_connect('x312', 'dbname=' || current_database() || ' application_name=pd312_reader');
select dblink_connect('d312', 'dbname=' || current_database() || ' application_name=pd312a_detach');
select dblink_exec('x312', 'begin isolation level repeatable read');
select * from dblink('x312', 'select count(*) from public.pd312a') as t(n bigint);
select dblink_send_query('d312', format('alter table public.pd312a detach partition public.%I concurrently', :'fwd_a'));
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity
                       where datname = current_database() and application_name = 'pd312a_detach'
                         and wait_event = 'virtualxid');
    perform pg_sleep(0.05);
  end loop;
end $$;
select is((select count(*)::int from pg_stat_activity
            where datname = current_database() and application_name = 'pd312a_detach'
              and wait_event = 'virtualxid'),
          1, 'LIVENESS: the detach reached its wait phase, its flag committed');
select pg_terminate_backend(pid) from pg_stat_activity
 where datname = current_database() and application_name = 'pd312a_detach';
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when not exists (select 1 from pg_stat_activity
                           where datname = current_database() and application_name = 'pd312a_detach');
    perform pg_sleep(0.05);
  end loop;
end $$;
select dblink_exec('x312', 'commit');
select dblink_disconnect('x312');
select dblink_disconnect('d312');

select ok(exists (select 1 from pg_inherits where inhparent = 'public.pd312a'::regclass
                    and inhrelid = to_regclass(format('public.%I', :'fwd_a')) and inhdetachpending),
          'LIVENESS: the forward partition is pending detach under pd312a');
select is((select count(*)::int from pg_stat_activity
            where datname = current_database() and application_name = 'pd312a_detach'),
          0, 'LIVENESS: and its detacher is gone: abandoned, not live');
select is(pg_temp.pd312_ids(:'fwd_a'), array[1001, 1002]::bigint[],
          'LIVENESS: the pending partition holds rows 1001 and 1002');
select is((select count(*)::int from public.pd312a where id in (1001, 1002)), 0,
          'LIVENESS: which are invisible through the parent, all the outside-rows gate reads');

select throws_like(
  $$ select pgpm.untransmute('public.pd312a') $$,
  '%' || :'fwd_a' || '%pending a concurrent detach%DETACH PARTITION%FINALIZE%',
  'untransmute refuses, naming the pending partition and the FINALIZE that finishes it');

-- identity: which rows, where; and nothing else moved
select is(pg_temp.pd312_ids(:'fwd_a'), array[1001, 1002]::bigint[],
          'rows 1001 and 1002 are still in the pending partition');
select ok(exists (select 1 from pg_inherits where inhparent = to_regclass('public.pd312a')
                    and inhrelid = to_regclass(format('public.%I', :'fwd_a')) and inhdetachpending),
          'which is still pending detach under pd312a: the refusal changed nothing');
select is((select relkind::text from pg_class where oid = to_regclass('public.pd312a')), 'p',
          'pd312a is still the partitioned table');
select is((select count(*)::int from pgpm.config where parent_table = to_regclass('public.pd312a')), 1,
          'pgpm still manages it');
select is((select count(*)::int from pgpm.log
            where parent_table = to_regclass('public.pd312a') and action = 'untransmute'),
          0, 'and no untransmute was logged');

-- the remedy the refusal names: finish the detach; the partition is the operator's table from then on
select lives_ok(format('alter table public.pd312a detach partition public.%I finalize', :'fwd_a'),
                'the operator finishes the detach');
select lives_ok($$ select pgpm.untransmute('public.pd312a') $$,
                'and untransmute then goes through');
select is((select relkind::text from pg_class where oid = to_regclass('public.pd312a')), 'r',
          'pd312a is an ordinary table again');
select is(pg_temp.pd312_ids('pd312a'), (select array_agg(g::bigint order by g) from generate_series(1, 20) g),
          'holding exactly the original rows 1..20');
select is((select relkind::text || '/' || relispartition::text from pg_class
            where oid = to_regclass(format('public.%I', :'fwd_a'))), 'r/false',
          'the finished partition stands on its own');
select is(pg_temp.pd312_ids(:'fwd_a'), array[1001, 1002]::bigint[],
          'still holding rows 1001 and 1002');
select is((select count(*)::int from pgpm.log
            where parent_table = to_regclass('public.pd312a') and action = 'untransmute'),
          1, 'with the one reverse logged');

-- ============================ (B) the flag lands while untransmute waits for its lock ============================
-- H holds SHARE UPDATE EXCLUSIVE on the parent, which queues the detach; untransmute passes its unlocked
-- checks (nothing pending yet) and queues for ACCESS EXCLUSIVE behind both. When H commits, the detach is
-- granted first, sets its flag and commits, then waits on untransmute's own lock. The forward partition is
-- EMPTY here, and that is deliberate: within the one statement that read the parent before the flag landed,
-- the gate under the lock still reads through the pending partition (measured), so rows in it would be
-- refused as rows outside the monolith. Empty, nothing but the pending check stops the reverse, whose DROP
-- of the parent would take the partition the operator is detaching, and fail their detach.
create table public.pd312b (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.pd312b select i, now() - i * interval '1 hour' from generate_series(1, 30) i;
call pgpm.transmute('public.pd312b', 'ts', interval '1 day', p_obtain => 3);
select child_name as fwd_b from pgpm.part
 where parent_table = 'public.pd312b'::regclass
   and child_oid <> (select monolith_oid from pgpm.config where parent_table = 'public.pd312b'::regclass)
 order by lo::timestamptz desc limit 1 \gset

select dblink_connect('h312', 'dbname=' || current_database() || ' application_name=pd312_holder');
select dblink_exec('h312', 'begin');
select dblink_exec('h312', 'lock table public.pd312b in share update exclusive mode');
select dblink_connect('e312', 'dbname=' || current_database() || ' application_name=pd312b_detach');
select dblink_send_query('e312', format('alter table public.pd312b detach partition public.%I concurrently', :'fwd_b'));
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                       where a.datname = current_database() and a.application_name = 'pd312b_detach'
                         and l.locktype = 'relation' and l.relation = 'public.pd312b'::regclass
                         and l.mode = 'ShareUpdateExclusiveLock' and not l.granted);
    perform pg_sleep(0.05);
  end loop;
end $$;
select is((select count(*)::int from pg_locks l join pg_stat_activity a on a.pid = l.pid
            where a.datname = current_database() and a.application_name = 'pd312b_detach'
              and l.locktype = 'relation' and l.relation = 'public.pd312b'::regclass
              and l.mode = 'ShareUpdateExclusiveLock' and not l.granted),
          1, 'LIVENESS: the detach is queued on the parent behind the holder, its flag not yet set');

-- untransmute, in a session of its own: its unlocked checks see no pending partition and no row outside
-- the monolith, and it queues for ACCESS EXCLUSIVE. From here this session does not touch public.pd312b.
select dblink_connect('u312', 'dbname=' || current_database() || ' application_name=pd312_untransmute');
select dblink_send_query('u312', $$select pgpm.untransmute('public.pd312b')$$);
do $$
begin
  for i in 1 .. 600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                       where a.datname = current_database() and a.application_name = 'pd312_untransmute'
                         and l.locktype = 'relation' and l.relation = 'public.pd312b'::regclass
                         and l.mode = 'AccessExclusiveLock' and not l.granted);
    perform pg_sleep(0.05);
  end loop;
end $$;
select is((select count(*)::int from pg_locks l join pg_stat_activity a on a.pid = l.pid
            where a.datname = current_database() and a.application_name = 'pd312_untransmute'
              and l.locktype = 'relation' and l.relation = 'public.pd312b'::regclass
              and l.mode = 'AccessExclusiveLock' and not l.granted),
          1, 'LIVENESS: untransmute passed its unlocked checks and waits for ACCESS EXCLUSIVE on the parent');
select is((select count(*)::int from pg_inherits where inhparent = 'public.pd312b'::regclass and inhdetachpending),
          0, 'LIVENESS: no partition of pd312b was pending detach when it passed them');
-- release: the detach is granted first, sets its flag, commits, and waits on untransmute's own lock
select dblink_exec('h312', 'commit');
select dblink_disconnect('h312');
create function pg_temp.pd312_untransmute_result() returns text language plpgsql as $f$
declare v text;
begin
  select r into v from dblink_get_result('u312') as t(r text);
  perform * from dblink_get_result('u312') as t(r text);   -- drain the end of the result stream
  return 'returned ' || coalesce(v, 'null');
exception when others then
  return 'raised: ' || sqlerrm;
end $f$;
select pg_temp.pd312_untransmute_result() as u_result \gset
select ok(:'u_result' like '%' || :'fwd_b' || '%pending a concurrent detach%DETACH PARTITION%FINALIZE%',
          'untransmute, granted its lock after the flag landed, refuses there: ' || :'u_result');
select dblink_disconnect('u312');
create function pg_temp.pd312_detach_result() returns text language plpgsql as $f$
begin
  perform * from dblink_get_result('e312') as t(r text);
  return 'completed';
exception when others then
  return 'raised: ' || sqlerrm;
end $f$;
select is(pg_temp.pd312_detach_result(), 'completed', 'the detach it waited on then completes');
select dblink_disconnect('e312');

select is((select relkind::text || '/' || relispartition::text from pg_class
            where oid = to_regclass(format('public.%I', :'fwd_b'))), 'r/false',
          'the partition it detached stands on its own');
select is((select relkind::text from pg_class where oid = to_regclass('public.pd312b')), 'p',
          'pd312b is still the partitioned table: the refusal rolled the call back');
select is(pg_temp.pd312_ids('pd312b'), (select array_agg(g::bigint order by g) from generate_series(1, 30) g),
          'holding exactly its rows 1..30');
select is((select count(*)::int from pgpm.log
            where parent_table = to_regclass('public.pd312b') and action = 'untransmute'),
          0, 'and no untransmute was logged');

select * from finish();
