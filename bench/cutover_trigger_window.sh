#!/usr/bin/env bash
# Guard that the transmute cutover carries every trigger the table has when the rename takes it, including
# one another session committed while the cutover was already running (issue #593). Run by CI
# (`./test.sh perf`).
#
# THE BAR: the converted parent carries every row trigger the table had at the rename. Before #593 the
# cutover captured the triggers at the start of phase 3, under nothing stronger than the ACCESS SHARE its
# staging CREATE TABLE ... LIKE takes, and CREATE TRIGGER needs only SHARE ROW EXCLUSIVE, which ACCESS
# SHARE does not exclude. A trigger committed between that capture and the rename was never replayed:
# step 7b dropped it from the monolith with the ones it had captured, and every row, wherever routed,
# escaped it. The fix takes ACCESS EXCLUSIVE explicitly and captures under it.
#
# WHAT THIS DRIVES. Three sessions, in the order the race needs, with no timing guesses:
#
#   a first transmute  fails in the cutover (a blocker holds ACCESS SHARE on the REFERENCING table, and
#                      the incoming-FK drop times out), leaving a claim and a VALIDATED bound, so the
#                      resume below requests no lock on the table before phase 3.
#   session B          begins, creates trigger ev_b on the table (SHARE ROW EXCLUSIVE, granted), then
#                      parks in a server-side loop polling a gate table, so the CREATE TRIGGER stays
#                      UNCOMMITTED for exactly as long as this guard wants.
#   the resume         runs phase 3: its staging CREATE TABLE ... LIKE takes ACCESS SHARE on the table
#                      (compatible with B's lock, so it gets it), and it then blocks on ACCESS EXCLUSIVE
#                      behind B. Pre-#593 the capture had already happened by then; post-#593 the capture
#                      is what the ACCESS EXCLUSIVE is guarding.
#   this script        polls pg_locks until it sees the resume waiting, records the three witnesses
#                      below in one statement, then opens the gate. B commits, the resume gets its lock,
#                      and what the converted parent carries is the property under test.
#
# THE LIVENESS WITNESSES. "The trigger was not lost" is equally satisfied by a run in which B committed
# before phase 3 ever began (then any capture sees it, and the fix is not exercised). So the guard
# asserts, BEFORE releasing B: the resume is waiting (granted = false) for AccessExclusiveLock on the
# table; the resume already HOLDS AccessShareLock on it, which in a resume with a validated bound only
# phase 3's staging LIKE takes, so the resume is past the pre-#593 capture point; and B still has an
# open xid, so its trigger is uncommitted at that instant. If any witness fails the guard fails.
#
# THE INSTRUMENT'S COST. A `docker exec` sample costs 40-80 ms, which is fine: the window is not a
# duration, the resume stays parked on its lock wait until this script opens the gate. No sampling
# session reads public.ev while the resume waits (a new ACCESS SHARE queues behind a pending ACCESS
# EXCLUSIVE and would deadlock the guard against the wait it is witnessing); the witnesses read
# pg_locks and pg_stat_activity only.
#
# Asymmetric fixture: ev_a exists from the start and adds 1, B's ev_b adds 10, so a row's n says which
# fired and how often: 11 is both, once. Under the defect a row carries 1 wherever it lands.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_trigger_capture_unlocked  -- the explicit ACCESS EXCLUSIVE before the capture is removed,
#                                          so the capture reads the triggers under ACCESS SHARE only and
#                                          the incoming-FK drop is again the first statement to wait
#                                          behind B: ev_b is missed, exactly as before #593
#
# Usage: cutover_trigger_window.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
qraw() { docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-66s %s\n' "$1" "$2"
  else printf 'FAIL  %-66s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -v ON_ERROR_STOP=1 -c "drop database if exists $DB" >/dev/null 2>&1 \
  || { echo "FAIL  could not drop database $DB (stale connection?)"; exit 1; }
docker exec "$C" psql -U postgres -q -v ON_ERROR_STOP=1 -c "create database $DB" >/dev/null 2>&1 \
  || { echo "FAIL  could not create database $DB"; exit 1; }
docker exec "$C" psql -U postgres -d "$DB" -qv ON_ERROR_STOP=1 -f "$INSTALL" >/dev/null 2>&1 \
  || { echo "FAIL  could not install $INSTALL"; exit 1; }
check "pgpm installed into $DB, with _transmute defined" \
  "$(q "select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'pgpm' and p.proname = '_transmute'")" "1"

# ---- the fixture ----
# shellcheck disable=SC2016  # $f$ is a dollar-quote, not a shell variable
qraw 'create table public.ev (id bigint primary key, n int not null default 0);
      insert into public.ev (id) select g from generate_series(1, 15) g;
      create table public.ref (id int primary key, ev_id bigint references public.ev(id));
      insert into public.ref values (1, 3);
      create function public.ev_add1()  returns trigger language plpgsql as $f$ begin new.n := new.n + 1;  return new; end $f$;
      create function public.ev_add10() returns trigger language plpgsql as $f$ begin new.n := new.n + 10; return new; end $f$;
      create trigger ev_a before insert on public.ev for each row execute function public.ev_add1();
      create table public.gate (x int);
      create function public.gate_wait() returns void language plpgsql as $f$
      begin
        for i in 1 .. 1200 loop
          exit when exists (select 1 from public.gate);
          perform pg_sleep(0.05);
        end loop;
      end $f$;' >/dev/null \
  || { echo "FAIL  fixture: could not create public.ev"; exit 1; }

# ---- the first attempt: fails in the cutover, leaving a claim and a validated bound ----
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "set application_name = 'ctw_blocker'" -c "begin" -c "lock table public.ref in access share mode" \
  -c "select public.gate_wait()" -c "commit" >/dev/null 2>&1 &
BLK=$!
BSESS=""; RES=""
trap 'kill $BLK $BSESS $RES 2>/dev/null' EXIT
for _ in $(seq 1 100); do
  [ "$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
           where a.application_name = 'ctw_blocker' and l.relation = 'public.ref'::regclass and l.granted")" = "1" ] && break
  sleep 0.1
done
q "call pgpm.transmute('public.ev', 'id', 10::bigint, p_obtain => 2, p_incoming_fks => 'preserve', p_lock_timeout => '300ms')" >/dev/null 2>&1
q "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'ctw_blocker'" >/dev/null
wait "$BLK" 2>/dev/null
check "LIVENESS: the first attempt left a claim with a VALIDATED bound" \
  "$(q "select count(*) from pgpm.transmute_inflight i join pg_constraint c
          on c.conrelid = i.parent_table and c.conname = 'pgpm_monolith_bound' and c.convalidated
         where i.parent_table = 'public.ev'::regclass")" "1"
check "LIVENESS: and the table is still the plain table" \
  "$(q "select relkind from pg_class where oid = 'public.ev'::regclass")" "r"

# ---- session B: CREATE TRIGGER ev_b, held uncommitted until the gate opens ----
docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 \
  -c "set application_name = 'ctw_b'" -c "begin" \
  -c "create trigger ev_b before insert on public.ev for each row execute function public.ev_add10()" \
  -c "select public.gate_wait()" -c "commit" >/dev/null 2>&1 &
BSESS=$!
b_holds=0
for _ in $(seq 1 100); do
  b_holds=$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
                where a.application_name = 'ctw_b' and l.relation = 'public.ev'::regclass
                  and l.mode = 'ShareRowExclusiveLock' and l.granted")
  [ "${b_holds:-0}" = "1" ] && break
  sleep 0.1
done
check "LIVENESS: B holds SHARE ROW EXCLUSIVE on ev, CREATE TRIGGER uncommitted" "${b_holds:-0}" "1"

# ---- the resume ----
RLOG=$(mktemp)
docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 \
  -c "set application_name = 'ctw_resume'" \
  -c "call pgpm.transmute('public.ev', 'id', 10::bigint, p_obtain => 2, p_incoming_fks => 'preserve', p_lock_timeout => '60s')" \
  >"$RLOG" 2>&1 &
RES=$!

r_wait=0; r_share=0; b_open=0
for _ in $(seq 1 300); do
  IFS='|' read -r r_wait r_share b_open < <(q "
    select
      (select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
        where a.application_name = 'ctw_resume' and l.locktype = 'relation'
          and l.relation = 'public.ev'::regclass and l.mode = 'AccessExclusiveLock' and not l.granted),
      (select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
        where a.application_name = 'ctw_resume' and l.locktype = 'relation'
          and l.relation = 'public.ev'::regclass and l.mode = 'AccessShareLock' and l.granted),
      (select count(*) from pg_stat_activity where application_name = 'ctw_b' and backend_xid is not null)")
  [ "${r_wait:-0}" = "1" ] && break
  sleep 0.1
done
check "LIVENESS: the resume is waiting for ACCESS EXCLUSIVE on ev" "${r_wait:-0}" "1"
check "LIVENESS: holding the ACCESS SHARE its staging LIKE took (past 0b)" "${r_share:-0}" "1"
check "LIVENESS: while B's CREATE TRIGGER is still uncommitted (open xid)" "${b_open:-0}" "1"

# ---- open the gate ----
q "insert into public.gate values (1)" >/dev/null
wait "$BSESS"; B_RC=$?
wait "$RES"; R_RC=$?
BSESS=""; RES=""
check "B's commit went through" "$B_RC" "0"
check "the resume completed" "$R_RC" "0"
[ "$R_RC" = 0 ] || sed 's/^/      /' "$RLOG"
rm -f "$RLOG"
check "LIVENESS: the resume converted ev (transmute_resume logged, relkind p)" \
  "$(q "select (select count(*) from pgpm.log where parent_table = 'public.ev'::regclass and action = 'transmute_resume')
               || ':' || (select relkind::text from pg_class where oid = 'public.ev'::regclass)")" "1:p"

# ---- the property under test ----
check "the parent carries ev_a AND the ev_b B committed mid-cutover" \
  "$(q "select string_agg(tgname, ',' order by tgname) from pg_trigger
         where tgrelid = 'public.ev'::regclass and not tgisinternal")" "ev_a,ev_b"
check "the monolith carries each once, as clones of the parent's" \
  "$(q "select string_agg(t.tgname || ':' || (t.tgparentid <> 0)::text, ',' order by t.tgname) from pg_trigger t
         where not t.tgisinternal and t.tgrelid = (select format('%I.%I', 'public', child_name)::regclass
           from pgpm.part where parent_table = 'public.ev'::regclass order by lo::bigint limit 1)")" "ev_a:true,ev_b:true"
q "insert into public.ev (id) values (16), (35)" >/dev/null
check "rows into the monolith (16) and a forward partition (35) fire both, once" \
  "$(q "select string_agg(id || ':' || n, ',' order by id) from public.ev where id >= 16")" "16:11,35:11"

exit "$fail"
