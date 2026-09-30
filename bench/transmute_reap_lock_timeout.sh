#!/usr/bin/env bash
# Guard maintain_all's reaper against parking behind a long reader (issue #657). Run by CI (`./test.sh perf`).
#
# THE DEFECT. maintain_all runs _transmute_reap first, before any lock_timeout is set, and under pg_cron's
# session default (0: wait forever). The reaper undoes an abandoned conversion with ALTER TABLE ... DROP
# CONSTRAINT pgpm_monolith_bound, which takes ACCESS EXCLUSIVE on the operator's live table. One long reader
# of that table parked it, and a PENDING ACCESS EXCLUSIVE queues every later lock request behind it, so
# every read and write of the table waited for the reader to end, and the whole sweep with it. The fix
# bounds the reaper's wait (transmute's own default, #309) and defers that table to the next tick.
#
# WHY A SHELL HARNESS. The contract is about a THIRD session: an ordinary write attempted while the reaper
# is queued behind a reader. pgTAP gives one session per file. tests/166 pins what one session plus dblink
# can see (the deferral, its log row, the per-table isolation, the caller's setting left alone).
#
# WHAT IT ASSERTS, each paired with the witness that makes it mean something:
#   LIVENESS  a real abandoned conversion is there (claim, bound, owner dead): the reaper has work to do.
#   LIVENESS  the reader holds ACCESS SHARE on the table for the whole run.
#   LIVENESS  the sweep's reaper is seen QUEUED for ACCESS EXCLUSIVE behind the reader: the wait is real.
#   CONTRACT  an ordinary write to the table completes under a ceiling far below the reader's life.
#   CONTRACT  the sweep itself finishes while the reader is still open (it deferred, it did not stall).
#   CONTRACT  the deferral is recorded as skip_transmute_reap, exactly, and the bound and claim are kept.
#   LIVENESS  once the reader is gone, the next sweep undoes the conversion (transmute_reap, bound gone).
#
# TIMING. The reaper's bound is 5 s, the write's ceiling is WRITE_CEILING (12 s), the reader lives
# READER_HOLD (40 s). Every sample is its own docker exec (~100 ms), against a 5 s window. A build that
# waits for the reader cannot pass: its write waits the reader's whole life, past the ceiling.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_reap_no_lock_timeout -- the reaper's SET lock_timeout removed, so it waits forever again.
#
# Usage: transmute_reap_lock_timeout.sh <container> <db> [install.sql]
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
WRITE_CEILING=${WRITE_CEILING:-12}
READER_HOLD=${READER_HOLD:-40}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-78s %s\n' "$1" "$2"
  else printf 'FAIL  %-78s got %s, want %s\n' "$1" "'$2'" "'$3'"; fail=1; fi
}
cleanup() {
  docker exec "$C" psql -U postgres -d postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity
      where datname = '$DB' and application_name like 'pgpm_rlt_%'" >/dev/null 2>&1
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-78s %s\n' "the install under test installed" "$INSTALL"; exit 1
fi

q "create table public.rlt (id bigint primary key, body text);
   insert into public.rlt select g, 'row ' || g from generate_series(1, 50) g;
   create table public.rlt_ref (rid bigint primary key, id bigint references public.rlt);" >/dev/null

# A REAL abandoned conversion: the holder keeps the referencing table locked, so the cutover times out
# dropping the preserved incoming key after phase 1 committed the bound and the claim; the converting
# psql then exits, so the claim's owner is dead.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_rlt_holder'" \
  -c "begin; lock table public.rlt_ref in access share mode; select pg_sleep(4); commit;" >/dev/null 2>&1 &
HOLDER=$!
for _ in $(seq 1 50); do
  [ "$(q "select count(*) from pg_stat_activity where application_name = 'pgpm_rlt_holder' and wait_event = 'PgSleep'")" = 1 ] && break
  sleep 0.1
done
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "call pgpm.transmute('public.rlt', 'id', 1000::bigint,
  p_obtain => 2, p_lock_timeout => '1s', p_incoming_fks => 'preserve')" >/dev/null 2>&1
wait "$HOLDER" 2>/dev/null
check "LIVENESS: an abandoned conversion is there for the reaper (claim,bound,owner_dead)" \
  "$(q "select (select count(*) from pgpm.transmute_inflight where parent_table = 'public.rlt'::regclass) || ','
            || (select count(*) from pg_constraint where conrelid = 'public.rlt'::regclass and conname = 'pgpm_monolith_bound') || ','
            || (select (not pgpm._session_alive(owner_pid, owner_backend_start))::text
                  from pgpm.transmute_inflight where parent_table = 'public.rlt'::regclass)")" "1,1,true"

# The long reader, tagged so the teardown terminates exactly this backend.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_rlt_reader'" \
  -c "begin; select count(*) from public.rlt; select pg_sleep($READER_HOLD); commit;" >/dev/null 2>&1 &
READER=$!
held=no
for _ in $(seq 1 50); do
  if [ "$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
              where a.application_name = 'pgpm_rlt_reader' and l.relation = 'public.rlt'::regclass
                and l.mode = 'AccessShareLock' and l.granted")" = 1 ]; then held=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the reader holds ACCESS SHARE on the table" "$held" "yes"

# The sweep, as pg_cron runs it: a bare CALL with the session's default lock_timeout.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_rlt_sweep'" \
  -c "call pgpm.maintain_all()" >/dev/null 2>&1 &
SWEEP=$!
queued=no
for _ in $(seq 1 40); do
  if [ "$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
              where a.application_name = 'pgpm_rlt_sweep' and l.relation = 'public.rlt'::regclass
                and l.mode = 'AccessExclusiveLock' and not l.granted")" = 1 ]; then queued=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the sweep's reaper is queued for ACCESS EXCLUSIVE behind the reader" "$queued" "yes"

# THE CONTRACT: an ordinary write the bound admits (id 60 is inside [0, 1000)), timed.
t0=$SECONDS
out=$(docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set statement_timeout = '${WRITE_CEILING}s'" \
  -c "insert into public.rlt values (60, 'during the sweep') returning id" 2>&1)
check "an ordinary write is not held up behind the reaper (took $((SECONDS - t0)) s)" "$out" "60"

# The sweep finishes on its own while the reader is still open: it deferred, it did not wait.
for _ in $(seq 1 $((WRITE_CEILING * 5))); do kill -0 "$SWEEP" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$SWEEP" 2>/dev/null; then swept="still running"; else swept="finished"; fi
check "the sweep finished without waiting for the reader" "$swept" "finished"
check "LIVENESS: the reader was still open when it did" \
  "$(q "select count(*) from pg_stat_activity where application_name = 'pgpm_rlt_reader' and state = 'active'")" "1"
check "the deferral is logged, skip_transmute_reap exactly, with the lock timeout as its reason" \
  "$(q "select string_agg(action || ':' || method, ',') from pgpm.log
         where parent_table = 'public.rlt'::regclass and action in ('skip_transmute_reap', 'transmute_reap')")" \
  "skip_transmute_reap:canceling statement due to lock timeout"
check "the bound and the claim are kept for the next tick" \
  "$(q "select (select count(*) from pg_constraint where conrelid = 'public.rlt'::regclass and conname = 'pgpm_monolith_bound') || ','
            || (select count(*) from pgpm.transmute_inflight where parent_table = 'public.rlt'::regclass)")" "1,1"

# LIVENESS: with the reader gone, the next sweep undoes the conversion, so the deferral above was the lock.
cleanup
wait "$READER" 2>/dev/null
wait "$SWEEP" 2>/dev/null
q "call pgpm.maintain_all()" >/dev/null
check "LIVENESS: once the reader is gone the next sweep undoes it (bound,claim,transmute_reap)" \
  "$(q "select (select count(*) from pg_constraint where conrelid = 'public.rlt'::regclass and conname = 'pgpm_monolith_bound') || ','
            || (select count(*) from pgpm.transmute_inflight where parent_table = 'public.rlt'::regclass) || ','
            || (select count(*) from pgpm.log where parent_table = 'public.rlt'::regclass and action = 'transmute_reap')")" "0,0,1"
check "the write made during the sweep is there" "$(q "select body from public.rlt where id = 60")" "during the sweep"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
