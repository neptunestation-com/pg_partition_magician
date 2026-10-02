#!/usr/bin/env bash
# Run tests/212_obtain_lock_budget_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant (issue #786).
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its subject is a bound, "one obtain call holds no more than half the
# shared lock table", and a bound is satisfied by a call that built nothing at all, so the file pins its
# setup with liveness witnesses of its own (the tick really ran and stopped short of its lookahead; the
# direct call really built cells, each holding a slot, and used most of its half rather than a token
# few), and this wrapper re-checks, every CI run, that the file fails when the bound it guards is removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   obtain_no_lock_budget  -- obtain's lock-budget stop never fires, the pre-#786 shape exactly: the
#                             lookahead of one cell per slot of the whole table walks on until the lock
#                             table runs out (53200 `out of shared memory`), so the tick logs skip_obtain
#                             and builds nothing, and the direct call dies where it was promised to stop
#
# Usage: obtain_lock_budget.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). The file computes its
# budget from the server's own settings, so it needs no particular max_locks_per_transaction. Against the
# mutant it fills the shared lock table of the server it runs on for the moment each call takes to die, as
# extend_to_lock_budget.sh's does, so it must not share that server with work running concurrently.
# LOCK_BUDGET_TEST_FILE overrides the test file's path inside the container, for running from a worktree
# that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${LOCK_BUDGET_TEST_FILE:-/repo/tests/212_obtain_lock_budget_test.sql}"
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
  # pg_prove's exit status covers a file that dies early (a bad plan). What it cannot tell apart from a
  # real failure is a run that never reached the database at all, and discriminate.sh reads a non-zero
  # exit as "the guard caught the defect", so the count of assertions reached is asserted separately.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "obtain stops at half the lock table, not 53200" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "obtain stops at half the lock table, not 53200" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
