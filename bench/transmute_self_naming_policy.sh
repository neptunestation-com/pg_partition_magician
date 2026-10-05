#!/usr/bin/env bash
# transmute_self_naming_policy.sh <container> <db> [install.sql]
#
# Run tests/250_transmute_self_naming_policy_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #897): the
# cutover replayed the table's policies onto the staging parent <rel>_pgpm_new BEFORE the renames, and
# pg_get_expr qualifies a reference to the outer row with the table's own name, so a correlated-subquery
# policy (the common tenant-membership shape) failed CREATE POLICY raw in phase 3, after phases 1 and 2 had
# committed the write-rejecting bound and the claim, on every retry; and a subquery over the table itself
# bound to the original oid, which the rename hands to the monolith. The file is the acceptance test (the
# finder's reproduction, plus the unqualified outer column and the self-referencing subquery, asserted by
# identity); this wrapper exists so the mutation has a guard the discriminate track can run against the
# mutant, in the shape of bench/transmute_oid_bound_dependants.sh.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   transmute_policies_on_staging -- the pre-#897 shape: the policy loop executes onto the staging parent
#                                    where it used to, before the renames, and the post-rename replay is
#                                    gone. Part A of the file.
#
# Runs on the plain core image (pgtap, dblink and pg_prove; the test needs no pg_cron). TAP_GUARD_TEST_FILE
# overrides the test file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/250_transmute_self_naming_policy_test.sql}"
WHAT="a policy that names its own table is carried onto the parent"
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
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
