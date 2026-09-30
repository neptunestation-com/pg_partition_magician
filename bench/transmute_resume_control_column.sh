#!/usr/bin/env bash
# Run tests/182_transmute_resume_control_column_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant. The harness is
# bench/grid_timezone.sh's, selected by its GRID_TZ_TEST_FILE override (see that file's header for why a
# wrapper around a plain pgTAP file exists at all, and bench/transmute_resume_lattice.sh for this one's
# closest sibling).
#
# What THIS file guards (issue #628): a transmute resumed after a failed cutover refuses a control column
# other than the one the recorded bound constrains, instead of reusing a validated CHECK on the old column
# and attaching on the new one, which scans the whole table under ACCESS EXCLUSIVE. tests/182's witnesses
# pin that the first attempt really failed in the cutover and left a validated CHECK on a, that b's values
# really lie inside that bound (so nothing but the refusal stops the re-run), and that the same column
# under a new name really resumes; this wrapper proves those witnesses would notice the refusal removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_resume_any_column  -- the resume's control-column check removed, which is pre-#628 behaviour
#                                   exactly: the re-run on b is not refused, dies at its first COMMIT
#                                   inside throws_like with 2D000, and tests/182 pins the refusal's message
#
# Usage: transmute_resume_control_column.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/182_transmute_resume_control_column_test.sql}" \
GRID_TZ_LABEL="a resumed transmute refuses another control column" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
