#!/usr/bin/env bash
# Run tests/timescale/db/32_uninstall_hypertable_capture_test.sql against an ARBITRARY copy of
# pgpm_core/uninstall.sql, so bench/discriminate.sh can point it at a mutant (issue #737).
#
# Same shape and same reason as bench/uninstall_residue.sh, on the timescale harness instead of the core
# one: the capture this file asserts uninstall removes exists only where from_hypertable_copy can run, which
# needs a real TimescaleDB. The file's load-bearing assertions are negatives ("no capture trigger, function
# or delta survives"), and a negative is equally satisfied by a copy that never installed the capture or by
# an uninstall that never ran. The file pins both with liveness witnesses (each trigger is on its
# hypertable and has logged the window's keys; the pgpm schema is gone afterwards), and its look-alike half
# (an operator's objects with the module's names and no record) is a positive that a name-pattern sweep
# breaks. Pointing the same file at a mutant uninstall.sql is what proves each half is load-bearing.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), both of uninstall.sql:
#   uninstall_keeps_hypertable_capture    -- the sweep returns at once: the pre-#737 script, which left
#                                            the copies' delta, function and trigger behind
#   uninstall_hypertable_capture_by_name  -- the sweep keys on the _pgpm_delta name instead of the copy's
#                                            record, so it drops the operator's look-alike too
#
# Usage: uninstall_hypertable_capture.sh <container> <db> [uninstall.sql]
# The third argument is the UNINSTALL script under test, a path inside the container, which the file reads
# with psql's \ir. pgpm_core/install.sql and pgpm_hypertable/install.sql are what get installed, always.
# Runs on the TIMESCALE track's container, which is why these mutations sit in MUTATION_TRACK=timescale.
#
# psql, not pg_prove: the supabase/postgres image has no pg_prove, so TAP is parsed out of psql -tAq here
# exactly as run_timescale does, including the ERROR: check and the plan check (#601): a mutant that dies
# with a raw error, or a file that stops short of its plan, must not read as the assertions failing.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; UNINSTALL="${3:-/repo/pgpm_core/uninstall.sql}"
TEST_FILE=/repo/tests/timescale/db/32_uninstall_hypertable_capture_test.sql
fail=0

q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@"; }

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
q -d postgres -q -c "create database $DB" >/dev/null 2>&1
q -d postgres -q -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1

# An install that fails is NOT a pass: say which happened. Neither install is the mutated file.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/pgpm_hypertable/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_hypertable installed" "/repo/pgpm_hypertable/install.sql"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the timescale fixtures loaded" "tests/timescale/fixtures.sql"
  fail=1
fi
# Likewise a mutant path that is not there: \ir would fail, the file would die early, and the guard would
# read as having caught the defect.
if ! docker exec "$C" test -r "$UNINSTALL"; then
  printf 'FAIL  %-58s %s\n' "the uninstall script under test exists" "$UNINSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(q -d "$DB" -tAq -v "uninstall=$UNINSTALL" -f "$TEST_FILE" 2>&1)
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+ -')
  # Two failure shapes, reported apart. A file that died early leaves a raw ERROR: or a plan shortfall,
  # which must NOT read the same as assertions that ran and failed: discriminate.sh treats any non-zero
  # exit as "the guard caught the defect", so a harness broken enough to fail against everything would
  # otherwise be reported as proving the mutation.
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if echo "$out" | grep -qE '^# Looks like you planned'; then
    printf 'FAIL  %-58s %s\n' "the file ran every assertion it planned" "$(echo "$out" | grep -E '^# Looks like you planned')"
    fail=1
  fi
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "uninstall sweeps the copies' capture and only theirs" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "uninstall sweeps the copies' capture and only theirs" "$ran ran, $bad failed"; fail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
