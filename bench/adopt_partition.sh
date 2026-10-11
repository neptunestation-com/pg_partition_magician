#!/usr/bin/env bash
# adopt_partition.sh <container> <db> [install.sql]
#
# Run tests/303_adopt_partition_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1082): the
# documented repair for an identity wedge (a partition restored from a dump under its own name, refused on
# identity) deleted the stale pgpm.part row, which left the restored relation attached and recorded by
# nothing, so its rows outlived retention for good and status() stopped counting it. pgpm.adopt_partition is
# the repair now: it records the attached relation by its oid. The file is the acceptance test; this wrapper
# exists so the mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/forget_missing_disarms_detach.sh.
#
# FOUR mutations are required to fail against it (bench/mutations/mutate.py):
#   adopt_partition_keeps_stale_oid      -- the stale row is not re-anchored: the wedge stands and the rows
#                                           stay. Part A.
#   adopt_partition_records_nothing      -- a partition with no row is not recorded afresh, the state the old
#                                           delete repair left. Part B (the issue's own path) and part D.
#   adopt_partition_credits_old_coverage -- coverage the old relation earned under the name is credited to
#                                           the adopted one. Part A's ledger identity.
#   adopt_partition_unlocked             -- the partition is not locked while it is judged, so a second
#                                           session's DETACH lands before the row commits. Part E.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/303_adopt_partition_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "adopt_partition() records an untracked attached partition" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "adopt_partition() records an untracked attached partition" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
