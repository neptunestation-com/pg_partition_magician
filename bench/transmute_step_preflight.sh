#!/usr/bin/env bash
# Run tests/141_transmute_step_obtain_preflight_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant. The harness is
# bench/grid_timezone.sh's, selected by its GRID_TZ_TEST_FILE override (see that file's header for why a
# wrapper around a plain pgTAP file exists at all).
#
# What THIS file guards (issue #581): transmute refuses a non-positive step, a step that is not a whole
# number of days on a date column, and a negative or null p_obtain, before anything is committed. Each
# refusal in tests/141 is pinned by its own message (a committing procedure that does not refuse dies at
# its first COMMIT inside throws_like with 2D000, which an unpinned assertion would accept), and the file
# converts every fixture with the corrected argument, so a table that could not be converted at all
# cannot pass for one that was refused; this wrapper proves those assertions would notice the refusals
# removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_no_step_obtain_preflight  -- the three #581 refusals removed, which is pre-#581 behaviour
#                                          exactly
#
# Usage: transmute_step_preflight.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/141_transmute_step_obtain_preflight_test.sql}" \
GRID_TZ_LABEL="transmute refuses a bad step or p_obtain up front" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
