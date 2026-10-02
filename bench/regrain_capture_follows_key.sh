#!/usr/bin/env bash
# regrain_capture_follows_key.sh <container> <db> [install.sql]
#
# Run tests/217_regrain_capture_follows_key_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #817):
# the capture apparatus (the delta's columns, the trigger function's field names) was minted from the
# reused key at prepare and never followed it, so a key column renamed mid-regrain made every write into
# the regraining range fail 42703 and every reconcile of a change captured before it fail until the swap,
# and one widened made every write of a key past the old type fail 22003. The file is the acceptance test;
# this wrapper exists so the mutations have a guard the discriminate track can run against the mutant, in
# the shape of bench/regrain_survives_parent_ddl.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   regrain_capture_drift_ignored   -- the capture is never compared with the parent's key, the pre-fix
#                                      shape. Parts A and B.
#   regrain_restart_keeps_capture   -- the drift is seen and the run restarts, but the restart keeps the
#                                      capture minted at prepare, so it restarts on every tick and never
#                                      swaps. Parts A and B.
#
# Runs on the plain core image (pgtap and pg_prove; the test needs neither pg_cron nor dblink).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/217_regrain_capture_follows_key_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a regrain's change capture follows its key" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a regrain's change capture follows its key" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
