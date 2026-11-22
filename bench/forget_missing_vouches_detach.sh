#!/usr/bin/env bash
# forget_missing_vouches_detach.sh <container> <db> [install.sql]
#
# Run tests/395_forget_missing_vouches_detach_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issues #1488 and #1461):
# forget_missing()'s #893 disarm read ONE unordered row of cron.job, so a superuser whose first row was another
# role's idle pgpm_detach job left the administrator's job armed with the forgotten retirement's detach (#1488), and
# a non-superuser, shown only its own job by pg_cron's row security, left it armed the same way (#1461). The job's
# next run then detached a re-created namesake's partition. The file is the acceptance test; this wrapper exists so
# the mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/forget_missing_disarms_detach.sh.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   forget_missing_reads_one_detach_job        -- the pre-#1488 read of one row. Part A.
#   forget_missing_unvouched_disarm            -- the #1461 refusal removed. Parts B and D.
#   forget_missing_refuses_retiring_role       -- the over-wide fix: the role whose own job holds the detach
#                                                 refused too. Part C.
#   dropped_retirements_count_undispatched     -- a mark never dispatched read as one a job may hold. Part E.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's catalog and its
# row security). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/395_forget_missing_vouches_detach_test.sql}"
LABEL="forget_missing() disarms every job, or refuses what it cannot vouch for"
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
