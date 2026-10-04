#!/usr/bin/env bash
# crossing_keys_control_collation.sh <container> <db> [install.sql]
#
# Run tests/253_crossing_keys_control_collation_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #900,
# F4-07): _crossing_keys compared the referencing column against a text_time cell's bounds under the
# REFERENCING column's collation, so for a mixed-case KSUID cell whose bounds run from an uppercase to a
# lowercase digit the en_US interval [lo, hi) was empty: no crossing key was found, the declared ON DELETE
# CASCADE never ran and the dispatched detach was refused on every run. The file is the acceptance test;
# this wrapper exists so the mutation has a guard the discriminate track can run against the mutant, in the
# shape of bench/crossing_keys_datestyle.sh.
#
# The mutation required to fail against it (bench/mutations/mutate.py):
#   crossing_keys_referencing_collation  -- the range compared under the referencing column's collation
#                                           again, the pre-fix shape.
#
# The test waits for a one-second KSUID cell whose bounds cross from uppercase to lowercase to age past the
# retention horizon: about 3 to 12 s, at most 63.
#
# Runs on the plain core image (pgtap, pg_prove and the en_US.utf8 locale; the test brings its own stand-in
# for pg_cron's catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a
# worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/253_crossing_keys_control_collation_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the crossing step finds its keys under any referencing collation" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the crossing step finds its keys under any referencing collation" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
