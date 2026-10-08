#!/usr/bin/env bash
# regrain_capture_delta_held.sh <container> <db> [install.sql]
#
# Run tests/290_regrain_capture_delta_held_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1057, bullet
# 3): the capture function _regrain_capture_install mints checked the minted name with to_regclass, which
# takes no lock, and then ran a static insert that looked the name up again after queueing on the delta's
# lock. A writer that arrived while an operator's transaction held the delta to rename it wrote its keys,
# once the rename committed, into a table the operator created under the freed name (the swap never reads
# it, so the committed write was reverted), or died 42P01 when there was none. The file is the acceptance
# test, with a deterministic second and third session (dblink, ordered by lock state, never by sleeps); this
# wrapper exists so the mutation has a guard the discriminate track can run against the mutant, in the shape
# of bench/regrain_capture_delta_by_record.sh. Its hypertable twin is bench/hypertable_capture_delta_held.sh.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_capture_fast_path_unlocked -- #1051's capture: the unlocked to_regclass check, then the static
#                                         insert that resolves the minted name again after any wait.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/290_regrain_capture_delta_held_test.sql}"
LABEL="the regrain capture writes its delta only while it holds it"
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
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
