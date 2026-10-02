#!/usr/bin/env bash
# Run tests/233_grid_floor_across_era_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same
# "the assertions were reached at all" count, so read that file's header for why a wrapper around a
# plain pgTAP file exists at all.
#
# What THIS file guards (issue #769, its BC bullet): _grid_floor's calendar branch floors to the greatest
# grid point at or below its input on both sides of the era. It counted the years from the anchor with
# extract(year), which has no year 0, so a BC value floored a year early from the 2000 anchor (an
# interrupted transmute of a table with BC rows was refused on its same-step re-run, regrain_step of a BC
# monolith minted an inverted copy child) and an AD value floored above itself from a BC anchor.
# tests/233 sweeps every month start from 3 BC to 3 AD for three calendar steps, then drives the resume
# and the regrain end to end, each paired with an AD control through the same code. This wrapper proves
# the file would notice.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   grid_floor_calendar_no_year_zero  -- the month count takes extract(year) differences again
#
# Usage: grid_floor_across_era.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_FLOOR_ACROSS_ERA_TEST_FILE:-/repo/tests/233_grid_floor_across_era_test.sql}" \
GRID_TZ_LABEL="the calendar floor is exact across the era" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
