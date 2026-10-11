#!/usr/bin/env bash
# forget_missing_disarms_detach.sh <container> <db> [install.sql]
#
# Run tests/246_forget_missing_disarms_detach_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #893):
# forget_missing() deleted a dropped parent's retiring pgpm.part row without returning the pgpm_detach job
# to idle, so the retirement's DETACH ... CONCURRENTLY, which names its partition by name, outlived it, and
# pg_cron's next run detached the same-named partition of a table re-created under the same name and grid.
# The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track
# can run against the mutant, in the shape of bench/retire_one_step_disarm.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   forget_missing_keeps_detach_armed  -- the disarm removed, the pre-fix shape. Part A.
#   forget_missing_disarm_any_command  -- the job disarmed whatever it holds, not only a detach of a
#                                         partition the forgotten parent was retiring. Part B.
#   forget_missing_disarm_owned        -- no live-owner check, so the identical command a re-created
#                                         namesake's own retirement armed is clobbered (the #407 rule).
#                                         Part C.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/246_forget_missing_disarms_detach_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "forget_missing() disarms the detach of a retirement it forgets" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "forget_missing() disarms the detach of a retirement it forgets" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
