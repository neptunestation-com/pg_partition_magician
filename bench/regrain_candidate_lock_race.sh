#!/usr/bin/env bash
# Run tests/148_regrain_candidate_lock_race_deferred_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant (issue #590).
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. The file holds a lock from a SECOND session (dblink) across one
# maintain_all() sweep, and its central claim is a negative ("a lock race on X did not stop the sweep"),
# which is equally satisfied by a sweep in which X never searched for a candidate at all. The file pins
# that with liveness witnesses of its own (the lock was held for the whole sweep, X's skip_regrain row
# carries the lock timeout's text, and once the lock is gone the same tick starts X's regrain), but
# nothing re-checks that those witnesses would still be met with the defect back and the fix assertions
# then FAIL. Pointing the same file at a mutant is what checks that, every CI run, instead of once by hand.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_candidate_outside_handler -- maintain()'s auto-regrain candidate search moved back above the
#                                        regrain step's exception handler, which is pre-#590 behaviour
#                                        exactly: the search's 55P03 raises out of maintain(), and
#                                        maintain_all() stops before the parent ordered after it
#
# Usage: regrain_candidate_lock_race.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has).
# CANDIDATE_LOCK_RACE_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${CANDIDATE_LOCK_RACE_TEST_FILE:-/repo/tests/148_regrain_candidate_lock_race_deferred_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised" -- a file
  # that dies early reports a bad plan and exits non-zero. What it cannot tell us apart from a real
  # failure is a run that never reached the database at all, and in THIS script that distinction
  # matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the defect",
  # so a harness broken enough to fail against everything would be reported as proving the mutation.
  # Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a candidate-search lock race defers the regrain step only" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a candidate-search lock race defers the regrain step only" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
