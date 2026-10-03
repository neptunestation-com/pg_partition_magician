#!/usr/bin/env bash
# regrain_capture_source_grantees.sh <container> <db> [install.sql]
#
# Run tests/236_regrain_capture_source_grantees_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #843):
# _regrain_capture_grant granted INSERT on the delta to the grantees of DML on the PARENT only, while the
# capture trigger runs as the writer, so a role granted UPDATE or DELETE directly on the regraining
# partition (a write PostgreSQL permits with no grant on the parent) got 42501 on the delta on every write
# into the source for the life of the regrain. The file is the acceptance test; this wrapper exists so the
# mutation has a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_capture_grant_parent_only  -- the grant reads the parent's ACL alone again, the pre-fix shape.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/236_regrain_capture_source_grantees_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a partition's own writers can write it mid-regrain" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a partition's own writers can write it mid-regrain" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
