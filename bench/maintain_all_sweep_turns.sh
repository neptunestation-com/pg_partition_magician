#!/usr/bin/env bash
# Run tests/147_maintain_all_sweep_turns_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant (issue #579).
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its contract is about ORDER under a shared statement_timeout, and
# its central assertions ("the parent cut short last tick led this one") are equally satisfied by a run
# in which nothing was ever cut short, or in which the tail parent had nothing to do. The file pins that
# with liveness witnesses of its own (each archive function counts its calls in a sequence, which a
# cancellation does not roll back, so "entered, then cut short" is observed rather than inferred), but
# nothing re-checks that those witnesses would still be met with the defect back and the fix assertions
# then FAIL. Pointing the same file at a mutant is what checks that, every CI run, instead of once by hand.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   maintain_all_fixed_sweep_order   -- maintain_all's loop back to `order by parent_table`, which is the
#                                       pre-#579 sweep exactly: the parent a backlog starves is starved on
#                                       every tick
#   maintain_all_no_first_turn_stamp -- turns stamped only on completion, so a parent whose own tick
#                                       overruns the timeout is never stamped and leads, and is cancelled
#                                       in, every sweep
#
# Usage: maintain_all_sweep_turns.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). About 8 s: five
# sweeps, each bounded by the file's 1.5 s statement_timeout.
# SWEEP_TURNS_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${SWEEP_TURNS_TEST_FILE:-/repo/tests/147_maintain_all_sweep_turns_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a sweep leads with the parent whose turn is oldest" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a sweep leads with the parent whose turn is oldest" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
