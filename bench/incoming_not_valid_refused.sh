#!/usr/bin/env bash
# incoming_not_valid_refused.sh <container> <db> [install.sql]
#
# Run tests/259_incoming_not_valid_key_refused_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #902):
# _transmute_incoming_gate preserved an incoming foreign key the operator had left NOT VALID, the cutover
# recorded it, restore_incoming_fks re-added it NOT VALID, and maintain's validate_incoming_fks VALIDATEd
# it: a clean key was silently promoted, and one over tolerated orphans failed and was retried every five
# minutes for good (fail_validate_incoming_fk). The file is the acceptance test; this wrapper exists so the
# mutation has a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   transmute_incoming_gate_accepts_not_valid -- the gate does not look at convalidated, the pre-fix shape.
#                                                Parts A (preflight, 'preserve'), B ('drop') and C (the
#                                                cutover's second asking, under its lock).
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/259_incoming_not_valid_key_refused_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a NOT VALID incoming key is refused, never validated by pgpm" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a NOT VALID incoming key is refused, never validated by pgpm" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
