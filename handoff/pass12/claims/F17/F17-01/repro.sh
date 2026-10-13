#!/bin/bash
# F17-01: docs/reference.md (untransmute) tells the operator to finish an interrupted
# DETACH ... CONCURRENTLY with the statement it quotes, then re-run untransmute. Typed against the
# state the paragraph describes, that statement must finish the detach. The statement is read from
# $TREE, never pasted here. (untransmute itself is left out: see F17-02.)
set -u
fail=0
ok()   { echo "ok - $1"; }
nok()  { echo "not ok - $1"; fail=1; }
q()    { $PSQL -tAq -c "$1" 2>&1; }

# The remedy as the reference words it, in the untransmute section.
REMEDY=$(perl -0777 -ne 'if (/finish an interrupted one with\s+`([^`]+)`/) { $s=$1; $s =~ s/\s+/ /g; print $s }' "$TREE/docs/reference.md")
if [ -n "$REMEDY" ]; then ok "fixture: the reference's remedy for a pending detach was found: $REMEDY"; else echo "not ok - fixture: the remedy sentence is not in docs/reference.md"; exit 1; fi

$PSQL -q >/dev/null 2>&1 <<'SQL'
create table public.t (id bigint primary key, v text not null);
insert into public.t select g, 'm' || g from generate_series(1, 50) g;
call pgpm.transmute('public.t', 'id', 100::bigint, p_obtain => 2);
insert into public.t values (150, 'forward');
SQL
P=$(q "select child_name from pgpm.part where parent_table = 'public.t'::regclass and lo = '100'")
[ -n "$P" ] && ok "fixture: forward partition $P holds row 150" || { echo "not ok - fixture: no forward partition"; exit 1; }

# Session A holds the parent so the concurrent detach waits in its second transaction.
$PSQL -q -c "begin; select count(*) from public.t; select pg_sleep(30); commit;" >/dev/null 2>&1 &
APID=$!
for i in $(seq 1 50); do
  n=$(q "select count(*) from pg_stat_activity where datname = current_database() and query like '%pg_sleep(30)%' and pid <> pg_backend_pid() and state = 'active'")
  [ "$n" = "1" ] && break; sleep 0.1
done
# Session B: the operator's DETACH ... CONCURRENTLY, which will be interrupted in its wait.
$PSQL -q -c "alter table public.t detach partition public.$P concurrently" >/dev/null 2>&1 &
BPID=$!
for i in $(seq 1 100); do
  n=$(q "select count(*) from pg_stat_activity where datname = current_database() and query like 'alter table public.t detach partition%' and wait_event_type = 'Lock'")
  [ "$n" = "1" ] && break; sleep 0.1
done
q "select pg_cancel_backend(pid) from pg_stat_activity where datname = current_database() and query like 'alter table public.t detach partition%'" >/dev/null
wait $BPID 2>/dev/null
q "select pg_terminate_backend(pid) from pg_stat_activity where datname = current_database() and query like '%pg_sleep(30)%' and pid <> pg_backend_pid()" >/dev/null
wait $APID 2>/dev/null
for i in $(seq 1 50); do
  n=$(q "select count(*) from pg_stat_activity where datname = current_database() and query like '%pg_sleep(30)%' and pid <> pg_backend_pid()")
  [ "$n" = "0" ] && break; sleep 0.1
done

pend=$(q "select inhdetachpending from pg_inherits where inhrelid = 'public.$P'::regclass")
[ "$pend" = "t" ] && ok "LIVENESS: $P is pending a concurrent detach (the interrupted state the reference describes)" \
                 || { echo "not ok - LIVENESS: $P is pending a concurrent detach (got '$pend')"; exit 1; }
hidden=$(q "select count(*) from public.t where id = 150")
[ "$hidden" = "0" ] && ok "LIVENESS: row 150 is invisible through the parent while $P is pending" \
                    || { echo "not ok - LIVENESS: row 150 is invisible through the parent (got $hidden)"; exit 1; }

# The operator types the reference's remedy, with the table and the partition filled in.
STMT=$(printf '%s' "$REMEDY" | sed -e "s/<table>/public.t/" -e "s/<partition>/public.$P/")
out=$(q "$STMT")
echo "# typed: $STMT"
echo "# server said: $out"
pend=$(q "select coalesce((select inhdetachpending::text from pg_inherits where inhrelid = 'public.$P'::regclass), 'detached')")
[ "$pend" = "detached" ] && ok "the reference's remedy finished the pending detach of $P" \
                         || nok "the reference's remedy finished the pending detach of $P (pg_inherits still says pending=$pend)"
v=$(q "select v from public.$P where id = 150")
[ "$v" = "forward" ] && ok "the partition, now detached, still holds row 150" || nok "the partition, now detached, still holds row 150 (got: $v)"
exit $fail
