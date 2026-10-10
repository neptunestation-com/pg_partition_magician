#!/usr/bin/env bash
# transmute_claim_owner_under_set_role.sh <container> <db> [install.sql]
#
# Run tests/310_transmute_claim_owner_under_set_role_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so that bench/discriminate.sh can show the file catches the defect its mutations
# put back (issue #771 bullet 3): the transmute claim insert read its owner's backend_start from
# pg_stat_activity, which masks it under SET ROLE for the session's own backend, so the claim recorded
# NULL. The owning session's re-run after a cutover failure was then refused as "already in progress in
# another session" (#509's arm compared NULL with NULL), and a reaper that could see backend_start read the
# still-connected owner as dead and undid its bound. The file is the acceptance test, and its second
# session (one dblink connection, SET ROLE to a role that is not a member of the session user) is the
# second session the contract needs; this wrapper exists so the mutations have a guard the discriminate
# track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   transmute_claim_owner_start_masked  -- the claim insert reads backend_start from pg_stat_activity as
#                                          the current role again, the pre-fix shape. Part B.
#   session_alive_self_masked           -- _session_alive judges the caller's own pid through
#                                          pg_stat_activity like any other, so a session under SET ROLE
#                                          that reused a dead owner's pid reads the claim as its own live
#                                          one and is refused its take-over. Part C.
#   transmute_claim_without_identity    -- the claim is taken even when no identity could be obtained,
#                                          instead of refused up front. Part D.
#
# Runs on the plain core image (pgtap, dblink and pg_prove; the test needs no pg_cron). It creates the
# cluster-wide roles r310 and r310_blind when absent and drops them at the end. TAP_GUARD_TEST_FILE
# overrides the test file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/310_transmute_claim_owner_under_set_role_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a claim under SET ROLE records and judges its owner" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a claim under SET ROLE records and judges its owner" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
