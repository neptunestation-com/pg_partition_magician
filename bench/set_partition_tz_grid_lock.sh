#!/usr/bin/env bash
# set_partition_tz_grid_lock.sh <container> <db> [install.sql]
#
# Run tests/195_set_partition_tz_grid_lock_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can show the file catches the defect of issue #725 its mutations put back:
# set_partition_tz judged committed pgpm.part and shared no lock with obtain() or extend_to(), so a zone
# change accepted beside an uncommitted extension (or read around by one) left the grid's top off the new
# zone's lattice and a permanent one-hour hole past it.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its refusals in sections (A) and (C) are exactly what a setter that
# simply ran after the extension had committed returns, so they prove nothing without the witnesses that
# the second session was seen WAITING while the first was still uncommitted; pointing the file at mutants
# with each lock removed is what checks those witnesses still let it fail, every CI run.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   set_partition_tz_config_unlocked -- the setter reads the config row unlocked: all four sections catch it
#   extend_to_config_unlocked        -- extend_to reads it unlocked: sections (A) and (B) catch it
#   obtain_config_unlocked           -- obtain reads it unlocked: sections (C) and (D) catch it
#
# Usage: set_partition_tz_grid_lock.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/195_set_partition_tz_grid_lock_test.sql}"
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
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "set_partition_tz serialises against obtain and extend_to" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "set_partition_tz serialises against obtain and extend_to" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
