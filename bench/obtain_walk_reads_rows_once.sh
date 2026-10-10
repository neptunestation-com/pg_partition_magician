#!/usr/bin/env bash
# obtain_walk_reads_rows_once.sh <container> <db> [install.sql]
#
# Run tests/316_obtain_walk_reads_rows_once_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1162):
# obtain's lookahead walk and extend_to's walk asked _cell_attached of every cell, and each ask scanned
# every attached pgpm.part row of the parent through _native_gt, so a tick that built nothing did lookahead
# x partitions comparisons (1,284,804 _native_gt calls at lookahead 800). The walks now read the rows once.
# The file is the acceptance test, counting the calls from pg_stat_xact_user_functions inside one
# transaction; this wrapper exists so the mutations have a guard the discriminate track can run against
# the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   obtain_walk_scans_per_cell            -- obtain asks _cell_attached of every cell, the pre-fix shape.
#                                            Part A.
#   extend_to_walk_scans_per_cell         -- extend_to's walk does the same. Part C.
#   cell_walk_trusts_built_over_dead_row  -- the plausible-but-wrong fix: a cell a built row overlaps is
#                                            skipped though a dead row overlaps it too, so the dead row is
#                                            never forgotten. Parts B and D.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/316_obtain_walk_reads_rows_once_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "obtain's and extend_to's walks read the rows once" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "obtain's and extend_to's walks read the rows once" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
