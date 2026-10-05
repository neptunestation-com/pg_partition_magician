#!/usr/bin/env bash
# regrain_capture_owner_grant.sh <container> <db> [install.sql]
#
# Run tests/262_regrain_capture_owner_grant_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #906):
# _regrain_capture_grant granted INSERT on the delta to the roles an ACL of the parent or the source lists,
# never to their OWNERS, whose rights are implicit, while the capture trigger runs as the writer. After
# ALTER TABLE <parent> OWNER TO (which does not reach the partitions) the old owner still owns the source,
# and every write it made into it failed 42501 on the delta for the life of the regrain; a parent re-owned
# mid-regrain left its new owner the same. The file is the acceptance test; this wrapper exists so the
# mutation has a guard the discriminate track can run against the mutant, in the shape of
# bench/regrain_capture_source_grantees.sh.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_capture_grant_acl_only  -- the grant reads the ACLs alone again, the pre-fix shape.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/262_regrain_capture_owner_grant_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the owners of the source and the parent write it mid-regrain" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the owners of the source and the parent write it mid-regrain" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
