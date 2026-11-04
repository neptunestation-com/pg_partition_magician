#!/usr/bin/env bash
# retain_recall_late_detach.sh <container> <db> [install.sql]
#
# Run tests/366_retain_recall_late_detach_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1438): _retain_recall's
# re-attach cleared the retirement marker in the transaction that idled the pgpm_detach job, so a run pg_cron had
# started before that commit, still carrying the armed DETACH ... CONCURRENTLY and queued on the parent behind the
# ATTACH, took the partition out again and left a row that read as attached with nothing to take back. The file is
# the acceptance test; this wrapper exists so the mutation has a guard the discriminate track can run against the
# mutant, in the shape of bench/retain_recall_renamed_detached.sh.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   recall_reattach_clears_mark   -- the re-attach clears the marker in its own transaction again.
#
# Runs on the plain core image (pgtap, dblink and pg_prove; the second sessions are dblink connections ordered by
# the parent's lock, polled server-side, and the test brings its own stand-in for pg_cron's catalog).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted somewhere other
# than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/366_retain_recall_late_detach_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a late detach run is taken back by the next tick" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a late detach run is taken back by the next tick" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
