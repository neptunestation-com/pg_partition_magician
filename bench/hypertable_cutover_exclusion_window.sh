#!/usr/bin/env bash
# Guard from_hypertable_cutover against dropping an EXCLUDE constraint added while it prepares (#841).
#
# THE DEFECT. The cutover asked _from_hypertable_check_exclusion (#675) only up front, not again under its
# ACCESS EXCLUSIVE, unlike the shape (#738) and the key and frontier (#792), which it re-asks there because
# the source is unlocked from the up-front checks to the lock (the pre-drain's commits, the index
# pre-builds). An exclusion constraint added in that window was dropped by the swap with the hypertable,
# and the migrated table accepted the rows it had rejected. The fix asks the check again under the lock.
#
# TWO PARTS, one per call of the check in the cutover, each with the mutation that removes it
# (bench/mutations/mutate.py):
#   PART A runs tests/timescale/db/41 (a constraint added after the copy, before the call). The up-front
#          check refuses it before the pre-drain commits a batch; without it the pre-drain (one row per
#          batch there, four rows past the watermark) reaches its first COMMIT inside throws_like and dies
#          with 2D000, which the message pin rejects, before the check under the lock is ever reached.
#          hypertable_cutover_no_exclusion_check -- the up-front call deleted. Breaks PART A.
#   PART B is the window that needs a second session: a constraint that lands WHILE the cutover prepares,
#          after the up-front check and before the lock. Only the check under the lock can see it.
#          hypertable_cutover_exclusion_unchecked_under_lock -- the call under the lock deleted. Breaks
#          PART B: the cutover converts the table, the constraint is gone and a conflicting row goes in.
#
# HOW PART B LANDS THE CONSTRAINT IN THE WINDOW, deterministically rather than by timing (no sleep decides
# anything), as bench/hypertable_cutover_shape.sh does for its DDL. A holder session takes ACCESS EXCLUSIVE
# on the COPY. The cutover (p_predrain => false, so its first touch of the copy is the pre-lock baseline
# read, in the swap transaction, after the up-front checks) queues behind it, holding nothing on the source;
# that is asserted, not assumed. The constraint is then added to the source and commits while the cutover
# is still queued, which is asserted too. The holder is ended, and the cutover goes on to its lock.
# p_lock_timeout is raised to 60s so the queueing on the copy is not cut short by the 5s default; it bounds
# nothing else this part relies on.
#
# Usage: hypertable_cutover_exclusion_window.sh <container> <db> [pgpm_hypertable/install.sql]
# Runs on the TIMESCALE track's container (a real hypertable: the constraint is TimescaleDB's to build on
# the chunks), which is why these mutations sit in MUTATION_TRACK=timescale. run_timescale also runs it
# against the unmutated module, so a harness that failed against everything would not read as
# discrimination.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
TEST_FILE=/repo/tests/timescale/db/41_from_hypertable_cutover_exclusion_window_test.sql
LABEL="an exclusion constraint added after the copy is refused before anything commits"
HOLD=${HOLD:-60}
LOG=$(mktemp)
fail=0

q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@"; }
v() { q -d "$DB" -qtA -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-78s %s\n' "$1" "$2"
  else printf 'FAIL  %-78s got %s, want %s\n' "$1" "'$2'" "'$3'"; fail=1; fi
}
end_session() { # <application_name>
  q -d postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity
      where datname = '$DB' and application_name = '$1'" >/dev/null 2>&1
}
fresh_db() {
  q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -d postgres -q -c "create database $DB" >/dev/null 2>&1
  q -d postgres -q -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1
  # A mutant that will not even install is NOT a pass: say which happened. Only pgpm_hypertable is mutated.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
    printf 'FAIL  %-78s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"; return 1
  fi
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
    printf 'FAIL  %-78s %s\n' "the module under test installed" "$HT"; return 1
  fi
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null 2>&1; then
    printf 'FAIL  %-78s %s\n' "the timescale fixtures loaded" "tests/timescale/fixtures.sql"; return 1
  fi
}

# ============================ PART A: the constraint added before the call (tests/timescale/db/41) ============================
echo "--- PART A: an exclusion constraint added after the copy, before the cutover is called"
if fresh_db; then
  # >>> pgTAP verdict: the same in every timescale wrapper; bench/wrapper_tap_verdicts.sh evaluates it.
  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+' | sed 's/^/    /' | head -20
  planned=$(echo "$out" | sed -nE 's/^1\.\.([0-9]+)$/\1/p' | head -1)
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+( |$)')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+( |$)')
  # pg_prove's verdict, which this runner has to apply itself. Three ways a file fails with no `not ok`,
  # each reported apart from assertions that ran and failed (discriminate.sh reads any non-zero exit as
  # "the guard caught the defect", so a harness that fails everything must say why): a raw ERROR:; a
  # psql exit other than 0, which is how a session that died part-way (FATAL, no ERROR:) shows, since it
  # never reaches finish() to print "# Looks like you planned" (#795); and a count of assertions
  # that is not the 1..N plan's, which a silently skipped assertion leaves (#601, #712).
  # A file that reached no assertion failed on its fixture, whatever stopped it, so its setup lines are
  # premises then and discriminate.sh's starved() does not read them as a catch (#1177).
  unreached=""; [ "$ran" -gt 0 ] || unreached="fixture: "
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "${unreached}the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ "$rc" != 0 ]; then
    printf 'FAIL  %-58s %s\n' "${unreached}psql ran the file to its end" "exit $rc"
    echo "$out" | grep -E 'FATAL:|connection' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ -z "$planned" ] || [ "$ran" != "$planned" ]; then
    printf 'FAIL  %-58s %s\n' "${unreached}the file ran every assertion it planned" "planned ${planned:-nothing}, $ran ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran, $bad failed"; fail=1
  fi
  # <<< pgTAP verdict
else
  fail=1
fi

# ============================ PART B: the constraint added while the cutover prepares ============================
echo "--- PART B: an exclusion constraint that lands after the up-front check, before the lock"
if ! fresh_db; then
  rm -f "$LOG"; q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; exit 1
fi
v "create table public.hxw (id bigint not null, ts timestamptz not null, dev int not null, primary key (id, ts));
   select create_hypertable('public.hxw', 'ts', chunk_time_interval => interval '1 day');
   insert into public.hxw select g, timestamptz '2026-09-01 00:00+00' + g * interval '3 hours', g
     from generate_series(1, 30) g;" >/dev/null
v "call pgpm.from_hypertable_copy('public.hxw', 'ts')" >/dev/null
EXPECT_MD5=$(v "select md5(string_agg(g || ':' || g, ',' order by g)) from generate_series(1, 30) g")
check "LIVENESS: the copy holds the 30 rows, by identity" \
  "$(v "select md5(string_agg(id || ':' || dev, ',' order by id)) from public.hxw_pgpm_dest")" "$EXPECT_MD5"

# The holder: ACCESS EXCLUSIVE on the copy, tagged so the teardown ends exactly this backend.
q -d "$DB" -qtA -c "set application_name = 'pgpm_hxw_holder'" \
  -c "begin; lock table public.hxw_pgpm_dest in access exclusive mode; select pg_sleep($HOLD); commit;" >/dev/null 2>&1 &
HOLDER=$!
held=no
for _ in $(seq 1 100); do
  if [ "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
             where a.application_name = 'pgpm_hxw_holder' and l.relation = 'public.hxw_pgpm_dest'::regclass
               and l.mode = 'AccessExclusiveLock' and l.granted")" = 1 ]; then held=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the holder has ACCESS EXCLUSIVE on the copy" "$held" "yes"

q -d "$DB" -qtA -c "set application_name = 'pgpm_hxw_cutover'" \
  -c "call pgpm.from_hypertable_cutover('public.hxw', 'ts', interval '1 day', p_paused => false,
                                        p_predrain => false, p_lock_timeout => '60s')" >"$LOG" 2>&1 &
CUT=$!
queued=no
for _ in $(seq 1 150); do
  if [ "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
             where a.application_name = 'pgpm_hxw_cutover' and l.relation = 'public.hxw_pgpm_dest'::regclass
               and not l.granted")" = 1 ]; then queued=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the cutover is queued on the copy, past its up-front checks" "$queued" "yes"
check "LIVENESS: and holds no lock on the source while it waits (the window is open)" \
  "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
         where a.application_name = 'pgpm_hxw_cutover' and l.relation = 'public.hxw'::regclass")" "0"

# The constraint, in its own session, bounded so a source lock the cutover should not hold fails here.
ddl=$(q -d "$DB" -qtA -c "set lock_timeout = '20s'" \
  -c "alter table public.hxw add constraint hxw_dev_excl exclude using btree (dev with =, ts with =)" 2>&1)
check "LIVENESS: the exclusion constraint committed on the source" \
  "$(echo "$ddl" | grep -c 'ERROR')/$(v "select count(*) from pg_constraint where conrelid = 'public.hxw'::regclass and conname = 'hxw_dev_excl' and contype = 'x'")" \
  "0/1"
check "LIVENESS: while the cutover was still queued on the copy" \
  "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
         where a.application_name = 'pgpm_hxw_cutover' and l.relation = 'public.hxw_pgpm_dest'::regclass
           and not l.granted")" "1"

end_session pgpm_hxw_holder
wait "$HOLDER" 2>/dev/null
for _ in $(seq 1 300); do kill -0 "$CUT" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$CUT" 2>/dev/null; then
  printf 'FAIL  %-78s %s\n' "the cutover finished once the holder was gone" "still running"; fail=1
  end_session pgpm_hxw_cutover
fi
wait "$CUT" 2>/dev/null

# THE CONTRACT: the cutover refused, under its lock, naming the constraint.
check "the cutover refused the swap: the exclusion constraint cannot be carried" \
  "$(grep -cF "pg_partition_magician: cannot migrate hypertable hxw -- its exclusion constraint(s) (hxw_dev_excl) cannot be carried." "$LOG")" "1"
check "the source is still the hypertable, with every row by identity" \
  "$(v "select (select count(*) from timescaledb_information.hypertables where hypertable_schema = 'public'
                 and hypertable_name = 'hxw') || '/' || (select relkind::text from pg_class where oid = 'public.hxw'::regclass)
            || '/' || (select md5(string_agg(id || ':' || dev, ',' order by id)) from public.hxw)")" "1/r/$EXPECT_MD5"
check "and keeps the constraint, which still rejects a row with dev 5 at id 5's instant" \
  "$(v "insert into public.hxw values (500, timestamptz '2026-09-01 15:00+00', 5)" | grep -c 'conflicting key value violates exclusion constraint')" \
  "1"

# LIVENESS: the remedy the message names converts the table, so the refusal above was the constraint and not
# something else about this table.
out=$(v "alter table public.hxw drop constraint hxw_dev_excl"; v "call pgpm.from_hypertable_cutover('public.hxw', 'ts', interval '1 day', p_paused => false)")
check "LIVENESS: with the constraint dropped the cutover converts the table" \
  "$(echo "$out" | grep -c 'ERROR:')/$(v "select relkind::text from pg_class where oid = 'public.hxw'::regclass")" "0/p"
check "LIVENESS: with every row, by identity" \
  "$(v "select md5(string_agg(id || ':' || dev, ',' order by id)) from public.hxw")" "$EXPECT_MD5"

rm -f "$LOG"
q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
