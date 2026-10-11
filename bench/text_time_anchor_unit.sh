#!/usr/bin/env bash
# text_time_anchor_unit.sh <container> <db> [install.sql]
#
# Run tests/284_text_time_anchor_unit_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #989): transmute
# accepted a p_anchor (or a step) finer than a text_time encoding's unit, _ts_to_text_time floored every
# bound to the unit, and pgpm.part recorded bounds half a second above the catalog's on an ObjectId grid.
# The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track
# can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   text_time_anchor_unit_unchecked  -- transmute no longer asks _text_time_unit_contract, the pre-fix
#                                       shape. tests/284 assertions 1 to 4.
#   text_time_unit_unix_epoch        -- the plausible-but-wrong check: the anchor measured from the Unix
#                                       epoch instead of p_tt_epoch, which _ts_to_text_time counts from.
#                                       tests/284 assertion 4.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/284_text_time_anchor_unit_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a text_time anchor and step are whole multiples of the unit" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a text_time anchor and step are whole multiples of the unit" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
