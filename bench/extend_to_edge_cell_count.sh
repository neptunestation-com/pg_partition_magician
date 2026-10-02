#!/usr/bin/env bash
# extend_to_edge_cell_count.sh <container> <db> [install.sql]
#
# Run tests/230_extend_to_edge_cell_count_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #836):
# extend_to's p_max dry count counted grid steps past the frontier's floor while the walk also built the
# frontier's own cell when it was missing, so extend_to(..., p_max => 1) could create two partitions. The
# file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track can
# run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   extend_to_edge_uncounted        -- the edge's cell is never counted, the pre-fix shape. Part A.
#   extend_to_edge_always_counted   -- the over-correction: the edge's cell is counted even when it is
#                                      built, so a call one step past a built edge is refused. Part C.
#
# Part A sleeps 1.2 s so that now() leaves the only cell a 1-second grid with no lookahead has built.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/230_extend_to_edge_cell_count_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "extend_to's p_max counts the edge's own missing cell" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "extend_to's p_max counts the edge's own missing cell" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
