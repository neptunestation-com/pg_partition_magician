#!/bin/bash
# F17-02: untransmute on a table with a partition pending a concurrent detach. CHANGELOG #1157 and
# docs/reference.md (untransmute) promise a refusal, before the one-way-door check and again under the
# ACCESS EXCLUSIVE, naming the pending partition. pgpm._refuse_detach_pending exists, but nothing calls it.
set -u
fail=0
ok()   { echo "ok - $1"; }
nok()  { echo "not ok - $1"; fail=1; }
q()    { $PSQL -tAq -c "$1" 2>&1; }

$PSQL -q >/dev/null 2>&1 <<'SQL'
create table public.t (id bigint primary key, v text not null);
insert into public.t select g, 'm' || g from generate_series(1, 50) g;
call pgpm.transmute('public.t', 'id', 100::bigint, p_obtain => 2);
insert into public.t values (150, 'forward'), (160, 'forward2');
SQL
P=$(q "select child_name from pgpm.part where parent_table = 'public.t'::regclass and lo = '100'")
[ -n "$P" ] && ok "fixture: forward partition $P holds rows 150 and 160" || { echo "not ok - fixture: no forward partition"; exit 1; }

# An operator's DETACH ... CONCURRENTLY, interrupted in its wait (session A holds the parent, B is cancelled).
$PSQL -q -c "begin; select count(*) from public.t; select pg_sleep(30); commit;" >/dev/null 2>&1 &
APID=$!
for i in $(seq 1 50); do
  n=$(q "select count(*) from pg_stat_activity where datname = current_database() and query like '%pg_sleep(30)%' and pid <> pg_backend_pid() and state = 'active'")
  [ "$n" = "1" ] && break; sleep 0.1
done
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
[ "$pend" = "t" ] && ok "LIVENESS: $P is pending a concurrent detach" \
                 || { echo "not ok - LIVENESS: $P is pending a concurrent detach (got '$pend')"; exit 1; }
rows=$(q "select string_agg(id::text, ',' order by id) from public.$P")
[ "$rows" = "150,160" ] && ok "LIVENESS: $P holds rows 150 and 160, which the parent no longer shows" \
                        || { echo "not ok - LIVENESS: $P holds rows 150,160 (got $rows)"; exit 1; }

r=$(q "select pgpm.untransmute('public.t')")
echo "# untransmute said: $(printf '%s' "$r" | tr '\n' ' ')"
case "$r" in *"pending a concurrent detach"*) ok "untransmute refuses while $P is pending a concurrent detach";;
  *) nok "untransmute refuses while $P is pending a concurrent detach";; esac
rows=$(q "select coalesce((select string_agg(id::text, ',' order by id) from public.$P), 'gone')" )
case "$rows" in "150,160") ok "rows 150 and 160 still exist in $P";;
  *) nok "rows 150 and 160 still exist in $P (got: $(printf '%s' "$rows" | head -1))";; esac
logged=$(q "select count(*) from pgpm.log where action = 'untransmute'")
[ "$logged" = "0" ] && ok "no untransmute was logged" || nok "no untransmute was logged (pgpm.log records a plain untransmute)"
exit $fail
