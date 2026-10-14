#!/usr/bin/env bash
# install_keeps_surface_grants.sh <container> <db> [install.sql]
#
# Run tests/336_install_keeps_surface_grants_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1267):
# pgpm._surface_prepare() dropped a declared function whose installed shape CREATE OR REPLACE cannot replace (a
# pre-#343 status() without regrain_to) and the file recreated it at its creator's default privileges, so an
# upgrade silently undid an operator's REVOKE EXECUTE ... FROM PUBLIC and GRANT EXECUTE to a monitoring role.
# The file is the acceptance test (it re-runs the install with \ir, the file handed to it as the psql variable
# `install`); this wrapper exists so the mutations have a guard the discriminate track can run against the
# mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   surface_prepare_drops_granted   -- the pre-fix shape: _surface_prepare drops a reshaped function whatever its
#                                      grants, so nothing is kept aside to carry them from. Parts A and B.
#   surface_carry_grants_as_owner   -- every kept grant is replayed by the installing role, so one another role
#                                      made through a grant option is recorded under the owner and its grantor
#                                      can no longer revoke it. Part A.
#   surface_prepare_grantor_unchecked -- the up-front refusal of a grant this session cannot replay as its
#                                      grantor is gone, so the function is taken aside and the run goes on.
#                                      Part D.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/336_install_keeps_surface_grants_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-62s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set install=$INSTALL $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -|ERROR' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-62s %s\n' "re-running install.sql keeps the grants on a reshaped function" "$ran ran"
  else printf 'FAIL  %-62s %s\n' "re-running install.sql keeps the grants on a reshaped function" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-62s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
