#!/usr/bin/env bash
# set_partition_tz_midflight.sh <container> <db> [install.sql]
#
# Run tests/163_set_partition_tz_midflight_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can show the file catches the defect of issue #660 its mutation puts back:
# set_partition_tz judged only ATTACHED bounds, so a zone change in the middle of a regrain was accepted
# and the rest of the run, computed in the new zone, overlapped the copies cut in the old one.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its load-bearing assertions include negatives ("the zone is
# unchanged", "no zone change was logged"), equally satisfied by a run in which no regrain was in flight
# at all or the zone was one the lattice checks refuse anyway; the file pins both with liveness witnesses
# (the cursor and the three copies really are there; Sao_Tome really agrees with UTC at every attached
# bound, and really is accepted once the run is cancelled), and pointing it at the mutant is what checks
# those witnesses still let it fail, every CI run.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   set_partition_tz_regrain_midflight -- the in-flight refusal removed, the lock kept: sections (A) and
#                                         (B) both catch it
#
# Usage: set_partition_tz_midflight.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/163_set_partition_tz_midflight_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "set_partition_tz refuses a zone change mid-regrain" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "set_partition_tz refuses a zone change mid-regrain" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
