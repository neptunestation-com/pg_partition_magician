#!/usr/bin/env bash
# retire_one_step_disarm.sh <container> <db> [install.sql]
#
# Run tests/229_retire_one_step_disarm_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #835): retire()
# returned the standing pgpm_detach job to idle only in its referenced branch, so a retirement dispatched
# while an incoming FK existed, and finished by the one-step DROP after the FK was dropped, left the job
# running the dropped partition's detach every tick. The file is the acceptance test; this wrapper exists
# so the mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   retire_one_step_no_disarm       -- the one-step path's disarm removed, the pre-fix shape. Part A.
#   retire_one_step_disarm_any      -- the plausible-but-wrong fix: disarm unconditionally, which clobbers
#                                      another retirement's dispatch (the #407 rule). Part B.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's catalog). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/229_retire_one_step_disarm_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a dispatched retirement's one-step DROP disarms its own detach" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a dispatched retirement's one-step DROP disarms its own detach" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
