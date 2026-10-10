#!/usr/bin/env bash
# regrain_names_fit_clamped_cell.sh <container> <db> [install.sql]
#
# Run tests/238_regrain_names_fit_clamped_cell_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #815,
# F3-06): set_regrain's name check (_regrain_names_fit, #710) rendered a clamped first sub-range with
# _part_name at the target step's granularity, while regrain_step names it through _regrain_sub_name (#783)
# at a finer and longer label, so a table name that fit the day label but not the clamped cell's hour label
# passed set_regrain and every auto-regrain tick then failed the 63-byte limit. The file is the acceptance
# test; this wrapper exists so the mutation has a guard the discriminate track can run against the mutant,
# in the shape of bench/retain_recall_moved_parent.sh.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_names_fit_part_name  -- the check names each cell with _part_name again, the pre-fix shape.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/238_regrain_names_fit_clamped_cell_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "set_regrain checks a clamped cell's name as minted" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "set_regrain checks a clamped cell's name as minted" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
