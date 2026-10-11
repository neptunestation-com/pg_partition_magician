#!/usr/bin/env bash
# transmute_uncarried_shapes_under_lock.sh <container> <db> [install.sql]
#
# Run tests/283_transmute_uncarried_shapes_under_lock_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so that bench/discriminate.sh can show the file catches the defect its mutations put
# back (issue #766, bullet 3): the three shapes #730 refuses up front (a NOT VALID CHECK, a CHECK ... NO
# INHERIT, a GENERATED control column) were asked in the preflight only, so one committed while phases 1 and 2
# had let go of the table failed the cutover raw, after the write-rejecting bound and the claim had committed.
# The cutover now asks again under the ACCESS SHARE it takes before its staging LIKE. The file opens each
# window with an event trigger on phase 1's ADD of the bound and pairs every refusal with witnesses that the
# window opened and its change committed. The file is the acceptance test; this wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/transmute_uncarriable_shapes.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py), one per helper the cutover calls:
#   transmute_uncarried_constraints_preflight_only -- the constraint refusals are not asked in the cutover:
#                                                     (A) dies on the ATTACH's raw error, (B) on the LIKE's
#   transmute_generated_control_preflight_only     -- the generated-column refusal is not asked in the
#                                                     cutover: (C) dies on PARTITION BY RANGE's raw error
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo. The file builds its own
# fixtures, so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/283_transmute_uncarried_shapes_under_lock_test.sql}"
WHAT="a shape committed after the preflight is refused by the cutover"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

# the file's dblink session can outlive a run that died short of its disconnect
q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-62s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-62s %s\n' "$WHAT" "$ran ran"
  else printf 'FAIL  %-62s %s\n' "$WHAT" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-62s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
