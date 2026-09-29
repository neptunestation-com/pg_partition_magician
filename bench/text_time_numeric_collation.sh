#!/usr/bin/env bash
# Run tests/134_text_time_numeric_collation_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant. The harness is
# bench/grid_timezone.sh's, selected by its GRID_TZ_TEST_FILE override: same fresh database, same
# install-must-succeed check, same "the assertions were reached at all" count, so read that file's
# header for why a wrapper around a plain pgTAP file exists at all.
#
# What THIS file guards (issue #568): _check_text_time_collation refuses a control column whose
# collation weighs a run of decimal digits by its numeric value (ICU 'und-u-kn-true'), under which cuid
# rows are routed to the wrong month. The refusals in tests/134 are paired with witnesses that the
# collation really misorders the fixture rows against their own month's bounds, and with positive
# controls (collate "C", en_US.utf8, ICU without numeric ordering) that must still convert; this
# wrapper is what proves the refusals would notice the new probes being removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   text_time_collation_positional_only  -- the probe keeps only its first shape, '<d><max>...' <
#                                           '<d+1><zero>...', which a numeric ordering satisfies, so
#                                           the column is accepted and routing misplaces rows again
#
# Usage: text_time_numeric_collation.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/134_text_time_numeric_collation_test.sql}" \
GRID_TZ_LABEL="a numeric-ordering collation is refused for text_time" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
