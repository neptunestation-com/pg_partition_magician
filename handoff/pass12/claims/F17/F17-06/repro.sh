#!/bin/bash
# F17-06: scripts/archive_partition_whole.sql does not hold the parent and ask again before the strategy reads.
# docs/reference.md ("It holds the parent and asks again before the strategy reads, as the step does, so a
# detach that lands while the call waits leaves the table alone too, and the call says so") and CHANGELOG #1159
# promise a call of pgpm._archive_hold_partition there; the script keeps only the comment. So an operator's
# DETACH PARTITION in flight when the call picks its candidate commits under the strategy's read, the strategy
# (reading through the parent) finds none of the table's rows, and [lo, hi) is recorded as covered.
set -u
fail=0
ok()   { echo "ok - $1"; }
nok()  { echo "not ok - $1"; fail=1; }
q()    { $PSQL -tAq -c "$1" 2>&1; }

$PSQL -q >/dev/null 2>&1 <<'SQL'
create table public.t (id bigint primary key, v text not null);
insert into public.t select g, 'm' || g from generate_series(1, 50) g;
call pgpm.transmute('public.t', 'id', 100::bigint, p_obtain => 5, p_retain => 150::bigint);
insert into public.t select g, 'f' || g from generate_series(100, 450) g;
create function public.arch_raise(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $f$ begin raise exception 'bucket not reachable yet'; end $f$;
create function public.arch_read(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $f$
declare n bigint;
begin
  execute format('select count(*) from %s where id >= %L::bigint and id < %L::bigint', p_parent, p_lo, p_hi) into n;
  return (p_hi, n, null, null)::pgpm.archive_result;
end $f$;
select pgpm.set_archive_fn('public.t', 'public.arch_raise(regclass,name,text,text)'::regprocedure);
select pgpm.resume('public.t');
SQL
$PSQL -q -c "call pgpm.maintain('public.t')" >/dev/null 2>&1
q "select pgpm.set_archive_fn('public.t', 'public.arch_read(regclass,name,text,text)'::regprocedure)" >/dev/null
P=$(q "select child_name from pgpm.part where parent_table = 'public.t'::regclass and lo = '0'")
blk=$(q "select count(*) from pg_trigger where tgname = 'pgpm_write_block' and tgrelid = 'public.$P'::regclass and tgenabled = 'A'")
[ "$blk" = "1" ] && ok "LIVENESS: $P [0, 100) is write-blocked, uncovered, the oldest candidate" \
                 || { echo "not ok - LIVENESS: $P write-blocked (got $blk)"; exit 1; }

# Session X: the operator's DETACH PARTITION, uncommitted, holding the parent.
$PSQL -q -c "begin; alter table public.t detach partition public.$P; select pg_sleep(4); commit;" >/dev/null 2>&1 &
XPID=$!
for i in $(seq 1 50); do
  n=$(q "select count(*) from pg_stat_activity where datname = current_database() and query like '%detach partition%pg_sleep(4)%' and pid <> pg_backend_pid() and state = 'active'")
  [ "$n" = "1" ] && break; sleep 0.1
done
[ "$n" = "1" ] && ok "fixture: the operator's DETACH is in flight" || { echo "not ok - fixture: DETACH in flight"; exit 1; }
# Session Y: the operator utility, defined then called while the detach is in flight.
( cat "$TREE/scripts/archive_partition_whole.sql"; echo "select 'RESULT: ' || pgpm_archive_next_partition_whole('public.t'::regclass);" ) \
  | $PSQL -q -tA -f - > /tmp/f17_06_y_$DB.out 2>&1 &
YPID=$!
for i in $(seq 1 50); do
  n=$(q "select count(*) from pg_stat_activity where datname = current_database() and wait_event_type = 'Lock' and pid <> pg_backend_pid()")
  [ "$n" -ge 1 ] && break; sleep 0.1
done
[ "$n" -ge 1 ] && ok "LIVENESS: the call is waiting behind the detach's lock" || echo "not ok - LIVENESS: the call is waiting behind the detach's lock"
wait $XPID; wait $YPID
echo "# the script returned: $(grep RESULT /tmp/f17_06_y_$DB.out)"; rm -f /tmp/f17_06_y_$DB.out
det=$(q "select count(*) from pg_inherits where inhrelid = 'public.$P'::regclass")
[ "$det" = "0" ] && ok "LIVENESS: the detach committed; $P is the operator's table" || { echo "not ok - LIVENESS: detach committed"; exit 1; }
led=$(q "select coalesce(string_agg(format('[%s, %s) rows %s', lo, hi, rows_archived), '; '), 'none') from pgpm.archive_ledger where parent_table = 'public.t'::regclass and child_name = '$P'")
[ "$led" = "none" ] && ok "no coverage is recorded for $P, which left the parent while the call waited" \
                   || nok "no coverage is recorded for $P, which left the parent while the call waited (the ledger holds $led)"
exit $fail
