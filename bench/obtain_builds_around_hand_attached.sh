#!/usr/bin/env bash
# obtain_builds_around_hand_attached.sh <container> <db> [install.sql]
#
# Run tests/368_obtain_builds_around_hand_attached_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1119): whether a
# forward cell was built was judged from pgpm.part alone, so a partition the operator attached by hand over a cell's
# range was invisible, obtain's CREATE ... PARTITION OF over it raised "would overlap", and the whole call unwound
# on every tick, building no other missing cell. The file is the acceptance test; this wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/retire_default_partition.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   obtain_hand_attached_unseen           -- _cell_attached reads pgpm.part alone again. Parts A to E.
#   obtain_hand_attached_maxvalue_unseen  -- a partition up to MAXVALUE reaches no cell. Part C.
#   obtain_hand_attached_closed_bound     -- the cell starting at its upper bound is taken for covered. Part A.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the
# container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/368_obtain_builds_around_hand_attached_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "obtain builds around a partition attached by hand" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "obtain builds around a partition attached by hand" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
