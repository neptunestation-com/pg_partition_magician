#!/usr/bin/env bash
# Run tests/172_regrain_copy_name_clash_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its central assertions are negatives ("none of the new table's rows
# went into the other table", "nothing was copied into the squatter", "none is left behind under the
# name"), and a negative is equally satisfied by a run in which the copy never reached the clashing
# sub-range, or in which no relation held the name at all. The file pins its setup with liveness
# witnesses of its own (the cursor sits at the clashing sub-range, the rendered name is exactly the
# other table's partition, the recorded copy really was renamed aside with its two rows, the dropped
# copy really was recreated), but nothing re-checks that those witnesses would still be met with the
# defect back and the fix assertions then FAIL. Pointing the same file at a mutant is what checks that,
# every CI run, instead of once by hand.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   regrain_copy_into_named_relation -- regrain_step copies into whatever relation bears the sub-range's
#                                       name again: pre-#631 exactly, so another table's partition
#                                       gains this table's rows
#   regrain_copy_dropped_by_name     -- regrain_cancel drops copies by their recorded name again, so a
#                                       copy renamed aside survives and a squatter is dropped instead
#   regrain_recreated_copy_oid_stale -- a copy recreated under its row keeps the dead oid, so the cancel
#                                       drops nothing and the recreated copy is left behind
#
# Usage: regrain_copy_name_clash.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). RCN_TEST_FILE
# overrides the test file's path inside the container, for running from a worktree that is mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${RCN_TEST_FILE:-/repo/tests/172_regrain_copy_name_clash_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a regrain copies only into relations it created" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a regrain copies only into relations it created" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
