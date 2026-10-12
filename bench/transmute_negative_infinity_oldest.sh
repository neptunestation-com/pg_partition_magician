#!/usr/bin/env bash
# transmute_negative_infinity_oldest.sh <container> <db> [install.sql]
#
# Run tests/343_transmute_negative_infinity_oldest_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #769, bullet
# 2): transmute refused a time control's +infinity NEWEST value up front, and only an id control's non-finite
# oldest value (#895), so a timestamptz, timestamp or date control whose OLDEST value is -infinity reached
# _grid_floor raw and the operator got "cannot convert infinity to integer" or "cannot subtract infinite
# timestamps" instead of pgpm's refusal naming the table, the column and the remedy.
# The file is the acceptance test; this wrapper exists so the mutation has a guard the discriminate track can
# run against the mutant, in the shape of bench/date_key_anchor_midnight.sh.
#
# The mutation required to fail against it (bench/mutations/mutate.py):
#   transmute_time_oldest_infinity_unchecked -- _transmute's -infinity oldest-value refusal is never taken.
#                                              tests/343 parts A, B, C and D.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/343_transmute_negative_infinity_oldest_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a -infinity oldest time value is refused by pgpm" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a -infinity oldest time value is refused by pgpm" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
