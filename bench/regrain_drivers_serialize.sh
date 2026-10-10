#!/usr/bin/env bash
# regrain_drivers_serialize.sh <container> <db> [install.sql]
#
# Run tests/162_regrain_drivers_serialize_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can show the file catches the two defects of issue #554 its mutations put back.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its two-session sections are ordered by lock state (the second call
# is collected only once it is seen waiting while the first is still uncommitted), and every outcome they
# assert would also hold for a second call that simply ran after the first had committed; the file pins
# that with liveness witnesses, but nothing re-checks that the witnesses would still let it fail with the
# lock gone. It also learned the hard way that the lock can be masked: a first draft passed against the
# lockless mutant, because a step ANALYZEs a delta with no row estimate and ANALYZE's SHARE UPDATE
# EXCLUSIVE serialised the two steps by accident. Pointing the file at the mutants is what keeps that
# honest, every CI run.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   regrain_lock_noop               -- pgpm._regrain_lock takes nothing: two drivers of one parent
#                                      interleave again (sections C, D and E catch it)
#   set_regrain_retarget_midflight  -- set_regrain accepts a new target with a run in flight again, and
#                                      the run wedges on the new grid (sections A and B catch it)
#
# Usage: regrain_drivers_serialize.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/162_regrain_drivers_serialize_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "regrain drivers serialise; no retarget mid-flight" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "regrain drivers serialise; no retarget mid-flight" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
