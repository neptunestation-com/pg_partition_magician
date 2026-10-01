#!/usr/bin/env bash
# Run tests/183_regrain_reconcile_identity_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant (issue #723).
#
# The file is plain pgTAP and the default matrix already runs it, so on correct code this adds nothing.
# What it adds is the standing proof that the file DISCRIMINATES. Its central assertions are negatives
# ("the unrelated table is untouched", "the recorded copy is untouched", "the delta keeps every captured
# change"), and each is equally satisfied by a run in which the reconcile never had a key to apply or no
# relation held the copy's name at all. The file pins its setup with liveness witnesses (the copy really
# is the renamed table by oid, the stranger really holds its two rows, the writes really are captured
# and eligible, and with the name given back the same tick does reconcile), and pointing it at a mutant
# checks, every CI run, that the assertions then FAIL.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_reconcile_into_named_relation -- _regrain_reconcile writes into whatever relation bears the
#                                            fine child's recorded name again: pre-#723 exactly
#
# Usage: regrain_reconcile_identity.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). RRI_TEST_FILE
# overrides the test file's path inside the container, for running from a worktree that is mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${RRI_TEST_FILE:-/repo/tests/183_regrain_reconcile_identity_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a reconcile writes only into the copy pgpm.part recorded" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a reconcile writes only into the copy pgpm.part recorded" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
