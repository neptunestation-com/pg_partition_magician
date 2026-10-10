#!/usr/bin/env bash
# regrain_registered_grid_off_unit.sh <container> <db> [install.sql]
#
# Run tests/324_regrain_registered_grid_off_unit_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (#1117, #1139 bullet
# 1): a time grid an older install registered off its control column's unit (a date key anchored at noon, a
# timestamptz(0) key anchored 0.4 s off the second) was not re-asked at regrain, since _regrain_step_shape asked
# the unit rule of the target only, so the run copied every sub-range and every swap then failed, leaving the
# copies, the capture trigger and the TRUNCATE refusal on the source until regrain_cancel; and nothing on the
# upgrade flagged such a grid.
# The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track can
# run against the mutant, in the shape of bench/regrain_target_time_precision.sh. The file re-runs the install
# with \ir, handed the copy under test as the psql variable `install` (as bench/install_keeps_dependent_views.sh
# hands tests/281 its own), so the upgrade block judged is the mutant's.
#
# Mutations (bench/mutations/mutate.py):
#   regrain_step_registered_time_anchor_unasked  -- _regrain_step_shape asks a time key's registered step but
#                                                  not its registered anchor (the anchor clause alone).
#   upgrade_grid_off_unit_unflagged              -- the upgrade block finds the off-unit grid and logs nothing.
#
# Runs on the plain core image (pgtap and pg_prove). The install path is read inside the container.
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted somewhere
# other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/324_regrain_registered_grid_off_unit_test.sql}"
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
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set install=$INSTALL $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a time grid registered off its unit is refused and flagged" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a time grid registered off its unit is refused and flagged" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
