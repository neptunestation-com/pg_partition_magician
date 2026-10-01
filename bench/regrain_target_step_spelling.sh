#!/usr/bin/env bash
# regrain_target_step_spelling.sh <container> <db> [install.sql]
#
# Run tests/210_regrain_target_step_spelling_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back: set_regrain (and
# regrain_step, regrain() and a tick) accepted a whole target step written with a fractional part ('10.0')
# on an integer control column, so the grid wrote every fine cell's bound as '0.0', '10.0', ... and every
# tick after the prepare failed creating the first one and logged skip_regrain (#784, pass 6 F3-02).
# Mutation: regrain_step_scale_on_integer (the spelling check is skipped).
# The file is the acceptance test; this wrapper exists so the mutations have a guard the
# discriminate track can run against the mutant, in the shape of bench/retire_straddle.sh.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/210_regrain_target_step_spelling_test.sql}"
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
  q -d "$DB" -q -c "ALTER DATABASE $DB SET poc.seed_count = 8000; ALTER DATABASE $DB SET poc.events_count = 4000;" >/dev/null 2>&1
  q -d "$DB" -q -f /repo/fixtures/demo.sql >/dev/null 2>&1
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "set_regrain refuses a whole step spelled with a fraction" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "set_regrain refuses a whole step spelled with a fraction" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
