#!/usr/bin/env bash
# retire() judges the retention policy again once it holds the partition's lock (issue #1454).
#
# THE DEFECT. retire() read pgpm.config at its start, judged the horizon on that read, and then waited for SHARE
# UPDATE EXCLUSIVE on the partition, as long as any reader of it liked. A set_retain that loosened retention past the
# partition and committed during that wait was never seen: a referenced partition's detach was dispatched (and, since
# #1438, lands), and an UNREFERENCED one was dropped, its rows gone though the policy in force kept them.
# set_retain's recall could not save either, because the mark it clears was retire()'s own, not yet committed.
#
# WHY A SHELL HARNESS. Every part needs two or three sessions at once: a holder of the partition's lock, the retire()
# waiting behind it, and the set_retain. Each window is held STRUCTURALLY: the holder's transaction (or, in part E,
# retire()'s own) stays open until this script, having seen the other session wait on a lock, lets it commit. Every
# observation is its own docker exec, so its own transaction. pg_cron exists only in `postgres` on the harness
# images, so the database brings a stand-in for cron.job, as tests/399 does.
#
# FIXTURES. Four tables of one shape (10000-wide cells, retain 25000, the frontier at 50005, so retention reaches the
# monolith [0, 10000) until set_retain moves it to 45000), with different rows in each monolith, so no two parts can
# pass on one another's rows:
#   A  referenced (a foreign key into the frontier row), rows 1, 2, 3: loosened during retire()'s lock wait
#   B  unreferenced, rows 4, 5: loosened during the wait (the one-step DROP path)
#   C  unreferenced, rows 6, 7, 8, 9: the same wait, NOT loosened (the witness that the wait-then-go path drops)
#   E  referenced: retire() dispatches, held open; a set_retain begun then must wait for the hand-off to commit
#
# WITNESSES (a failure of only these says the race was never set up):
#   LIVENESS: each holder held its lock, and each retire() waited on it
#   LIVENESS: (C) with no loosening the same wait ends in the drop
#   LIVENESS: (E) retire() dispatched the detach and has not committed
# THE CONTRACT:
#   (A) retire() returned false, nothing marked, the job idle, ids 1, 2, 3 served
#   (B) retire() returned false, the monolith stands, ids 4, 5 served, nothing logged retain_drop
#   (E) set_retain waited on a lock while retire() was open, and completed once it committed; the detach stays armed
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   retire_policy_read_once      -- the re-reading under the lock removed, the pre-fix shape. Parts A, B and E.
#   retire_policy_recheck_unlocked -- re-read, but with no row lock, so a set_retain begun after it does not
#                                   wait for the hand-off. Part E.
#   set_retain_policy_unlocked   -- set_retain's read of the row takes no lock, the same race from its side. Part E.
#
# Usage: retire_policy_as_of_lock.sh <container> <db> [install.sql]
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0
work=$(mktemp -d)
# every held transaction is let go and the sessions waited for whatever way this script ends
trap 'touch "$work"/go_A "$work"/go_B "$work"/go_C "$work"/go_E; wait 2>/dev/null; rm -rf "$work"' EXIT

q() { docker exec "$C" psql -U postgres "$@"; }
v() { docker exec -e PGOPTIONS=-cclient_min_messages=warning "$C" psql -U postgres -d "$DB" -qtAX -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-66s %s\n' "$1" "$2"
  else printf 'FAIL  %-66s %s (want %s)\n' "$1" "$2" "$3"; fail=1; fi
}
# until <sql> answers <want>, polled server-side state, at most 20 s; prints the last answer
until_is() { local a; for _ in $(seq 1 200); do a=$(v "$1"); [ "$a" = "$2" ] && break; sleep 0.1; done; echo "$a"; }
state() { echo "select coalesce(string_agg(coalesce(wait_event_type, '') || ':' || state, ','), 'none') from pg_stat_activity where application_name = '$1'"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
if ! q -v ON_ERROR_STOP=1 -q -c "create database $DB" >/dev/null 2>&1; then
  printf 'FAIL  %-66s %s\n' "fixture: the database was created" "$DB"; exit 1
fi
# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-66s %s\n' "the module under test installed" "$INSTALL"; exit 1
fi

if ! docker exec -i "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qX >/dev/null 2>"$work/setup.err" <<'SQL'
set client_min_messages = warning;
create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text,
                       username text not null default current_user);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $f$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$f$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');
create function pg_temp.mk(t text, ids bigint[]) returns void language plpgsql as $f$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', t);
  execute format('insert into public.%I select i, %L from unnest(%L::bigint[]) i', t, t, ids);
end $f$;
select pg_temp.mk('pa', '{1,2,3}'), pg_temp.mk('pb', '{4,5}'), pg_temp.mk('pc', '{6,7,8,9}'), pg_temp.mk('pe', '{11,12}');
SQL
then
  printf 'FAIL  %-66s %s\n' "fixture: the stand-in cron and the tables were set up" "no"
  sed 's/^/      /' "$work/setup.err" | head -5; exit 1
fi
for t in pa pb pc pe; do
  v "call pgpm.transmute('public.$t', 'id', 10000::bigint, p_retain => 25000, p_paused => false)" >/dev/null
  v "select pgpm.extend_to('public.$t', '60000')" >/dev/null
  v "insert into public.$t values (50005, 'frontier')" >/dev/null
done
for t in pa pe; do
  v "create table public.${t}_ref (id bigint primary key, p_id bigint references public.$t (id))" >/dev/null
  v "insert into public.${t}_ref values (1, 50005)" >/dev/null
done
mon() { v "select child_name from pgpm.part where parent_table = 'public.$1'::regclass and lo = '0'"; }
reached() { v "select (not pgpm._native_gt(c.control_kind, '10000', pgpm._retain_boundary(c)))::int from pgpm.config c where parent_table = 'public.$1'::regclass"; }
check "LIVENESS: retention reaches the four monoliths under retain 25000" "$(reached pa)$(reached pb)$(reached pc)$(reached pe)" "1111"

# race <table> <loosen: 1|0>: a holder takes the monolith's lock, retire() waits on it, the policy is (or is not)
# loosened and committed, the holder lets go; retire()'s answer lands in $work/retire_<table>.out
race() {
  local t=$1 loosen=$2 m; m=$(mon "$t")
  ( printf 'begin;\nlock table public.%s in share update exclusive mode;\n' "\"$m\""
    for _ in $(seq 1 600); do [ -e "$work/go_$t" ] && break; sleep 0.1; done
    printf 'commit;\n' ) \
    | docker exec -i -e PGAPPNAME="hold1454_$t" "$C" psql -U postgres -d "$DB" -qtAX -v ON_ERROR_STOP=1 >"$work/hold_$t.out" 2>&1 &
  check "LIVENESS: ($t) the holder holds the monolith's lock" "$(until_is "$(state "hold1454_$t")" "Client:idle in transaction")" "Client:idle in transaction"
  docker exec -e PGAPPNAME="ret1454_$t" "$C" psql -U postgres -d "$DB" -qtAX \
    -c "select pgpm.retire('public.$t', '$m')" >"$work/retire_$t.out" 2>&1 &
  local rpid=$!
  check "LIVENESS: ($t) retire() waits on the monolith's lock" "$(until_is "$(state "ret1454_$t")" "Lock:active")" "Lock:active"
  if [ "$loosen" = 1 ]; then
    v "select pgpm.set_retain('public.$t', '45000')" >/dev/null
    check "LIVENESS: ($t) the loosening committed in the wait, retention no longer reaching" "$(reached "$t")" "0"
  fi
  touch "$work/go_$t"
  for _ in $(seq 1 300); do kill -0 "$rpid" 2>/dev/null || break; sleep 0.1; done
  wait "$rpid"
}
mark() { v "select coalesce((select (retiring_at is not null)::text from pgpm.part where parent_table = 'public.$1'::regclass and lo = '0'), 'no row')"; }
served() { v "select coalesce(string_agg(id::text, ',' order by id), '') from public.$1 where id < 10000"; }

# --- (C) first: the same wait with no loosening drops the monolith ------------------------------------------
race pc 0
check "LIVENESS: (C) with no loosening the wait ends in the drop" "$(cat "$work/retire_pc.out")/$(served pc)" "t/"

# --- (A) referenced, loosened in the wait --------------------------------------------------------------------
race pa 1
check "(A) retire() returned false, without an error" "$(cat "$work/retire_pa.out")" "f"
check "(A) nothing is marked and the job is idle" "$(mark pa)/$(v "select command from cron.job where jobid = 1")" "false/select 1"
check "(A) ids 1, 2, 3 are served by the parent" "$(served pa)" "1,2,3"

# --- (B) unreferenced, loosened in the wait ------------------------------------------------------------------
race pb 1
check "(B) retire() returned false, without an error" "$(cat "$work/retire_pb.out")" "f"
check "(B) the monolith stands, ids 4, 5 served, no retain_drop logged" \
  "$(v "select count(*) from pg_class where relname = '$(mon pb)'")/$(served pb)/$(v "select count(*) from pgpm.log where parent_table = 'public.pb'::regclass and action = 'retain_drop'")" "1/4,5/0"

# --- (E) a loosening begun after retire() has re-read the policy waits for the hand-off -----------------------
me=$(mon pe)
( printf 'begin;\nselect pgpm.retire(%s, %s);\n' "'public.pe'" "'$me'"
  # the dispatch as retire()'s own transaction sees it, uncommitted: the job holds this monolith's detach
  printf "select position('%s' in command) > 0 from cron.job where jobid = 1;\n" "$me"
  for _ in $(seq 1 600); do [ -e "$work/go_E" ] && break; sleep 0.1; done
  printf 'commit;\n' ) \
  | docker exec -i -e PGAPPNAME=ret1454_E "$C" psql -U postgres -d "$DB" -qtAX -v ON_ERROR_STOP=1 >"$work/retire_E.out" 2>&1 &
open=$(until_is "$(state ret1454_E)" "Client:idle in transaction")
check "LIVENESS: (E) retire() dispatched the detach and has not committed" "$open $(tr '\n' ' ' < "$work/retire_E.out")" "Client:idle in transaction f t "
docker exec -e PGAPPNAME=set1454_E -e PGOPTIONS=-cclient_min_messages=warning "$C" psql -U postgres -d "$DB" -qtAX \
  -c "select pgpm.set_retain('public.pe', '45000')" >"$work/set_E.out" 2>&1 &
spid=$!
check "(E) set_retain waits on a lock while retire() is open" "$(until_is "$(state set1454_E)" "Lock:active")" "Lock:active"
touch "$work/go_E"
for _ in $(seq 1 300); do kill -0 "$spid" 2>/dev/null || break; sleep 0.1; done
wait
check "(E) set_retain completed once retire() committed, without an error" "$(grep -c ERROR "$work/set_E.out")/$(reached pe)" "0/0"
check "(E) the dispatched detach stays armed, the mark kept (it was handed off first)" \
  "$(mark pe)/$(v "select (command like '%detach partition%' and position('$me' in command) > 0)::text from cron.job where jobid = 1")" "true/true"

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
