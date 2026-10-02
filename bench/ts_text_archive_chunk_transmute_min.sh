#!/usr/bin/env bash
# Run tests/213_ts_text_archive_chunk_transmute_min_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant. The harness is
# bench/grid_timezone.sh's, selected by its GRID_TZ_TEST_FILE override (see that file's header for why a
# wrapper around a plain pgTAP file exists at all, and bench/regrain_reconcile_datestyle.sh for a sibling).
#
# What THIS file guards (issue #788): two more reads of a timestamptz control value that the same session
# parses back go through _ts_text, never a bare ::text, so their result does not depend on the session's
# DateStyle. _next_archive_chunk's three value reads: under SQL DateStyle and Europe/Dublin a bare render
# reads 'IST', which parses back as Israel (+02), an hour early, so the picker returned no chunk and the
# aged child was never archived or retired. _transmute's min(control): under SQL DateStyle and
# Asia/Kolkata the minimum read 3.5 hours late, the monolith's lo floored a month late, and phase 2's
# VALIDATE failed on the table's own row. tests/213 witnesses each session's IST render and its round-trip
# gap, and an ISO-session control for each site, then pins the chunk by its bounds, the ledger by its
# chunks and their rows, and the conversion by its lo and the partition serving each row.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site:
#   archive_chunk_bare_text  -- the picker's shared value render is a bare ::text again
#   transmute_min_bare_text  -- transmute's min(control) read is a bare ::text again
#
# The defect is reachable in one session only before PostgreSQL 18 (see tests/213's header); the perf
# and discriminate tracks run this on 17.
#
# Usage: ts_text_archive_chunk_transmute_min.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/213_ts_text_archive_chunk_transmute_min_test.sql}" \
GRID_TZ_LABEL="the archive chunk and transmute's lo are the same in any DateStyle" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
