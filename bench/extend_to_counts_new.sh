#!/usr/bin/env bash
# extend_to_counts_new.sh <container> <db> [install.sql]
#
# Run tests/403_extend_to_counts_new_partitions_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1242):
# extend_to's p_max dry count was the grid steps from the frontier's floor to the target's, so the cells obtain's
# lookahead had already built above max(id) (or now()) counted as new, and a call needing two partitions was
# refused under p_max => 3. The count now walks the walk's own cells over its one read of the attached rows.
# The lock budget's projection (#591) counts the partitions left to build for the same reason. The file is the
# acceptance test; this wrapper gives the mutations a guard the discriminate track can run, in the shape of
# bench/frontier_read_windows.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   extend_to_counts_grid_steps       -- every cell the dry count walks is counted, built or not: the pre-fix
#                                        count. Parts A and B.
#   extend_to_projects_walked_cells   -- the lock budget projected over the cells left in the walk, the
#                                        pre-fix shape kept beside the new count: behind a lookahead it comes
#                                        up short by the cells walked before the first build. Part C.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/403_extend_to_counts_new_partitions_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "extend_to counts the partitions it would build" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "extend_to counts the partitions it would build" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
