#!/usr/bin/env bash
# adopt_partition_isolation.sh <container> <db> [install.sql]
#
# Run tests/332_adopt_partition_isolation_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1262):
# adopt_partition judged the partition (attached and not pending, its name, its bounds) through the caller's
# snapshot after its SHARE UPDATE EXCLUSIVE lock, and under REPEATABLE READ or SERIALIZABLE that snapshot is the
# transaction's first, so a DETACH another session committed before the call was read as still attached and a
# standalone table was recorded in pgpm.part as a partition (a RENAME, under its old name). It refuses any
# isolation level stricter than READ COMMITTED now, so every read after the lock has a snapshot taken after it,
# and asks the lock manager, under the lock, whether the lock it took is on the partition's oid.
# The file is the acceptance test; this wrapper exists so the mutation has a guard the discriminate track can
# run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   adopt_partition_strict_isolation_admitted -- the refusal gone, the pre-fix shape: parts A (a detached table
#                                                recorded), B (a renamed partition recorded under its old name)
#                                                and C (SERIALIZABLE admitted) catch it, and part D's remedy then
#                                                meets the rows the admitted calls recorded.
#   adopt_partition_lock_unwitnessed         -- the lock taken by name with no witness that it is on p_child: a
#                                                rename and a squatter on the old name (part E), or the
#                                                partition's schema swapped away and back while the lock waits
#                                                (part F), leave the lock on another relation, and the partition
#                                                is recorded with no lock on it. Parts E and F catch it.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/332_adopt_partition_isolation_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "adopt_partition() refuses a snapshot older than its lock" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "adopt_partition() refuses a snapshot older than its lock" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
