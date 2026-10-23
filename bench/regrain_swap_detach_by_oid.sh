#!/usr/bin/env bash
# regrain_swap_detach_by_oid.sh <container> <db> [install.sql]
#
# Run tests/349_regrain_swap_detach_by_oid_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1362): regrain_step's
# swap ran `alter table <parent> detach partition <source>` with both names rendered before the DETACH waited for
# ACCESS EXCLUSIVE on the parent behind a reader, and nothing locked by oid first. A schema renamed aside during the
# wait, with a namesake schema holding a namesake partitioned table and a namesake partition committed in its place,
# was what the DETACH reached: the stranger's partition left the stranger's table while the swap went on by oid and
# reported success. The fix locks the parent and the source by oid (pgpm._lock_oid_or_raise) before the DETACH and
# renders their names under those locks. The file is the acceptance test; this wrapper exists so the mutation has a
# guard the discriminate track can run against the mutant, in the shape of bench/retire_locks_by_oid.sh.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   regrain_swap_detach_unlocked -- the two locks by oid before the DETACH are gone, the pre-fix shape: the DETACH
#                                   waits for the parent by name and detaches the stranger's partition (part A), or
#                                   waits for the source by name and fails on the stranger's (part C).
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/349_regrain_swap_detach_by_oid_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the regrain swap detaches the source it identified" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the regrain swap detaches the source it identified" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
