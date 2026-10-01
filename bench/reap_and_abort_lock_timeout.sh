#!/usr/bin/env bash
# Guard _detach_reap and transmute_abort against parking behind a long reader (issue #708).
# Run by CI (`./test.sh perf`).
#
# THE DEFECT. #684 bounded _transmute_reap's ACCESS EXCLUSIVE wait (bench/transmute_reap_lock_timeout.sh)
# and left two more of the same kind in the core, both waiting under whatever the session had (pg_cron's
# default, and psql's, is 0: wait forever):
#   * transmute_abort's ALTER TABLE ... DROP CONSTRAINT pgpm_monolith_bound on the operator's live table;
#   * _detach_reap's ALTER TABLE ... DETACH PARTITION ... FINALIZE, which maintain_all runs before any
#     lock_timeout is set, on the abandoned partition.
# One long reader of the table (or the partition) parked either, and a PENDING ACCESS EXCLUSIVE queues every
# later lock request behind it, so every read and write of it waited for the reader to end; for the reaper,
# the whole sweep did too. The fix bounds both at transmute's default (p_lock_timeout, 5 s): the abort
# refuses with lock_not_available, the reaper logs fail_detach_reap and leaves the partition for next tick.
#
# WHY A SHELL HARNESS. The contract is about a THIRD session: an ordinary read or write attempted while the
# DDL is queued behind a reader. pgTAP gives one session per file. tests/198 pins what one session plus
# dblink can see (each call returns, the per-row deferral and its log row, the refusal's message, the
# caller's setting left alone, the work done once the reader has gone).
#
# WHAT IT ASSERTS, per section, each paired with the witness that makes it mean something:
#   LIVENESS  the work is really there (an abandoned conversion; an abandoned pending detach).
#   LIVENESS  the reader holds ACCESS SHARE for the whole run.
#   LIVENESS  the DDL is seen QUEUED for ACCESS EXCLUSIVE behind the reader: the wait is real.
#   CONTRACT  an ordinary write (the table) or read (the partition) completes under a ceiling far below the
#             reader's life.
#   CONTRACT  the abort, or the sweep, returns on its own while the reader is still open.
#   CONTRACT  it changed nothing it could not finish: the bound and claim kept / the partition still pending,
#             and the reaper's deferral is logged fail_detach_reap, exactly, with the lock timeout as reason.
#   LIVENESS  once the reader is gone the same call does the work, so the refusal above was the lock.
#
# TIMING. Each bound is 5 s, the ceiling is WRITE_CEILING (12 s), a reader lives READER_HOLD (40 s). Every
# sample is its own docker exec (~100 ms), against a 5 s window. A build that waits for the reader cannot
# pass: its read or write waits the reader's whole life, past the ceiling.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   transmute_abort_no_lock_timeout -- the abort's set_config of p_lock_timeout removed (the parameter, its
#                                      validation and the refusal kept), so the DROP waits forever again.
#   detach_reap_no_lock_timeout     -- _detach_reap's SET lock_timeout clause removed, so the FINALIZE
#                                      waits forever again.
#
# Usage: reap_and_abort_lock_timeout.sh <container> <db> [install.sql]
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
WRITE_CEILING=${WRITE_CEILING:-12}
READER_HOLD=${READER_HOLD:-40}
LOG=$(mktemp)
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-82s %s\n' "$1" "$2"
  else printf 'FAIL  %-82s got %s, want %s\n' "$1" "'$2'" "'$3'"; fail=1; fi
}
end_app() { # <application_name>: terminate exactly that tagged backend
  docker exec "$C" psql -U postgres -d postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity
      where datname = '$DB' and application_name = '$1'" >/dev/null 2>&1
}
cleanup() {
  docker exec "$C" psql -U postgres -d postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity
      where datname = '$DB' and application_name like 'pgpm_ral_%'" >/dev/null 2>&1
}
# waits up to ~$2 tenths of a second for the query $1 to return 1; prints yes or no
await() {
  local _
  for _ in $(seq 1 "$2"); do
    if [ "$(q "$1")" = 1 ]; then echo yes; return; fi
    sleep 0.1
  done
  echo no
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-82s %s\n' "the install under test installed" "$INSTALL"; exit 1
fi

echo "--- transmute_abort ---"
q "create table public.rab (id bigint primary key, body text);
   insert into public.rab select g, 'row ' || g from generate_series(1, 50) g;
   create table public.rab_ref (rid bigint primary key, id bigint references public.rab);" >/dev/null

# A REAL abandoned conversion: the holder keeps the referencing table locked, so the cutover times out
# dropping the preserved incoming key after phase 1 committed the bound and the claim; the converting
# psql then exits, so the claim's owner is dead.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_ral_holder'" \
  -c "begin; lock table public.rab_ref in access share mode; select pg_sleep(4); commit;" >/dev/null 2>&1 &
HOLDER=$!
await "select count(*) from pg_stat_activity where application_name = 'pgpm_ral_holder' and wait_event = 'PgSleep'" 50 >/dev/null
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "call pgpm.transmute('public.rab', 'id', 1000::bigint,
  p_obtain => 2, p_lock_timeout => '1s', p_incoming_fks => 'preserve')" >/dev/null 2>&1
wait "$HOLDER" 2>/dev/null
check "LIVENESS: an abandoned conversion is there to abort (claim,bound,owner_dead)" \
  "$(q "select (select count(*) from pgpm.transmute_inflight where parent_table = 'public.rab'::regclass) || ','
            || (select count(*) from pg_constraint where conrelid = 'public.rab'::regclass and conname = 'pgpm_monolith_bound') || ','
            || (select (not pgpm._session_alive(owner_pid, owner_backend_start))::text
                  from pgpm.transmute_inflight where parent_table = 'public.rab'::regclass)")" "1,1,true"

docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_ral_reader1'" \
  -c "begin; select count(*) from public.rab; select pg_sleep($READER_HOLD); commit;" >/dev/null 2>&1 &
READER1=$!
check "LIVENESS: the reader holds ACCESS SHARE on the table" \
  "$(await "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
              where a.application_name = 'pgpm_ral_reader1' and l.relation = 'public.rab'::regclass
                and l.mode = 'AccessShareLock' and l.granted" 50)" "yes"

# The operator's abort: no p_lock_timeout, the session's default lock_timeout (0).
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_ral_abort'" \
  -c "select pgpm.transmute_abort('public.rab')" >"$LOG" 2>&1 &
ABORT=$!
check "LIVENESS: the abort is queued for ACCESS EXCLUSIVE behind the reader" \
  "$(await "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
              where a.application_name = 'pgpm_ral_abort' and l.relation = 'public.rab'::regclass
                and l.mode = 'AccessExclusiveLock' and not l.granted" 40)" "yes"

# THE CONTRACT: an ordinary write the bound admits (id 60 is inside [0, 1000)), timed.
t0=$SECONDS
out=$(docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set statement_timeout = '${WRITE_CEILING}s'" \
  -c "insert into public.rab values (60, 'during the abort') returning id" 2>&1)
check "an ordinary write is not held up behind the abort (took $((SECONDS - t0)) s)" "$out" "60"

for _ in $(seq 1 $((WRITE_CEILING * 5))); do kill -0 "$ABORT" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$ABORT" 2>/dev/null; then aborted="still waiting"
else aborted=$(grep -c 'pg_partition_magician: transmute_abort(rab) could not take ACCESS EXCLUSIVE on rab within 5s' "$LOG"); fi
check "the abort refused on the lock instead of waiting, naming the table and its bound" "$aborted" "1"
check "LIVENESS: the reader was still open when it did" \
  "$(q "select count(*) from pg_stat_activity where application_name = 'pgpm_ral_reader1' and state = 'active'")" "1"
check "the bound and the claim are kept, and no transmute_abort is logged" \
  "$(q "select (select count(*) from pg_constraint where conrelid = 'public.rab'::regclass and conname = 'pgpm_monolith_bound') || ','
            || (select count(*) from pgpm.transmute_inflight where parent_table = 'public.rab'::regclass) || ','
            || (select count(*) from pgpm.log where parent_table = 'public.rab'::regclass and action = 'transmute_abort')")" "1,1,0"

end_app pgpm_ral_reader1
wait "$READER1" 2>/dev/null
wait "$ABORT" 2>/dev/null
check "LIVENESS: once the reader is gone the same call aborts the conversion" \
  "$(q "select pgpm.transmute_abort('public.rab')")" "t"
check "LIVENESS: and the bound and claim are gone, the abort logged once (bound,claim,log)" \
  "$(q "select (select count(*) from pg_constraint where conrelid = 'public.rab'::regclass and conname = 'pgpm_monolith_bound') || ','
            || (select count(*) from pgpm.transmute_inflight where parent_table = 'public.rab'::regclass) || ','
            || (select count(*) from pgpm.log where parent_table = 'public.rab'::regclass and action = 'transmute_abort')")" "0,0,1"
check "the write made during the abort is there" "$(q "select body from public.rab where id = 60")" "during the abort"

echo "--- _detach_reap, in maintain_all ---"
q "create table public.rdr (id bigint not null primary key, payload text);
   insert into public.rdr select g, 'x' from generate_series(1, 500) g;" >/dev/null
# a CALL of a committing procedure must be its own statement, not part of a multi-statement -c
q "call pgpm.transmute('public.rdr', 'id', 1000::bigint, p_obtain => 3)" >/dev/null
q "insert into public.rdr values (2001, 'p1'), (2002, 'p2'), (2005, 'p5')" >/dev/null
CHILD=$(q "select child_name from pgpm.part where parent_table = 'public.rdr'::regclass and lo = '2000'")
check "LIVENESS: the partition to abandon holds its three rows" \
  "$(q "select string_agg(id || ':' || payload, ',' order by id) from public.$CHILD")" "2001:p1,2002:p2,2005:p5"

# An ABANDONED detach, as tests/116 builds one: a holder on the parent (pruned to the monolith) parks a
# concurrent detach in its wait phase, and the detacher's session dies there.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_ral_h1'" \
  -c "begin; select count(*) from public.rdr where id < 1000; select pg_sleep($READER_HOLD); commit;" >/dev/null 2>&1 &
H1=$!
await "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
        where a.application_name = 'pgpm_ral_h1' and l.relation = 'public.rdr'::regclass and l.granted" 50 >/dev/null
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_ral_detacher'" \
  -c "alter table public.rdr detach partition public.$CHILD concurrently" >/dev/null 2>&1 &
X=$!
check "LIVENESS: the concurrent detach set the pending flag and parked in its wait phase" \
  "$(await "select (exists (select 1 from pg_inherits where inhrelid = 'public.$CHILD'::regclass and inhdetachpending)
                    and exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                                 where a.application_name = 'pgpm_ral_detacher' and l.locktype = 'virtualxid'
                                   and not l.granted))::int" 50)" "yes"
end_app pgpm_ral_detacher
wait "$X" 2>/dev/null
end_app pgpm_ral_h1
wait "$H1" 2>/dev/null
check "LIVENESS: the detach is abandoned: still pending, its session and the holder gone" \
  "$(await "select (exists (select 1 from pg_inherits where inhrelid = 'public.$CHILD'::regclass and inhdetachpending)
                    and not exists (select 1 from pg_stat_activity where application_name in ('pgpm_ral_detacher', 'pgpm_ral_h1')))::int" 50)" "yes"

docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_ral_reader2'" \
  -c "begin; select count(*) from public.$CHILD; select pg_sleep($READER_HOLD); commit;" >/dev/null 2>&1 &
READER2=$!
check "LIVENESS: the reader holds ACCESS SHARE on the abandoned partition" \
  "$(await "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
              where a.application_name = 'pgpm_ral_reader2' and l.relation = 'public.$CHILD'::regclass
                and l.mode = 'AccessShareLock' and l.granted" 50)" "yes"

# The sweep, as pg_cron runs it: a bare CALL with the session's default lock_timeout.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_ral_sweep'" \
  -c "call pgpm.maintain_all()" >/dev/null 2>&1 &
SWEEP=$!
check "LIVENESS: the sweep's reaper is queued for ACCESS EXCLUSIVE on the partition behind the reader" \
  "$(await "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
              where a.application_name = 'pgpm_ral_sweep' and l.relation = 'public.$CHILD'::regclass
                and l.mode = 'AccessExclusiveLock' and not l.granted" 40)" "yes"

# THE CONTRACT: an ordinary read of the partition, timed.
t0=$SECONDS
out=$(docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set statement_timeout = '${WRITE_CEILING}s'" \
  -c "select string_agg(id || ':' || payload, ',' order by id) from public.$CHILD" 2>&1)
check "an ordinary read of the partition is not held up behind the reaper (took $((SECONDS - t0)) s)" \
  "$out" "2001:p1,2002:p2,2005:p5"

for _ in $(seq 1 $((WRITE_CEILING * 5))); do kill -0 "$SWEEP" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$SWEEP" 2>/dev/null; then swept="still running"; else swept="finished"; fi
check "the sweep finished without waiting for the reader" "$swept" "finished"
check "LIVENESS: the reader was still open when it did" \
  "$(q "select count(*) from pg_stat_activity where application_name = 'pgpm_ral_reader2' and state = 'active'")" "1"
check "the deferral is logged, fail_detach_reap exactly, with the lock timeout as its reason" \
  "$(q "select string_agg(action || ':' || method, ',') from pgpm.log
         where parent_table = 'public.rdr'::regclass and action in ('detach_reap', 'fail_detach_reap')")" \
  "fail_detach_reap:canceling statement due to lock timeout"
check "the partition is left pending for the next tick" \
  "$(q "select count(*) from pg_inherits where inhrelid = 'public.$CHILD'::regclass and inhdetachpending")" "1"

# LIVENESS: with the reader gone, the next sweep finalizes it, so the deferral above was the lock.
end_app pgpm_ral_reader2
wait "$READER2" 2>/dev/null
wait "$SWEEP" 2>/dev/null
q "call pgpm.maintain_all()" >/dev/null
check "LIVENESS: once the reader is gone the next sweep finalizes it (pending,detach_reap)" \
  "$(q "select (select count(*) from pg_inherits where inhrelid = 'public.$CHILD'::regclass) || ','
            || (select count(*) from pgpm.log where parent_table = 'public.rdr'::regclass and action = 'detach_reap')")" "0,1"
check "the finalized partition keeps its rows" \
  "$(q "select string_agg(id || ':' || payload, ',' order by id) from public.$CHILD")" "2001:p1,2002:p2,2005:p5"

cleanup
rm -f "$LOG"
docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
