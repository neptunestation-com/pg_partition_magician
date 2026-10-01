#!/usr/bin/env bash
# untransmute_publication_membership.sh <container> <db> [install.sql]
#
# Run tests/206_untransmute_publication_membership_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so that bench/discriminate.sh can show the file catches the defects its mutations
# put back (issue #780): untransmute dropped the parent's publication memberships with the parent and
# handed back the monolith's conversion-time ones, so a publication the managed table joined since stopped
# publishing it at the reverse and one it left published it again. The file is the acceptance test; this
# wrapper exists so the mutations have a guard the discriminate track can run against the mutant, in the
# shape of bench/untransmute_acl_capture_under_lock.sh, whose tests/203 covers the grants in the same window.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   untransmute_publication_not_restored      -- the memberships are captured and never applied, the
#                                                pre-fix outcome. Parts A and B.
#   untransmute_publication_capture_before_lock -- the capture moves above the explicit ACCESS EXCLUSIVE,
#                                                so a membership changed while the lock was queued is
#                                                lost. Part B.
#   untransmute_publication_always_readd      -- every membership is dropped and re-added, matching or
#                                                not, so an unchanged reverse needs every publication's
#                                                owner. Parts A and A2.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). The file opens dblink sessions of its own,
# so the database's backends are terminated before each drop. TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/206_untransmute_publication_membership_test.sql}"
WHAT="untransmute hands back the parent's publication memberships"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$WHAT" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$WHAT" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
