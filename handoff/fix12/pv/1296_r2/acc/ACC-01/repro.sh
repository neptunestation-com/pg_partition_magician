#!/bin/bash
# #1263 acceptance, rebuilt by the claims verifier of PR #1296 (the finder's F13-01 repro.sh is repro.sh, unedited).
#
# The original's last line expected the swap to go through while a transaction older than the copies is open in
# ANOTHER database. That exemption is unsound: a REPEATABLE READ transaction begun after the copies that imported a
# snapshot exported before them shows the same backend_xmin (the foreign xid), state and start times as the issue's
# READ COMMITTED reader, and passing one passes the other (tests/333 assertion 16 reads empty under the mutant
# snapshot_wait_foreign_floor_exempt). So this version pins the contract the fix keeps instead: the swap is STILL
# deferred (nothing swapped, the source attached by oid), and the refusal names the transaction holding every
# snapshot back, by its database, pid and xid, instead of calling the innocent local reader one that "would find the
# regrained range empty" and nothing else. Fails on the base (no holder clause), on
# snapshot_wait_holder_this_database_only (holder looked for here only) and on snapshot_wait_foreign_floor_exempt
# (the swap goes through). Passes on the fix.
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
  fp=$($ADMIN -c "select pid from pg_stat_activity where datname = '$OTHER' and application_name = 'f13h1_foreign' and backend_xid is not null")
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
src_oid=$($PSQL -At -c "select child_oid from pgpm.part where parent_table = 'public.h1b'::regclass and attached and lo = '0'")
[ -n "$src_oid" ] && ok "fixture: (B) the source monolith is attached (oid $src_oid)" || nok "fixture: (B) no attached source"
rpid=$($PSQL -At -c "select pid from pg_stat_activity where application_name = 'f13h1_b'")
[ -n "$fp" ] && ok "LIVENESS: (B) the foreign transaction is pid $fp in $OTHER" || nok "LIVENESS: (B) no foreign pid"
# the full refusal (not cut): the swap tick under a 2 s budget
full=$($PSQL -At -c "set lock_timeout = '2s'; select pgpm.regrain_step('public.h1b', 'h1b_p0000000000000000000_to_0000000000000200000', '20000', 5000)" 2>&1 | tr '\n' ' ')
case "$full" in
  *"ERROR:  pg_partition_magician: regrain swap deferred: "*) ok "the swap is still deferred while the foreign transaction runs";;
  *"swapped:"[0-9]*) nok "the swap is still deferred while the foreign transaction runs (it went through: $full)";;
  *) nok "the swap is refused with the snapshot wait's message: ${full:0:300}";;
esac
case "$full" in *"pids "*"$rpid"*) ok "the refusal lists the local reader pid $rpid";;
                *) nok "the refusal does not list the local reader $rpid: ${full:0:300}";; esac
want="a transaction older than the copies is still running in database $OTHER (pid $fp, xid $fx, open "
case "$full" in *"$want"*) ok "the refusal names the holding transaction: database $OTHER, pid $fp, xid $fx";;
                *) nok "the refusal names the innocent local pid $rpid without the holding transaction in $OTHER (pid $fp, xid $fx): ${full:0:400}";; esac
case "$full" in *"cannot be told from snapshots that miss the copies"*) ok "the refusal says the listed sessions cannot be told from snapshots that miss the copies";;
                *) nok "the refusal calls the listed sessions readers that would find the range empty, unqualified";; esac
n=$($PSQL -At -c "select count(*) from pgpm.log where parent_table = 'public.h1b'::regclass and action = 'regrain'")
now=$($PSQL -At -c "select child_oid from pgpm.part where parent_table = 'public.h1b'::regclass and attached and lo = '0'")
[ "$n" = "0" ] && [ "$now" = "$src_oid" ] && ok "nothing was swapped: no regrain row, the same source attached by oid" \
  || nok "the swap went ahead (regrain rows $n, source now $now, was $src_oid)"
exit $fail
