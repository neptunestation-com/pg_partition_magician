#!/usr/bin/env bash
# build_refuses_dropped_detach_name.sh <container> <db> [install.sql]
#
# Run tests/396_build_refuses_dropped_detach_name_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1487): a table
# dropped with a plain DROP TABLE while its retirement's detach was armed in a pgpm_detach job, then re-created
# under the same name and grid without forget_missing(), got a partition of the recorded name, and the job's next
# run detached it, rows and all, unlogged. The file is the acceptance test; this wrapper exists so the mutations
# have a guard the discriminate track can run against the mutant, in the shape of
# bench/forget_missing_disarms_detach.sh.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site that makes or names a
# partition:
#   transmute_builds_dropped_detach_name       -- transmute's phase-1 refusal removed. Part A.
#   obtain_builds_dropped_detach_name          -- _obtain_name's two checks removed (obtain, extend_to). Part B.
#   regrain_renames_to_dropped_detach_name     -- regrain_step's refusal before the source's rename removed. Part C.
#   regrain_copies_to_dropped_detach_name      -- regrain_step's refusal before a fine child's create removed. Part D.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's catalog).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted somewhere other
# than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/396_build_refuses_dropped_detach_name_test.sql}"
LABEL="no partition takes a name a dropped table's retirement records"
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
