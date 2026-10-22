#!/usr/bin/env bash
# uninstall_drops_by_oid.sh <container> <db> [uninstall.sql]
#
# Run tests/348_uninstall_drops_by_oid_test.sql against an ARBITRARY copy of pgpm_core/uninstall.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1357): uninstall.sql
# dropped the objects pgpm's records name (regrain's delta and capture function, from_hypertable's scratch copy,
# delta and function) by names read before a wait, regrain_cancel's, an earlier drop's or the DROP's own for its
# lock, so a schema renamed aside with a namesake schema and table committed during the wait made it drop the
# operator's table, rows and all, and leave pgpm's. pgpm._uninstall_drop, which the script creates in pgpm, drops
# by oid and checks the oid is gone. The file is the acceptance test; it drives its waits with dblink holder
# sessions. This wrapper exists so the mutations have a guard the discriminate track can run against the mutant,
# in the shape of bench/uninstall_scratch_by_record.sh.
#
# FIVE mutations are required to fail against it (bench/mutations/mutate.py), all of uninstall.sql:
#   uninstall_regrain_delta_dropped_by_name    -- the reported site: the regrain delta by the name read first (S1, S2)
#   uninstall_drop_lock_not_followed           -- a table dropped by the name its oid has at the statement, with no
#                                                 lock by oid first: the uninstall refuses where it must follow (S1)
#   uninstall_drop_effect_unchecked            -- no check that the oid is gone: a DROP FUNCTION that waited for the
#                                                 function's lock drops a namesake (S6)
#   uninstall_scratch_copy_dropped_by_name     -- the record sweep's copy by its name before the wait (S3)
#   uninstall_comment_sweep_delta_by_loop_name -- the comment sweep's delta by the loop's names (S4)
#
# The third argument is the UNINSTALL script under test, not an install: pgpm_core/install.sql is what gets
# installed, always. It is a path inside the container, which the file reads with psql's \ir. Runs on the plain
# core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the container,
# for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; UNINSTALL="${3:-/repo/pgpm_core/uninstall.sql}"
INSTALL=/repo/pgpm_core/install.sql
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/348_uninstall_drops_by_oid_test.sql}"
LABEL="uninstall drops what pgpm recorded by its oid"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A module that will not install is NOT a pass, and neither is a mutant path that is not there (\ir would fail,
# the file would die early, and the guard would read as having caught the defect). Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: the module under test installed" "$INSTALL"
  fail=1
fi
if ! docker exec "$C" test -r "$UNINSTALL"; then
  printf 'FAIL  %-58s %s\n' "fixture: the uninstall script under test exists" "$UNINSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set uninstall=$UNINSTALL $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -30
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
