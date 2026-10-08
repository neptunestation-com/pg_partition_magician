#!/usr/bin/env bash
# Run tests/293_obtain_plain_name_too_long_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by its
# GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same "the assertions
# were reached at all" count, so read that file's header for why a wrapper around a plain pgTAP file exists.
#
# What THIS file guards (issue #1072): an id label widens from 19 to 20 digits at 10^19, so on a numeric key
# a 42-byte table name fits every cell below that edge and none past it. #510 refuses a name over 63 bytes,
# and that refusal of a cell's PLAIN name used to escape obtain and extend_to, unwinding every cell the call
# would have built, the nameable [9.9e18, 10^19) among them, on every tick. The file's "no skip_obtain" and
# "no cut name" are negatives, so it pins its setup with liveness witnesses (the 63-byte cell and the
# 64-byte one, the fail_obtain_name rows proving the walk reached past the edge), and its part C pins the
# boundary the other way: a table whose name fits no cell of its grid is still refused.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   obtain_plain_name_uncaught       -- the plain name's refusal escapes again: the tick logs skip_obtain,
#                                       builds nothing, and extend_to raises
#   obtain_plain_name_caught_always  -- the over-correction: every plain refusal is swallowed, so part C's
#                                       too-long table is no longer refused
#
# Usage: obtain_plain_name_too_long.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${OBTAIN_PLAIN_NAME_TEST_FILE:-/repo/tests/293_obtain_plain_name_too_long_test.sql}" \
GRID_TZ_LABEL="obtain builds past a cell whose plain name cannot fit" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
