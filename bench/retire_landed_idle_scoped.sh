#!/usr/bin/env bash
# retire_landed_idle_scoped.sh <container> <db> [install.sql]
#
# Run tests/400_retire_landed_idle_scoped_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1498): retire()'s idle
# of a landed detach reset every pgpm_detach job the caller sees, and a superuser sees every role's, so a superuser's
# tick completing one retirement clobbered another role's job holding a different retirement's pending detach. The
# file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run
# against the mutant, in the shape of bench/retire_completion_vouches_detach.sh.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   retire_landed_idle_unscoped            -- every visible job reset whoever dispatched it. Part B.
#   retire_landed_idle_no_null_fallback    -- only the recorded role's job, none when retiring_by is null. Parts A, C.
#   retire_landed_idle_superuser_own_job   -- a superuser's record scoped to its own job, though its dispatch armed
#                                             every role's. Part A.
#   retire_landed_idle_clobbers_dispatch   -- the job holding another mark's pending detach reset too. Part A.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's catalog and its
# row security). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/400_retire_landed_idle_scoped_test.sql}"
LABEL="retire() idles only the jobs that may hold a landed detach"
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
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
