#!/usr/bin/env bash
# Run tests/135_regrain_restart_null_cursor_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override (see that file's header for why a wrapper around a plain pgTAP file
# exists at all, and bench/month_step_dst_gap.sh for a sibling of this one).
#
# What THIS file guards (issue #569): regrain_step's prepare tick discards the regrain's copies whenever
# no change capture is installed on the source, whatever config.regrain_cursor says. The janitor's
# documented backstop (a cursor cleared by hand, then _enforce_regrain_capture reaping the capture it no
# longer covers) leaves the copies with the cursor NULL, and a discard gated on the cursor let the next
# run resume from them, so the swap reverted an UPDATE, resurrected a DELETE and lost an INSERT made
# while capture was off. tests/135 witnesses the copy, the reaped capture and the uncaptured changes,
# then pins the restart row, the dropped copy and the rows through the swap by identity.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_restart_needs_cursor  -- the discard-and-restart is gated on regrain_cursor IS NOT NULL
#                                    again, which is pre-#569 behaviour exactly
#
# Usage: regrain_restart_null_cursor.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/135_regrain_restart_null_cursor_test.sql}" \
GRID_TZ_LABEL="copies made without capture are discarded whatever the cursor says" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
