#!/usr/bin/env bash
# regrain_calendar_clamped_name.sh <container> <db> [install.sql]
#
# Run tests/260_regrain_calendar_clamped_name_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back:
# _regrain_sub_name left every calendar target step (month, year) to _part_name, so a sub-range clamped to a
# child's off-lattice lo took the label of the lattice cell it sits in at the step's own granularity. A
# '1 year' lattice starts in the month the anchor reads in partition_tz (December west of UTC with the
# default anchor, or a non-January p_anchor), so a monthly New York monolith starting 2023-03-01 clamped
# [2023-03-01, 2023-12-01) under 2023, the name of the lattice cell after it, and regrain_history(.., '1 year')
# refused its own first copy as a relation it did not create (#904).
# The file is the acceptance test; this wrapper exists so the mutation (regrain_calendar_name_by_lattice)
# has a guard the discriminate track can run against the mutant, in the shape of
# bench/regrain_clamped_subrange_names.sh.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo. The file builds its own fixtures,
# so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/260_regrain_calendar_clamped_name_test.sql}"
WHAT="a clamped calendar regrain sub-range is named by its own start"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$WHAT" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$WHAT" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
