#!/usr/bin/env bash
# regrain_target_time_precision.sh <container> <db> [install.sql]
#
# Run tests/277_regrain_target_time_precision_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back: set_regrain (and
# regrain_step, regrain() and a tick) accepted a regrain target step finer than a timestamp(p) or
# timestamptz(p) control column's fractional-second precision ('500 milliseconds' on a timestamptz(0) key),
# so the run copied every sub-range and every swap then failed 'empty range bound' as ATTACH rounded two
# adjacent fine bounds to the same instant, with the capture trigger and the TRUNCATE refusal left on the
# source (#980, pass 9 F3-03; the time-key twin of #899).
# Mutation: regrain_step_time_precision_unread (the precision check is skipped).
# The file is the acceptance test; this wrapper exists so the mutation has a guard the discriminate track
# can run against the mutant, in the shape of bench/regrain_target_column_scale.sh.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/277_regrain_target_time_precision_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "set_regrain refuses a step finer than the time precision" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "set_regrain refuses a step finer than the time precision" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
