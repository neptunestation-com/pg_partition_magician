#!/usr/bin/env bash
# regrain_not_valid_check.sh <container> <db> [install.sql]
#
# Run tests/331_regrain_not_valid_check_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1261): a regrain
# copy made LIKE the parent INCLUDING CONSTRAINTS took the parent's NOT VALID CHECK as a validated one, refused
# the row written before it that the parent still serves, and every copy batch of that sub-range failed 23514,
# wedging the run until regrain_cancel. The file is the acceptance test; this wrapper exists so the mutations
# have a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   regrain_copy_validates_not_valid_check     -- _regrain_copy_make leaves the parent's NOT VALID CHECKs on
#                                                 the copy, validated, the pre-fix shape. Parts A, B and C
#                                                 (and D on PostgreSQL 18).
#   regrain_drift_excuses_validated_copy_check -- the plausible-but-wrong drift rule: a copy's validated CHECK
#                                                 under the name of the parent's NOT VALID one is excused, as
#                                                 #633 excuses such a key, so a copy made before the parent's
#                                                 CHECK was re-added NOT VALID refuses a row reconciled into
#                                                 it on every tick. Part C.
#   regrain_drift_compares_not_valid_check     -- the drift check still asks every copy for the parent's NOT
#                                                 VALID CHECK, which no copy is made with, so every copy reads
#                                                 as drift and so does the probe copy, and the run is refused
#                                                 rather than restarted. Parts A, B and C.
#
# Runs on the plain core image (pgtap and pg_prove). Part D (a NOT VALID NOT NULL) needs PostgreSQL 18 and
# skips before it. TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/331_regrain_not_valid_check_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a regrain copies the rows a NOT VALID CHECK tolerates" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a regrain copies the rows a NOT VALID CHECK tolerates" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
