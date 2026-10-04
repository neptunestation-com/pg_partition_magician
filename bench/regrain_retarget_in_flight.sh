#!/usr/bin/env bash
# regrain_retarget_in_flight.sh <container> <db> [install.sql]
#
# Run tests/261_regrain_step_retarget_in_flight_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #905):
# regrain_step refused a second run only on a DIFFERENT child of the parent (#267), so a hand regrain_step
# or regrain() at another target on the child an auto-regrain was splitting resumed the run on the other
# grid, minted a copy overlapping the ones already made, and every later swap failed 'would overlap'
# (skip_regrain) until regrain_cancel; a maintain tick did the same to a run started by hand at a step
# other than regrain_to. The file is the acceptance test; this wrapper exists so the mutation has a guard
# the discriminate track can run against the mutant, in the shape of bench/regrain_capture_source_grantees.sh.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_step_retarget_unchecked  -- regrain_step no longer asks whether the run in flight on the child
#                                       was cut on the requested step's grid, the pre-fix shape.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/261_regrain_step_retarget_in_flight_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a step off the in-flight run's grid is refused" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a step off the in-flight run's grid is refused" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
