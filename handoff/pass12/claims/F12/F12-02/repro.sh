#!/usr/bin/env bash
# scripts/archive_partition_whole.sql never calls pgpm._archive_hold_partition, though its own comment (and
# docs/reference.md) says it holds the parent and asks again before the strategy reads. An operator's DETACH
# PARTITION in flight when the candidate query runs is invisible to it; the strategy's read through the parent
# waits on the detach, finds none of the table's rows, and [lo, hi) is recorded covered with 0 rows. Attached back,
# retain() drops rows nothing archived. Reads the script from $TREE; the race is driven by dblink, ordered by
# held locks (the detach holds until this session sees the call waiting), not by sleeps.
set -u
SQLF="$(mktemp)"; trap 'rm -f "$SQLF"' EXIT
cat > "$SQLF" <<'SQL'
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(8);

create schema f1202;
create table f1202.calls (n serial primary key, p_child name, p_lo text, p_hi text, seen text);
create function f1202.via_parent(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_seen text; v_n bigint;
begin
  execute format('select string_agg(id::text, '','' order by id), count(*) from %s where id >= %L::bigint and id < %L::bigint',
                 p_parent, p_lo, p_hi) into v_seen, v_n;
  insert into f1202.calls (p_child, p_lo, p_hi, seen) values (p_child, p_lo, p_hi, coalesce(v_seen, 'none'));
  v.covered_hi := p_hi; v.rows_archived := v_n; v.s3_key := 'f1202/' || p_lo;
  return v;
end $$;

create table public.f1202_ev (id bigint primary key, payload text);
insert into public.f1202_ev values (7, 'a'), (42, 'b'), (88, 'c');
call pgpm.transmute('public.f1202_ev', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.f1202_ev values (150, 'd'), (160, 'e'), (500, 'frontier');
select pgpm._enforce_write_blocks('public.f1202_ev');
select pgpm.set_archive_fn('public.f1202_ev', 'f1202.via_parent(regclass,name,text,text)'::regprocedure);
select child_name as p0, child_oid as p0oid from pgpm.part where parent_table = 'public.f1202_ev'::regclass and lo = '0' \gset

select ok(pgpm._is_write_blocked('public.f1202_ev', :'p0') and not pgpm._archive_fully_covered('public.f1202_ev', :'p0'),
  'LIVENESS: [0, 100) is write-blocked and uncovered, the oldest candidate');

create function f1202.race(p_child name, out detach_held boolean, out call_waited boolean, out result text)
language plpgsql as $$
begin
  call_waited := false;
  perform dblink_connect('d1202', 'dbname=' || current_database());
  perform dblink_exec('d1202', $q$set application_name = 'd1202_detach'$q$);
  perform dblink_exec('d1202', 'begin');
  perform dblink_exec('d1202', format('alter table public.f1202_ev detach partition public.%I', p_child));
  perform pg_stat_clear_snapshot();
  detach_held := exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                          where a.application_name = 'd1202_detach' and l.locktype = 'relation'
                            and l.relation = 'public.f1202_ev'::regclass and l.mode = 'AccessExclusiveLock' and l.granted);
  perform dblink_connect('a1202', 'dbname=' || current_database());
  perform dblink_exec('a1202', $q$set application_name = 'a1202_archive'$q$);
  perform dblink_send_query('a1202', $q$select pgpm_archive_next_partition_whole('public.f1202_ev'::regclass)$q$);
  for i in 1 .. 3000 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                where a.application_name = 'a1202_archive' and l.locktype = 'relation' and not l.granted) then
      call_waited := true;
    end if;
    exit when call_waited or dblink_is_busy('a1202') = 0;
    perform pg_sleep(0.01);
  end loop;
  perform dblink_exec('d1202', 'commit');
  select r into result from dblink_get_result('a1202') as t(r text);
  perform * from dblink_get_result('a1202') as t(r text);
  perform dblink_disconnect('a1202');
  perform dblink_disconnect('d1202');
end $$;

-- the script is defined in this database (it is a plain function), so the dblink session can call it
select * from f1202.race(:'p0') \gset r_
select diag('call: ' || :'r_result');
select ok(:'r_detach_held'::boolean, 'LIVENESS: the operator''s DETACH held the parent''s ACCESS EXCLUSIVE, uncommitted, when the call started');
select ok(:'r_call_waited'::boolean, 'LIVENESS: the call was seen waiting on a lock the detach held, so it chose its candidate before the detach committed');
select ok((select pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
             from pgpm.part p where p.parent_table = 'public.f1202_ev'::regclass and p.child_name = :'p0'),
  'LIVENESS: once committed, [0, 100) is detached by hand');

select is_empty(format($$ select 1 from f1202.calls where p_child = %L $$, :'p0'),
  'the table that left while the call waited is never handed to the strategy');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.f1202_ev'::regclass and child_name = %L $$, :'p0'),
  'no coverage is recorded for it');

select format('alter table public.f1202_ev attach partition public.%I for values from (0) to (100)', :'p0') as attach_sql \gset
:attach_sql;
select is((select string_agg(id::text, ',' order by id) from public.f1202_ev where id < 100), '7,42,88',
  'LIVENESS: attached back, ids 7, 42 and 88 are visible through the parent before retain');
select pgpm.retain('public.f1202_ev');
select is((select string_agg(id::text, ',' order by id) from public.f1202_ev where id < 100), '7,42,88',
  'retain() keeps ids 7, 42 and 88: nothing archived them');
select * from finish();
SQL
out="$(cat "$TREE/scripts/archive_partition_whole.sql" "$SQLF" | $PSQL -X -q -tA -v ON_ERROR_STOP=1 -f - 2>&1)"
rc=$?
echo "$out"
[ $rc -ne 0 ] && exit 1
echo "$out" | grep -q '^not ok' && exit 1
exit 0
