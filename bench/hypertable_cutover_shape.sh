#!/usr/bin/env bash
# Guard from_hypertable_cutover against swapping in a copy whose shape is no longer the source's (#738).
#
# THE DEFECT. from_hypertable_copy fixes the destination's shape once, by CREATE TABLE ... LIKE, and the
# documented two-phase flow lets the workload run on until the cutover. The cutover read its column list and
# its conservation fingerprint from the source only, so DDL on the live hypertable in between (a column
# dropped, a default changed, a CHECK added) was silently reverted by the swap: the dropped column came back
# with its old values, the default reverted, the CHECK was gone. The fix compares the two shapes
# (_from_hypertable_check_shape) twice: up front, and again under the swap's ACCESS EXCLUSIVE on both.
#
# TWO PARTS, one per check, each with the mutation that removes it (bench/mutations/mutate.py):
#   PART A runs tests/timescale/db/28 (DDL made before the cutover is called). The up-front check refuses
#          it by name before the pre-drain or the index pre-builds run; without it the under-lock check
#          still names a dropped column, a changed default and an added CHECK, but a column ADDED since the
#          copy kills the pre-lock reads of the copy with a raw error first, which the message pin rejects.
#          hypertable_cutover_shape_unchecked_up_front -- the up-front call deleted. Breaks PART A (D).
#   PART B is the window that needs a second session: DDL that lands WHILE the cutover prepares, after the
#          up-front check and before the lock. Only the under-lock check can see it.
#          hypertable_cutover_shape_unchecked_under_lock -- the under-lock call deleted. Breaks PART B: the
#          cutover converts the table with the copy's old default and without the new CHECK.
#
# HOW PART B LANDS DDL IN THE WINDOW, deterministically rather than by timing (no sleep decides anything).
# A holder session takes ACCESS EXCLUSIVE on the COPY. The cutover (p_predrain => false, so its first touch
# of the copy is the pre-lock baseline read, in the swap transaction, after the up-front check) queues
# behind it, holding nothing on the source; that is asserted, not assumed. The DDL then runs on the source
# and commits while the cutover is still queued, which is asserted too. The holder is ended, and the cutover
# goes on to its lock. p_lock_timeout is raised to 60s so the queueing on the copy is not cut short by the
# 5s default; it bounds nothing else this part relies on.
#
# Usage: hypertable_cutover_shape.sh <container> <db> [pgpm_hypertable/install.sql]
# Runs on the TIMESCALE track's container (a real hypertable: the DDL is TimescaleDB's to propagate to the
# chunks), which is why these mutations sit in MUTATION_TRACK=timescale. run_timescale also runs it against
# the unmutated module, so a harness that failed against everything would not read as discrimination.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
TEST_FILE=/repo/tests/timescale/db/28_from_hypertable_cutover_shape_test.sql
LABEL="each shape change made before the call is refused by name"
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

# ============================ PART A: DDL before the call (tests/timescale/db/28) ============================
echo "--- PART A: DDL made before the cutover is called"
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

# ============================ PART B: DDL while the cutover prepares ============================
echo "--- PART B: DDL that lands after the up-front check, before the lock"
if ! fresh_db; then
  rm -f "$LOG"; q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; exit 1
fi
v "create table public.hcs (id bigint not null, ts timestamptz not null, v text default 'old',
     primary key (id, ts));
   select create_hypertable('public.hcs', 'ts', chunk_time_interval => interval '1 day');
   insert into public.hcs (id, ts) select g, timestamptz '2026-09-01 00:00+00' + g * interval '3 hours'
     from generate_series(1, 30) g;" >/dev/null
v "call pgpm.from_hypertable_copy('public.hcs', 'ts')" >/dev/null
check "LIVENESS: the copy holds the 30 rows on the old default" \
  "$(v "select count(*) || '/' || min(v) || '/' || max(v) from public.hcs_pgpm_dest")" "30/old/old"
EXPECT_MD5=$(v "select md5(string_agg(g || ':old', ',' order by g)) from generate_series(1, 30) g")

# The holder: ACCESS EXCLUSIVE on the copy, tagged so the teardown ends exactly this backend.
q -d "$DB" -qtA -c "set application_name = 'pgpm_hcs_holder'" \
  -c "begin; lock table public.hcs_pgpm_dest in access exclusive mode; select pg_sleep($HOLD); commit;" >/dev/null 2>&1 &
HOLDER=$!
held=no
for _ in $(seq 1 100); do
  if [ "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
             where a.application_name = 'pgpm_hcs_holder' and l.relation = 'public.hcs_pgpm_dest'::regclass
               and l.mode = 'AccessExclusiveLock' and l.granted")" = 1 ]; then held=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the holder has ACCESS EXCLUSIVE on the copy" "$held" "yes"

q -d "$DB" -qtA -c "set application_name = 'pgpm_hcs_cutover'" \
  -c "call pgpm.from_hypertable_cutover('public.hcs', 'ts', interval '1 day', p_paused => false,
                                        p_predrain => false, p_lock_timeout => '60s')" >"$LOG" 2>&1 &
CUT=$!
queued=no
for _ in $(seq 1 150); do
  if [ "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
             where a.application_name = 'pgpm_hcs_cutover' and l.relation = 'public.hcs_pgpm_dest'::regclass
               and not l.granted")" = 1 ]; then queued=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the cutover is queued on the copy, past its up-front check" "$queued" "yes"
check "LIVENESS: and holds no lock on the source while it waits (the window is open)" \
  "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
         where a.application_name = 'pgpm_hcs_cutover' and l.relation = 'public.hcs'::regclass")" "0"

# The DDL, in its own session, bounded so a source lock the cutover should not hold fails here, not hangs.
ddl=$(q -d "$DB" -qtA -c "set lock_timeout = '20s'" \
  -c "alter table public.hcs alter column v set default 'new'" \
  -c "alter table public.hcs add constraint hcs_v_chk check (v <> 'forbidden')" 2>&1)
check "LIVENESS: the DDL on the source committed (default 'new', CHECK added)" \
  "$(echo "$ddl" | grep -c 'ERROR')/$(v "select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a
         on a.attrelid = d.adrelid and a.attnum = d.adnum where a.attrelid = 'public.hcs'::regclass and a.attname = 'v'")/$(v "select count(*) from pg_constraint where conrelid = 'public.hcs'::regclass and conname = 'hcs_v_chk'")" \
  "0/'new'::text/1"
check "LIVENESS: while the cutover was still queued on the copy" \
  "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
         where a.application_name = 'pgpm_hcs_cutover' and l.relation = 'public.hcs_pgpm_dest'::regclass
           and not l.granted")" "1"

end_session pgpm_hcs_holder
wait "$HOLDER" 2>/dev/null
for _ in $(seq 1 300); do kill -0 "$CUT" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$CUT" 2>/dev/null; then
  printf 'FAIL  %-78s %s\n' "the cutover finished once the holder was gone" "still running"; fail=1
  end_session pgpm_hcs_cutover
fi
wait "$CUT" 2>/dev/null

# THE CONTRACT: the cutover refused, under its lock, naming both differences.
check "the cutover refused the swap: the copy no longer has the source's shape" \
  "$(grep -cF "from_hypertable_cutover(hcs) refusing to swap: the copy hcs_pgpm_dest no longer has the source's shape: column v has default 'new'::text on the source but default 'old'::text on the copy; CHECK hcs_v_chk (CHECK ((v <> 'forbidden'::text))) is on the source but not on the copy." "$LOG")" "1"
check "the source is still the hypertable, with every row by identity" \
  "$(v "select (select count(*) from timescaledb_information.hypertables where hypertable_schema = 'public'
                 and hypertable_name = 'hcs') || '/' || (select relkind::text from pg_class where oid = 'public.hcs'::regclass)
            || '/' || (select md5(string_agg(id || ':' || v, ',' order by id)) from public.hcs)")" "1/r/$EXPECT_MD5"
check "and keeps the DDL: the new default and the CHECK are still on it" \
  "$(v "select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid
         and a.attnum = d.adnum where a.attrelid = 'public.hcs'::regclass and a.attname = 'v'")/$(v "select count(*) from pg_constraint where conrelid = 'public.hcs'::regclass and conname = 'hcs_v_chk'")" \
  "'new'::text/1"

# LIVENESS: the remedy the message names converts the table in its current shape, so the refusal above was
# the shape and not something else about this table.
out=$(v "call pgpm.from_hypertable_copy('public.hcs', 'ts')"; v "call pgpm.from_hypertable_cutover('public.hcs', 'ts', interval '1 day', p_paused => false)")
check "LIVENESS: after a fresh copy the cutover converts the table" \
  "$(echo "$out" | grep -c 'ERROR:')/$(v "select relkind::text from pg_class where oid = 'public.hcs'::regclass")" "0/p"
check "LIVENESS: with the source's default and CHECK, and every row" \
  "$(v "insert into public.hcs (id, ts) values (100, timestamptz '2026-09-02 07:00+00')"; v "select v from public.hcs where id = 100")/$(v "select count(*) from pg_constraint where conrelid = 'public.hcs'::regclass and conname = 'hcs_v_chk'")/$(v "select md5(string_agg(id || ':' || v, ',' order by id)) from public.hcs where id <= 30")" \
  "new/1/$EXPECT_MD5"

rm -f "$LOG"
q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
