#!/usr/bin/env bash
# retain_loop_per_child_isolation.sh <container> <db> [install.sql]
#
# Run tests/263_retain_loop_per_child_isolation_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #907):
# retain()'s loop over retire() had no exception block of its own, so when retire()'s write-block install
# timed out on ONE aged partition (a second session holding SHARE UPDATE EXCLUSIVE on it, as a VACUUM or
# ANALYZE does) the raise unwound the whole retain step into maintain()'s one handler and rolled back the
# DROPs retire() had already completed for the other aged partitions of the same call. The file holds the
# lock in a real second session (dblink) and gives every observation its own statement; it is the
# acceptance test, and this wrapper exists so the mutations have a guard the discriminate track can run
# against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   retain_loop_no_child_isolation  -- the per-partition exception block removed, the pre-fix shape. The
#                                      neighbours' drops, the rows left, and the per-partition skip row.
#   retain_loop_silent_skip         -- the plausible-but-wrong fix: the block kept, the skip_retain row
#                                      dropped, so the deferral is invisible. The per-partition skip row.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/263_retain_loop_per_child_isolation_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "one partition's retire raise defers that partition alone" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "one partition's retire raise defers that partition alone" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
