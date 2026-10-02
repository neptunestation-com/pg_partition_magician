#!/usr/bin/env bash
# Run tests/234_fine_child_label_bc_wide_year_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant. The harness is
# bench/grid_timezone.sh's, selected by its GRID_TZ_TEST_FILE override: same fresh database, same
# install-must-succeed check, same "the assertions were reached at all" count, so read that file's header
# for why a wrapper around a plain pgTAP file exists at all.
#
# What THIS file guards (issue #769, its label bullet): transmute's orphan guard (the pg_class and the
# pg_type half) and restore_incoming_fks's in-flight gate recognise a time-grid fine child's label in a
# BC year (`_bc`, #710) and in a year past 9999 (five digits or more), through the one helper all three
# ask (pgpm._is_fine_child_label). Its time pattern was '^[0-9]{4}(_[0-9]+)*$', so such an orphan or
# domain passed the guard and the gate re-added a suspended FK with it still out of the parent. Half of
# tests/234 is negatives (the gate returns 0, the conversion did nothing), so each is paired with an AD
# control that already refused, with a precondition that the FK is still suspended before each zero, and
# with the conversion or re-add that follows once the holder is gone. This wrapper proves they would
# notice.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   fine_child_label_time_four_digit  -- the helper's time branch is the four-digit pattern again, which
#                                        reaches all three callers
#
# Usage: fine_child_label_bc_wide_year.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${FINE_CHILD_LABEL_BC_WIDE_YEAR_TEST_FILE:-/repo/tests/234_fine_child_label_bc_wide_year_test.sql}" \
GRID_TZ_LABEL="the orphan guard and FK gate know BC and wide-year labels" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
