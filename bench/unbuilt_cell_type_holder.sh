#!/usr/bin/env bash
# Run tests/214_unbuilt_cell_type_holder_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same
# "the assertions were reached at all" count, so read that file's header for why a wrapper around a
# plain pgTAP file exists at all.
#
# What THIS file guards (issue #790): when a type (an enum, a domain, a range type) holds a forward
# cell's name, obtain and extend_to leave the cell unbuilt and log fail_obtain_name through
# _log_unbuilt_cell, whose method must name what holds the name. The holder used to be resolved through
# to_regclass alone, which sees relations only, so for a type the method stopped at "is held by " and
# named nothing. tests/214 pins each method exactly (an enum, a domain, a range type, and a view, the
# relation case) and pins with liveness rows that the cells really were left unbuilt and logged, so a
# method read off a run that never reached _log_unbuilt_cell cannot pass. This wrapper proves the file
# notices the pre-fix holder clause.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   unbuilt_cell_type_holder_unnamed  -- the type branch of the holder clause switched off, the pre-fix
#                                        expression exactly
#
# Usage: unbuilt_cell_type_holder.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${UNBUILT_CELL_TYPE_HOLDER_TEST_FILE:-/repo/tests/214_unbuilt_cell_type_holder_test.sql}" \
GRID_TZ_LABEL="fail_obtain_name names a type that holds a cell's name" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
