#!/bin/bash
# F13-01: the regrain swap's snapshot wait (_snapshot_wait) is refused by a transaction in ANOTHER database.
#
# backend_xmin is cluster-wide: a statement's snapshot xmin is the oldest xid running anywhere in the
# cluster. So while a transaction that took an xid before the copies' last write stays open in another
# database, every statement running in THIS database reports a backend_xmin at or before
# config.regrain_written_xid, even when its snapshot was taken after the copies committed and sees them
# whole. _snapshot_wait counts such a session as "a snapshot older than the copies" and the swap defers at
# its budget, every tick, for as long as the foreign transaction lasts, although its own comment says other
# databases' sessions are not consulted.
#
# Two tables with the same shape, both copied to the swap's doorstep, and one reader session in this
# database whose statement starts AFTER every copy has committed. Control (A): the same swap with no other
# session in this database goes through. Defect (B): a transaction open in another database since
# before B's copies; the same swap, same reader shape, is refused.
set -u
OTHER="${DB}_h1o"
OPSQL="docker exec -i $CONTAINER psql -X -q -At -U postgres -d $OTHER"
ADMIN="docker exec -i $CONTAINER psql -X -q -At -U postgres -d postgres"
fail=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }
cleanup() {
  kill $(jobs -p) 2>/dev/null
  $PSQL -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name like 'f13h1_%'" >/dev/null 2>&1
  $ADMIN -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$OTHER'" >/dev/null 2>&1
  $ADMIN -c "drop database if exists \"$OTHER\"" >/dev/null 2>&1
}
trap cleanup EXIT
$ADMIN -c "drop database if exists \"$OTHER\"" >/dev/null 2>&1
$ADMIN -c "create database \"$OTHER\"" >/dev/null

mk() {   # a frozen [0, 200000) monolith regrained to 20000, copied to the swap's doorstep, one tick per transaction
  $PSQL -c "create table public.$1 (id bigint primary key, payload text);
            insert into public.$1 select g, 'x' from generate_series(1, 1000) g;
            insert into public.$1 values (199999, 'widen');" >/dev/null
  $PSQL -c "call pgpm.transmute('public.$1', 'id', 100000)" >/dev/null
  $PSQL -c "insert into public.$1 values (350000, 'frontier')" >/dev/null
  for i in $(seq 1 40); do
    cur=$($PSQL -At -c "select coalesce(regrain_cursor, '-1') from pgpm.config where parent_table = 'public.$1'::regclass")
    [ "$cur" = "200000" ] && break
    $PSQL -At -c "select pgpm.regrain_step('public.$1', '${1}_p0000000000000000000_to_0000000000000200000', '20000', 5000)" >/dev/null
  done
}
swap() {   # the swap tick, under a 2 s budget; prints the status or the error
  $PSQL -At -c "set lock_timeout = '2s'; select pgpm.regrain_step('public.$1', '${1}_p0000000000000000000_to_0000000000000200000', '20000', 5000)" 2>&1 | grep -m1 -E '^(swapped|ERROR)' | cut -c1-220
}
reader() { # a statement in THIS database, started now, running 30 s
  ($PSQL -c "set application_name = 'f13h1_$1'; select pg_sleep(30)" >/dev/null 2>&1 &)
  for i in $(seq 1 100); do
    n=$($PSQL -At -c "select count(*) from pg_stat_activity where application_name = 'f13h1_$1' and state = 'active' and backend_xmin is not null")
    [ "$n" = "1" ] && break; sleep 0.1
  done
}

# ---------------- (A) control: no foreign transaction ----------------
mk h1a
[ "$($PSQL -At -c "select regrain_cursor from pgpm.config where parent_table = 'public.h1a'::regclass")" = "200000" ] \
  && ok "fixture: (A) h1a is copied to the swap's doorstep" || nok "fixture: (A) h1a did not reach the swap"
r=$(swap h1a)
case "$r" in swapped:*) ok "LIVENESS: (A) with no other session in this database the same swap goes through ($r)";;
                       *) nok "LIVENESS: (A) control swap failed: $r";; esac

# ---------------- (B) a transaction open in another database since before the copies ----------------
$PSQL -c "create table public.h1b (id bigint primary key, payload text);
          insert into public.h1b select g, 'x' from generate_series(1, 1000) g;
          insert into public.h1b values (199999, 'widen');" >/dev/null
$PSQL -c "call pgpm.transmute('public.h1b', 'id', 100000)" >/dev/null
$PSQL -c "insert into public.h1b values (350000, 'frontier')" >/dev/null
($OPSQL -c "set application_name = 'f13h1_foreign'; begin; select pg_current_xact_id(); select pg_sleep(60); commit;" >/dev/null 2>&1 &)
for i in $(seq 1 100); do
  fx=$($ADMIN -c "select backend_xid from pg_stat_activity where datname = '$OTHER' and application_name = 'f13h1_foreign' and backend_xid is not null")
  [ -n "$fx" ] && break; sleep 0.1
done
for i in $(seq 1 40); do
  cur=$($PSQL -At -c "select coalesce(regrain_cursor, '-1') from pgpm.config where parent_table = 'public.h1b'::regclass")
  [ "$cur" = "200000" ] && break
  $PSQL -At -c "select pgpm.regrain_step('public.h1b', 'h1b_p0000000000000000000_to_0000000000000200000', '20000', 5000)" >/dev/null
done
[ "$cur" = "200000" ] && ok "fixture: (B) h1b is copied to the swap's doorstep" || nok "fixture: (B) h1b did not reach the swap"
wx=$($PSQL -At -c "select regrain_written_xid from pgpm.config where parent_table = 'public.h1b'::regclass")
[ -n "$fx" ] && [ -n "$wx" ] && [ "$fx" -lt "$wx" ] \
  && ok "LIVENESS: (B) a transaction in database $OTHER holds xid $fx, older than the copies' last write $wx, and is still open" \
  || nok "LIVENESS: (B) no older foreign transaction (foreign $fx, written $wx)"
reader b
rx=$($PSQL -At -c "select backend_xmin from pg_stat_activity where application_name = 'f13h1_b'")
qs=$($PSQL -At -c "select query_start > (select max(at) from pgpm.log where parent_table = 'public.h1b'::regclass and action = 'regrain_copy') from pg_stat_activity where application_name = 'f13h1_b'")
[ "$qs" = "t" ] && ok "LIVENESS: (B) the reader's statement (snapshot) started after the last copy was logged, so it sees the copies" \
  || nok "LIVENESS: (B) reader did not start after the copies ($qs)"
[ -n "$rx" ] && [ "$rx" -le "$wx" ] && ok "LIVENESS: (B) yet its backend_xmin $rx is held at or before $wx by the other database's transaction" \
  || nok "LIVENESS: (B) reader xmin $rx not held back"
r=$(swap h1b)
case "$r" in swapped:*) ok "the swap goes through: the only older transaction is in another database, and the reader sees the copies ($r)";;
                       *) nok "the swap of h1b is refused because of a transaction in another database: $r";; esac
exit $fail
