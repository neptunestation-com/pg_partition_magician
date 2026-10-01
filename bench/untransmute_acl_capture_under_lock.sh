#!/usr/bin/env bash
# untransmute_acl_capture_under_lock.sh <container> <db> [install.sql]
#
# Run tests/203_untransmute_acl_capture_under_lock_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so that bench/discriminate.sh can show the file catches the defect its mutation
# puts back: untransmute captures the parent's privileges and row security (#667) above its explicit
# ACCESS EXCLUSIVE, so a GRANT committed while that lock was queued is lost with the parent (review pass 5
# seed S8). The file is the acceptance test; this wrapper exists so the mutation has a guard the
# discriminate track can run against the mutant, in the shape of bench/reread_under_lock_tap.sh, which
# runs tests/158 (the trigger capture in the same window) the same way.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). The file opens dblink sessions of its own,
# so the database's backends are terminated before each drop. TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/203_untransmute_acl_capture_under_lock_test.sql}"
WHAT="a GRANT made while untransmute queued for its lock is kept"
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
