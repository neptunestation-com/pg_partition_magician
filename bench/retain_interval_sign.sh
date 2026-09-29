#!/usr/bin/env bash
# Run tests/131_retain_interval_sign_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant (issue #565).
#
# WHY A WRAPPER EXISTS AT ALL. The test file is plain pgTAP and the default matrix already runs it on every
# version and channel, so on correct code this script adds nothing. What it adds is the standing proof
# that the file DISCRIMINATES. Its headline claims are negatives ("nothing was dropped", "every partition
# is still attached", "every row is still there") and a negative is equally satisfied by a tick that never
# had anything to drop. The file pins its own witnesses (every refused value passes the old interval
# comparison; the value's horizon lands past the hi of the partition taking writes), but nothing re-checks
# that those assertions would FAIL if the field-by-field rule were put back to `>= interval '0'`. Pointing
# the same file at that mutant is what checks it, every CI run.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   retain_interval_normalised_compare -- _retain_nonnegative compares the interval with zero under the
#                                         30-day-month / 360-day-year normalisation, so '-1 year 360 days'
#                                         is accepted and the tick drops the partition taking writes
#
# Usage: retain_interval_sign.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
# RETAIN_INTERVAL_SIGN_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${RETAIN_INTERVAL_SIGN_TEST_FILE:-/repo/tests/131_retain_interval_sign_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for a
# reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # discriminate.sh reads a non-zero exit as "the guard caught the defect", so a harness broken enough to
  # fail against everything would be reported as proving the mutation. The count of assertions that ran
  # is asserted separately, and printed either way, so that case reads as what it is.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "an interval retain is refused if any field is negative" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "an interval retain is refused if any field is negative" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
