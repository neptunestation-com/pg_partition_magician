#!/usr/bin/env bash
# Run tests/152_month_floor_doubled_midnight_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override (see that file's header for why a wrapper around a plain pgTAP file
# exists at all, and bench/month_step_dst_gap.sh for the gap-side sibling of this one).
#
# What THIS file guards (issue #584): a month floor never exceeds its input where a fall-back makes
# midnight on the 1st happen twice (America/Havana on 2020-11-01 and 2026-11-01). tests/152 pins the
# floors and the next of the October floor by hand-derived value, each with a witness that the hour
# really is doubled, and runs the issue's conversion end to end (it failed at VALIDATE on every run).
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   grid_floor_month_later_midnight  -- the month floor converts wall midnight with `at time zone` again,
#                                       which resolves the doubled midnight to its later occurrence
#
# Usage: month_floor_doubled_midnight.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/152_month_floor_doubled_midnight_test.sql}" \
GRID_TZ_LABEL="a month floor never exceeds its input across a doubled midnight" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
