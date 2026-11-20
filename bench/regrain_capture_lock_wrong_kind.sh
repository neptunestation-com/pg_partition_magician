#!/usr/bin/env bash
# regrain_capture_lock_wrong_kind.sh <container> <db> [install.sql]
#
# Run tests/385_regrain_capture_lock_wrong_kind_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1061, the core capture):
# the capture function _regrain_capture_install mints takes ROW EXCLUSIVE on its delta through the name it is about
# to use, and its handlers caught 42P01, 3F000 and 42501 but not wrong_object_type (42809). When the operator renamed
# the delta and gave the freed name to a materialized view or a sequence, the lock a queued writer took after the
# rename landed on that relation and raised 42809, uncaught, and the write died instead of following the delta. Both
# locks had the gap: the fast path's static LOCK on the minted name and the loop's on the name rendered from the oid.
# The file is the acceptance test, with tests/290's deterministic second and third session (dblink, ordered by lock
# state, never by sleeps); this wrapper exists so the mutations have a guard the discriminate track can run against
# the mutant, in the shape of bench/regrain_capture_delta_held.sh.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   regrain_capture_fast_lock_misses_42809 -- the fast path's handler without wrong_object_type: e385 and f385 die.
#   regrain_capture_loop_lock_misses_42809 -- the loop's handler without it: g385 dies.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/385_regrain_capture_lock_wrong_kind_test.sql}"
LABEL="a capture lock refused as 42809 follows the delta"
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
