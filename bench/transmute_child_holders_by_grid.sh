#!/usr/bin/env bash
# transmute_child_holders_by_grid.sh <container> <db> [install.sql]
#
# Run tests/341_transmute_child_holders_by_grid_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issues #1274, #1216):
# transmute's orphan-child guard (_transmute_refuse_child_holders) asked whether a name's suffix was a label of
# the control KIND, so a monthly grid was refused by the operator's own <rel>_p2023, a year label it can never
# give, and told to drop it; and it excused any relation with a pg_inherits parent, so a partition or
# inheritance child of ANOTHER table at a forward cell's name passed, and the conversion completed with that
# cell unbuilt. The guard now asks _grid_can_label (the step's granularity, or a finer one, or the coarser one a
# regrain target the step allows reaches), and refuses a relation of another table's hierarchy at a name the
# conversion itself creates (a forward cell's), leaving one at a name only a later regrain or obtain gives to
# their own refusals; and
# restore_incoming_fks's in-flight gate, which recognises a fine child's name as the guard does, asks
# _grid_can_label too, so a table the guard lets a preserve conversion through with does not hold the dropped
# incoming keys off for good. The file is the acceptance test, and pairs each refusal and each conversion with
# a witness that the name is (or is not) one the grid gives; this wrapper exists so the mutations have a guard
# the discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# The mutations required to fail against it (bench/mutations/mutate.py):
#   child_holders_any_kind_label       -- the pg_class half asks the kind's label test alone: part A's
#                                         monthly conversion is refused by t341a_p2023, part G's '30 days'
#                                         one by t341g_p2023_05
#   child_holder_types_any_kind_label  -- the pg_type half does: part A is refused by the domain t341a_p2022
#   child_holders_any_parent_exempt    -- any pg_inherits parent excuses a holder: parts E, F, I and J convert
#   child_holders_inherits_any_name    -- a hierarchy member at ANY name in reach is a holder: part K's
#                                         conversion is refused by another table's partition at a regrain
#                                         cell's name inside the monolith
#   restore_gate_any_kind_label        -- restore_incoming_fks's gate asks the kind's label test alone: part
#                                         H's incoming key is never re-added beside t341h_p2023
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo. The file builds its own fixtures, so
# fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/341_transmute_child_holders_by_grid_test.sql}"
WHAT="the orphan-child guard asks this grid's labels and this parent"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-62s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-62s %s\n' "$WHAT" "$ran ran"
  else printf 'FAIL  %-62s %s\n' "$WHAT" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-62s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
