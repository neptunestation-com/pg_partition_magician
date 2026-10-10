#!/usr/bin/env bash
# regrain_clamped_subrange_names.sh <container> <db> [install.sql]
#
# Run tests/209_regrain_clamped_subrange_names_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back:
# regrain_step named a sub-range clamped to a child's off-lattice lo at the target step's own granularity,
# so a day cell took the UTC date of its start, the label of its lattice neighbour too. On a monthly New
# York grid regrained to a day, February's clamped first cell rendered the name January's last cell held and
# every regrain of February was refused; a Los Angeles monolith's clamped first hour took the next cell's
# name and auto-regrain logged skip_regrain on every tick with the capture trigger left on (#783).
# The file is the acceptance test; this wrapper exists so the mutation (regrain_clamped_name_by_floor) has
# a guard the discriminate track can run against the mutant, in the shape of bench/time_literal_era.sh.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo. The file builds its own fixtures,
# so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/209_regrain_clamped_subrange_names_test.sql}"
WHAT="a clamped regrain sub-range is named by its own start"
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
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
