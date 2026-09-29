#!/usr/bin/env bash
# Run tests/161_obtain_explicit_name_too_long_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same "the
# assertions were reached at all" count, so read that file's header for why a wrapper around a plain
# pgTAP file exists at all.
#
# What THIS file guards (issue #663): on an upgraded pre-#503 day grid, #572 builds the cell a legacy
# label collides with under its explicit-range name, which is 14 bytes longer than the plain one, and #510
# refuses a name over 63 bytes. For a table name that fits the plain label and not the explicit one, that
# refusal used to escape obtain, unwinding every cell the tick would have built, on every tick. The file's
# "no skip_obtain" and "no cut name" are negatives, so it pins its setup with liveness witnesses (the
# legacy label really is the next cell's plain name, the explicit name really is 67 bytes and refused, the
# builder really reached past the cell), and this wrapper is what proves those witnesses would notice the
# refusal escaping again.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   obtain_explicit_name_uncaught  -- _obtain_name lets _part_name's #510 refusal of the explicit-range
#                                     name escape again: the tick logs skip_obtain and builds nothing
#
# Usage: obtain_explicit_name_too_long.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/161_obtain_explicit_name_too_long_test.sql}" \
GRID_TZ_LABEL="obtain builds past a cell whose explicit name cannot fit" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
