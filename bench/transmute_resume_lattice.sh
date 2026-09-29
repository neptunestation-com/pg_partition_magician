#!/usr/bin/env bash
# Run tests/139_transmute_resume_lattice_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override (see that file's header for why a wrapper around a plain pgTAP file
# exists at all, and bench/transmute_resume_zone.sh for this one's closest sibling).
#
# What THIS file guards (issue #574): a transmute resumed after a failed cutover refuses a step or anchor
# whose grid the recorded bound is not on, instead of reusing the bound and registering a grid with a hole
# right past the monolith's hi. tests/139's witnesses pin that the first attempt really failed in the
# cutover and left a claim on the step-10 grid, that 20 really is not a step-7 boundary, and that a step
# the bound IS flush with really resumes; this wrapper proves those witnesses would notice the refusal
# removed.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_resume_any_step  -- the resume's lattice check removed, which is pre-#574 behaviour exactly:
#                                 the step-7 re-run is not refused, dies at its first COMMIT inside
#                                 throws_like with 2D000, and tests/139 pins the refusal's own message
#
# Usage: transmute_resume_lattice.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/139_transmute_resume_lattice_test.sql}" \
GRID_TZ_LABEL="a resumed transmute refuses a grid its bound is not on" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
