#!/usr/bin/env bash
# crossing_keys_datestyle.sh <container> <db> [install.sql]
#
# Run tests/231_crossing_keys_datestyle_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #814,
# F4-01): _crossing_keys rendered a timestamptz referencing key with a bare ::text, so under DateStyle SQL
# in Asia/Kolkata ('IST', which PostgreSQL before 18 parses as Israel) retire()'s crossing DELETE matched
# nothing, the FK's declared ON DELETE was never applied and the dispatched detach could never succeed. The
# file is the acceptance test; this wrapper exists so the mutation has a guard the discriminate track can
# run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# The mutation required to fail against it (bench/mutations/mutate.py):
#   crossing_keys_bare_text  -- the key read back with a bare ::text again, the pre-fix shape.
#
# The defect reproduces on PostgreSQL 15 to 17 only (18 resolves an abbreviation in the session's own zone
# first), so this guard discriminates on the perf and discriminate tracks' PostgreSQL 17. The test sleeps
# 2.2 s so that its 1-second monolith ages past the retention horizon.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's catalog). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/231_crossing_keys_datestyle_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the crossing DELETE matches its keys under any DateStyle" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the crossing DELETE matches its keys under any DateStyle" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
