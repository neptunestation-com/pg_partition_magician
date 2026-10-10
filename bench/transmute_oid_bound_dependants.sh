#!/usr/bin/env bash
# transmute_oid_bound_dependants.sh <container> <db> [install.sql]
#
# Run tests/205_transmute_oid_bound_dependants_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect each of its mutations puts back: a view,
# a materialized view, a rule, a BEGIN ATOMIC function or another table's policy names the table by its oid,
# the cutover renames that oid into the monolith partition, and each of them silently narrowed to the
# monolith's rows (#779). untransmute meets the same objects over the parent at its DROP.
# One mutation per refusal site, so each is shown to be caught on its own:
#   oid_bound_dependants_unrefused             nothing refused anywhere, the pre-fix shape. Parts A, B, C.
#   oid_bound_dependants_cutover_only          refused only under the cutover's lock, after phases 1 and 2
#                                              committed the bound. Part A.
#   oid_bound_dependants_preflight_only        refused only in the preflight, so one created after it
#                                              follows the rename. Part B.
#   oid_bound_dependants_policy_on_staging     the policies are created on the staging parent before the
#                                              renames again (#897), so the cutover's re-check counts the
#                                              copy of the table's own policy, a false refusal. Part A.
#   untransmute_oid_bound_dependants_unrefused untransmute asks nothing: its DROP fails raw on a view and
#                                              takes a rule on the parent with it silently. Part C.
# The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate
# track can run against the mutant, in the shape of bench/transmute_uncarriable_shapes.sh.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo. The file builds its own
# fixtures, so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/205_transmute_oid_bound_dependants_test.sql}"
WHAT="objects bound to the table's oid are refused, both ways"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$WHAT" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$WHAT" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
