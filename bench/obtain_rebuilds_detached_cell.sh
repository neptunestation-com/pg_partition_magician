#!/usr/bin/env bash
# obtain_rebuilds_detached_cell.sh <container> <db> [install.sql]
#
# Run tests/280_obtain_rebuilds_detached_cell_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #956): a
# forward cell DETACHed by hand kept its relation, and obtain and extend_to judged a cell built when the
# relation its pgpm.part row anchors existed, so the cell was never rebuilt and nothing was logged, while
# every write into its range was refused. The file is the acceptance test; this wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/obtain_rebuilds_dropped_cell.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   obtain_trusts_detached_cell      -- _part_built asks whether the relation exists, not whether it is a
#                                       partition of the table: the pre-fix shape. Parts A and B.
#   detached_cell_name_refused       -- the plausible-but-wrong fix: the detached row is forgotten, but the
#                                       table it leaves holding the cell's plain name is read as a
#                                       stranger's, so the cell is logged fail_obtain_name and left unbuilt.
#                                       Parts A and B.
#   retiring_cell_forgotten          -- the over-correction: a partition retire() is detaching concurrently
#                                       (retiring_at set) is read as hand-detached, so its row is forgotten
#                                       and the range rebuilt under a retirement in flight. Part C.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/280_obtain_rebuilds_detached_cell_test.sql}"
LABEL="obtain and extend_to rebuild a hand-detached forward cell"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
