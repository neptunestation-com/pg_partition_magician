#!/usr/bin/env bash
# Run tests/156_extend_to_lock_budget_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant (issue #591).
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its subject is a refusal, and a refusal is a negative: "extend_to did
# not build these partitions". A negative is equally satisfied by a call that never had the work in front
# of it, so the file pins its setup with liveness witnesses of its own (an in-budget call really extends,
# by identity; each partition really costs at least one shared lock-table slot, so budget + 1 of them
# cannot fit; the far value really is inside the default p_max, so p_max is not what refuses it), and this
# wrapper re-checks, every CI run, that those witnesses would fail if the refusal they guard were removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   extend_to_no_lock_budget  -- extend_to's lock-budget refusal never fires, the pre-#591 shape exactly:
#                                the far call walks on under its default p_max until the lock table runs
#                                out (53200 `out of shared memory` on a stock server), so the file sees
#                                a server resource error where pgpm's own refusal was promised
#
# Usage: extend_to_lock_budget.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). The file computes its
# budget from the server's own settings, so it needs no particular max_locks_per_transaction; it does
# need max_locks_per_transaction x (max_connections + max_prepared_transactions) / 2 to stay under
# extend_to's default p_max of 10000 partitions, and says so in a LIVENESS line when it does not.
# LOCK_BUDGET_TEST_FILE overrides the test file's path inside the container, for running from a worktree
# that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${LOCK_BUDGET_TEST_FILE:-/repo/tests/156_extend_to_lock_budget_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "extend_to refuses past half the lock table, not 53200" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "extend_to refuses past half the lock table, not 53200" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
