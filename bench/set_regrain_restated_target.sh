#!/usr/bin/env bash
# set_regrain_restated_target.sh <container> <db> [install.sql]
#
# Run tests/319_set_regrain_restated_target_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1165,
# F3-03): set_regrain's #554 in-flight refusal compared the new target with config.regrain_to as text, so
# with a run in flight at '10' re-stating the target as '010' was refused as a change of target, against
# the reference's promise that re-stating the target already set is accepted. The file is the acceptance
# test; this wrapper exists so the mutations have a guard the discriminate track can run against the
# mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   same_step_id_compared_as_text  -- _same_step compares an id step as text again, the pre-fix shape for
#                                     an id key. Part A.
#   same_step_interval_equality    -- the plausible-but-wrong fix: a time step compared by interval
#                                     equality, which calls '1 month' and '30 days' the same step. Part B.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/319_set_regrain_restated_target_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the in-flight target is the same step in any spelling" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the in-flight target is the same step in any spelling" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
