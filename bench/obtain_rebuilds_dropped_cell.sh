#!/usr/bin/env bash
# obtain_rebuilds_dropped_cell.sh <container> <db> [install.sql]
#
# Run tests/264_obtain_rebuilds_dropped_cell_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #908):
# obtain and extend_to took an attached pgpm.part row for a built cell without asking whether its partition
# still existed, so a forward cell dropped by hand was never rebuilt and nothing was logged, while status()
# still counted it. The file is the acceptance test; this wrapper exists so the mutations have a guard the
# discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   obtain_trusts_dropped_cell      -- the dead row is trusted, the pre-fix shape. Parts A and B.
#   obtain_rebuild_keeps_stale_row  -- the plausible-but-wrong fix: the cell is rebuilt but the dead row is
#                                      never forgotten, so it keeps the dropped partition's oid. Parts A, B.
#   status_counts_dropped_cell      -- status() counts the dead row and reports its hi as the ceiling.
#                                      Part A.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/264_obtain_rebuilds_dropped_cell_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "obtain and extend_to rebuild a hand-dropped forward cell" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "obtain and extend_to rebuild a hand-dropped forward cell" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
