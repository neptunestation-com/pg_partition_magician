-- Both archive paths hold the parent before they read a candidate, and ask again under that hold, so a DETACH
-- PARTITION in flight when they chose it is waited out and the table it detached is left alone (issue #1159,
-- the per-PR verification's V-01).
--
-- THE BUG. pgpm._archive_step and scripts/archive_partition_whole.sql ask pgpm._part_detached_by_hand only in
-- their candidate query, under that statement's snapshot, and nothing they did locked the parent. An operator's
-- DETACH PARTITION holding the parent's (and the partition's) ACCESS EXCLUSIVE, uncommitted, when the query ran
-- was invisible to it, so the table was still a candidate. The first read of it (the step's chunk sizing, the
-- script's strategy) waited on the detach's lock; once the detach committed, a strategy reading through the
-- parent found none of the table's rows, returned covered_hi = hi, and [lo, hi) was recorded as covered with 0
-- rows. Attached back (the remedy docs/reference.md gives), retain() dropped rows nothing had archived. The
-- order is set by held locks, not by timing.
--
-- THE CONTRACT. pgpm._archive_hold_partition takes ACCESS SHARE on the parent, which waits out a detach in
-- flight, and asks the catalog as of that lock whether the candidate is still the parent's partition. A table
-- that left while the call waited is never handed to the strategy and no coverage is recorded for it.
--   PART A  the script, READ COMMITTED: the call waits on the detach's lock, the detach commits, the call
--           returns a message naming the table; no strategy call, no ledger row; the next call archives
--           [100, 200); attached back, retain() keeps ids 7, 42 and 88.
--   PART B  _archive_step, READ COMMITTED, no lock_timeout: the same, the step returning 0; its next call
--           archives [100, 200).
--   PART C  _archive_step under maintain()'s 200 ms lock_timeout, the detach held past it: a longer wait is a
--           skip, skip_archive over [0, 100) with the lock timeout as its reason, nothing recorded.
--   PART D  the script under REPEATABLE READ, its snapshot taken before the detach committed: the question is
--           asked of the catalog as of the lock, not of that snapshot, so the table is still left alone.
--
-- THE RACE needs two more sessions, which a pgTAP file gets through dblink, the way tests/109 does: a DETACH
-- connection opens the detach and holds it; an ARCHIVE connection runs the call asynchronously
-- (dblink_send_query); this session polls pg_locks until the call is seen waiting for a lock on the parent or
-- the partition (both held by the detach), then commits the detach and collects the call's result. No sleep is
-- load-bearing: the detach holds until told. While the call waits this session reads pg_locks and
-- pg_stat_activity only, never the table (a read would queue behind the detach's lock).
--
-- ASYMMETRIC FIXTURES. Each part's table: [0, 100) holds ids 7, 42 and 88 (3 rows, the one detached),
-- [100, 200) holds ids 150 and 160 (2 rows). Every strategy call is recorded with the ids it read.
--
-- bench/archive_hold_detach_in_flight.sh runs this file against a copy of pgpm_core/install.sql or of the
-- script with bench/mutations/mutate.py's archive_hold_unlocked, archive_hold_recheck_by_snapshot,
-- archive_step_hold_skipped and archive_whole_hold_skipped. The script's path is the psql variable
-- archive_whole_script, defaulting to the tree's copy, so the guard can point it at a mutant.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

\if :{?archive_whole_script}
\else
\set archive_whole_script /repo/scripts/archive_partition_whole.sql
\endif
\i :archive_whole_script

select plan(34);

create schema t325;
create table t325.calls (n serial primary key, parent regclass, p_child name, p_lo text, p_hi text, seen text);

-- reads [lo, hi) through the PARENT, as pgpm_archive's archive_to_s3_* do, and records what it saw
create function t325.via_parent(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_seen text; v_n bigint;
begin
  execute format('select string_agg(id::text, '','' order by id), count(*) from %s where id >= %L::bigint and id < %L::bigint',
                 p_parent, p_lo, p_hi)
    into v_seen, v_n;
  insert into t325.calls (parent, p_child, p_lo, p_hi, seen) values (p_parent, p_child, p_lo, p_hi, coalesce(v_seen, 'none'));
  v.covered_hi := p_hi; v.rows_archived := v_n; v.s3_key := 't325/' || p_lo;
  return v;
end $$;

-- One table per part, the same shape each: [0, 100) ids 7, 42, 88; [100, 200) ids 150, 160; horizon 200, so
-- both are write-blocked and uncovered.
do $$
declare t text;
begin
  foreach t in array array['t325_wh', 't325_st', 't325_lt', 't325_rr'] loop
    execute format('create table public.%I (id bigint primary key, payload text)', t);
    execute format($q$insert into public.%I values (7, 'a'), (42, 'b'), (88, 'c')$q$, t);
    call pgpm.transmute(format('public.%I', t)::regclass, 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
    execute format($q$insert into public.%I values (150, 'd'), (160, 'e'), (500, 'frontier')$q$, t);
    perform pgpm._enforce_write_blocks(format('public.%I', t)::regclass);
    perform pgpm.set_archive_fn(format('public.%I', t)::regclass, 't325.via_parent(regclass,name,text,text)'::regprocedure);
    commit;
  end loop;
end $$;

-- The race. Opens the detach of p_child and holds it; runs p_call in the archive session (under p_lock_timeout
-- when given, inside a REPEATABLE READ transaction whose snapshot predates the detach's commit when p_rr);
-- polls for the call's lock wait; then, with no lock_timeout, commits the detach and collects the call's
-- result, and with one, collects the result first (the call gives up while the detach still holds) and
-- commits the detach after. Returns what the witnesses need.
create function t325.race(p_parent regclass, p_child name, p_call text, p_rr boolean, p_lock_timeout text,
                          out detach_held boolean, out call_waited boolean, out result text)
language plpgsql as $$
declare v_child oid;
begin
  call_waited := false;
  perform dblink_connect('d325', 'dbname=' || current_database());
  perform dblink_exec('d325', $q$set application_name = 'd325_detach'$q$);
  perform dblink_exec('d325', 'begin');
  perform dblink_exec('d325', format('alter table %s detach partition public.%I', p_parent, p_child));
  select c.oid into v_child from pg_class c where c.relname = p_child and c.relnamespace = 'public'::regnamespace;
  perform pg_stat_clear_snapshot();
  detach_held := exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                          where a.application_name = 'd325_detach' and l.locktype = 'relation'
                            and l.relation = p_parent and l.mode = 'AccessExclusiveLock' and l.granted);

  perform dblink_connect('a325', 'dbname=' || current_database());
  perform dblink_exec('a325', $q$set application_name = 'a325_archive'$q$);
  if p_lock_timeout is not null then
    perform dblink_exec('a325', format('set lock_timeout = %L', p_lock_timeout));
  end if;
  if p_rr then
    perform dblink_exec('a325', 'begin isolation level repeatable read');
    perform * from dblink('a325', 'select count(*) from pgpm.part') as t(n bigint);   -- the snapshot, taken now
  end if;
  perform dblink_send_query('a325', p_call);

  -- bounded at 30 s, so a broken fixture fails rather than hangs; each turn its own pg_stat_activity snapshot
  for i in 1 .. 3000 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                where a.application_name = 'a325_archive' and l.locktype = 'relation'
                  and l.relation in (p_parent::oid, v_child) and not l.granted) then
      call_waited := true;
    end if;
    exit when (call_waited and p_lock_timeout is null) or dblink_is_busy('a325') = 0;
    perform pg_sleep(0.01);
  end loop;

  if p_lock_timeout is null then
    perform dblink_exec('d325', 'commit');
    select r into result from dblink_get_result('a325') as t(r text);
  else
    select r into result from dblink_get_result('a325') as t(r text);
    perform dblink_exec('d325', 'commit');
  end if;
  perform * from dblink_get_result('a325') as t(r text);   -- drain the empty result that ends the query
  if p_rr then perform dblink_exec('a325', 'commit'); end if;
  perform dblink_disconnect('a325');
  perform dblink_disconnect('d325');
end $$;

select child_name as wh0 from pgpm.part where parent_table = 'public.t325_wh'::regclass and lo = '0'   \gset
select child_name as wh1 from pgpm.part where parent_table = 'public.t325_wh'::regclass and lo = '100' \gset
select child_name as st0 from pgpm.part where parent_table = 'public.t325_st'::regclass and lo = '0'   \gset
select child_name as st1 from pgpm.part where parent_table = 'public.t325_st'::regclass and lo = '100' \gset
select child_name as lt0 from pgpm.part where parent_table = 'public.t325_lt'::regclass and lo = '0'   \gset
select child_name as rr0 from pgpm.part where parent_table = 'public.t325_rr'::regclass and lo = '0'   \gset

select ok(pgpm._is_write_blocked('public.t325_wh', :'wh0') and not pgpm._archive_fully_covered('public.t325_wh', :'wh0')
          and pgpm._is_write_blocked('public.t325_st', :'st0') and not pgpm._archive_fully_covered('public.t325_st', :'st0')
          and pgpm._is_write_blocked('public.t325_lt', :'lt0') and not pgpm._archive_fully_covered('public.t325_lt', :'lt0')
          and pgpm._is_write_blocked('public.t325_rr', :'rr0') and not pgpm._archive_fully_covered('public.t325_rr', :'rr0'),
  'LIVENESS: in every part [0, 100) is write-blocked and uncovered, the oldest candidate');

-- ---------------------------------------------------------------- PART A: the script, READ COMMITTED
select * from t325.race('public.t325_wh', :'wh0',
  $$select pgpm_archive_next_partition_whole('public.t325_wh'::regclass)$$, false, null) \gset a_
select diag('A: ' || :'a_result');
select ok(:'a_detach_held'::boolean, 'LIVENESS: A: the operator''s DETACH held the parent''s lock, uncommitted, when the call started');
select ok(:'a_call_waited'::boolean, 'LIVENESS: A: the call was seen waiting for a lock the detach held, so it chose its candidate before the detach committed');
select ok((select pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
             from pgpm.part p where p.parent_table = 'public.t325_wh'::regclass and p.child_name = :'wh0'),
  'LIVENESS: A: once committed, [0, 100) is detached by hand');
select is_empty($$ select 1 from t325.calls where parent = 'public.t325_wh'::regclass $$,
  'A: the strategy was handed nothing: not the table that left while the call waited');
select is_empty($$ select 1 from pgpm.archive_ledger where parent_table = 'public.t325_wh'::regclass $$,
  'A: and no coverage was recorded');
select matches(:'a_result'::text, format('^%s\.%s left ', 'public', :'wh0'),
  'A: the call says which table left while it waited');
select pgpm_archive_next_partition_whole('public.t325_wh'::regclass) as a_next \gset
select results_eq($$ select p_child, p_lo, p_hi, seen from t325.calls where parent = 'public.t325_wh'::regclass order by n $$,
  format($$ values (%L::name, '100'::text, '200'::text, '150,160'::text) $$, :'wh1'),
  'A: the next call archives [100, 200), ids 150 and 160');
select format('alter table public.t325_wh attach partition public.%I for values from (0) to (100)', :'wh0') as attach_wh \gset
:attach_wh;
select pgpm.retain('public.t325_wh');
select is((select string_agg(id::text, ',' order by id) from public.t325_wh where id < 100), '7,42,88',
  'A: attached back, retain() keeps ids 7, 42 and 88: nothing claimed them archived');

-- ---------------------------------------------------------------- PART B: _archive_step, READ COMMITTED
select * from t325.race('public.t325_st', :'st0',
  $$select pgpm._archive_step('public.t325_st'::regclass)$$, false, null) \gset b_
select ok(:'b_detach_held'::boolean, 'LIVENESS: B: the operator''s DETACH held the parent''s lock, uncommitted, when the step started');
select ok(:'b_call_waited'::boolean, 'LIVENESS: B: the step was seen waiting for a lock the detach held');
select ok((select pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
             from pgpm.part p where p.parent_table = 'public.t325_st'::regclass and p.child_name = :'st0'),
  'LIVENESS: B: once committed, [0, 100) is detached by hand');
select is(:'b_result'::text, '0', 'B: the step recorded no chunk');
select is_empty($$ select 1 from t325.calls where parent = 'public.t325_st'::regclass $$,
  'B: the strategy was handed nothing');
select is_empty($$ select 1 from pgpm.archive_ledger where parent_table = 'public.t325_st'::regclass $$,
  'B: and no coverage was recorded');
select is_empty($$ select action from pgpm.log where parent_table = 'public.t325_st'::regclass
                     and action in ('skip_archive', 'fail_archive_identity', 'fail_archive_contract') $$,
  'B: and nothing was logged, as for a table the candidate query leaves out');
select is(pgpm._archive_step('public.t325_st'), 1, 'B: the next step records one chunk');
select results_eq($$ select p_child, p_lo, p_hi, seen from t325.calls where parent = 'public.t325_st'::regclass order by n $$,
  format($$ values (%L::name, '100'::text, '200'::text, '150,160'::text) $$, :'st1'),
  'B: and it is [100, 200), ids 150 and 160');
select format('alter table public.t325_st attach partition public.%I for values from (0) to (100)', :'st0') as attach_st \gset
:attach_st;
select pgpm.retain('public.t325_st');
select is((select string_agg(id::text, ',' order by id) from public.t325_st where id < 100), '7,42,88',
  'B: attached back, retain() keeps ids 7, 42 and 88');

-- ---------------------------------------------------------------- PART C: under maintain()'s lock_timeout
select * from t325.race('public.t325_lt', :'lt0',
  $$select pgpm._archive_step('public.t325_lt'::regclass)$$, false, '200ms') \gset c_
select ok(:'c_detach_held'::boolean, 'LIVENESS: C: the operator''s DETACH held the parent''s lock, uncommitted, when the step started');
select results_eq($$ select lo, hi, method ~ 'lock timeout' from pgpm.log
                     where parent_table = 'public.t325_lt'::regclass and action = 'skip_archive' $$,
  $$ values ('0'::text, '100'::text, true) $$,
  'C: a wait longer than the 200 ms lock_timeout is a skip: skip_archive over [0, 100), for the lock timeout');
select is(:'c_result'::text, '0', 'C: the step recorded no chunk');
select is_empty($$ select 1 from t325.calls where parent = 'public.t325_lt'::regclass $$,
  'C: the strategy was handed nothing');
select is_empty($$ select 1 from pgpm.archive_ledger where parent_table = 'public.t325_lt'::regclass $$,
  'C: and no coverage was recorded');
select ok((select pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
             from pgpm.part p where p.parent_table = 'public.t325_lt'::regclass and p.child_name = :'lt0'),
  'LIVENESS: C: the detach committed after the step gave up, and [0, 100) is detached by hand');
select is(pgpm._archive_step('public.t325_lt'), 1, 'C: the next step leaves it out and records one chunk');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.t325_lt'::regclass and child_name = %L $$, :'lt0'),
  'C: none of it for the detached table');

-- ---------------------------------------------------------------- PART D: the script, REPEATABLE READ
select * from t325.race('public.t325_rr', :'rr0',
  $$select pgpm_archive_next_partition_whole('public.t325_rr'::regclass)$$, true, null) \gset d_
select diag('D: ' || :'d_result');
select ok(:'d_detach_held'::boolean, 'LIVENESS: D: the operator''s DETACH held the parent''s lock, uncommitted, when the call started');
select ok(:'d_call_waited'::boolean, 'LIVENESS: D: the call, in a REPEATABLE READ transaction, was seen waiting for a lock the detach held');
select ok((select pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
             from pgpm.part p where p.parent_table = 'public.t325_rr'::regclass and p.child_name = :'rr0'),
  'LIVENESS: D: once committed, [0, 100) is detached by hand');
select is_empty($$ select 1 from t325.calls where parent = 'public.t325_rr'::regclass $$,
  'D: the strategy was handed nothing, though the call''s snapshot predates the detach''s commit');
select is_empty($$ select 1 from pgpm.archive_ledger where parent_table = 'public.t325_rr'::regclass $$,
  'D: and no coverage was recorded');
select matches(:'d_result'::text, format('^%s\.%s left ', 'public', :'rr0'),
  'D: the call says which table left while it waited');
select format('alter table public.t325_rr attach partition public.%I for values from (0) to (100)', :'rr0') as attach_rr \gset
:attach_rr;
select pgpm.retain('public.t325_rr');
select is((select string_agg(id::text, ',' order by id) from public.t325_rr where id < 100), '7,42,88',
  'D: attached back, retain() keeps ids 7, 42 and 88');

select * from finish();
