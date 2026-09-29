#!/usr/bin/env bash
# Run tests/136_regrain_reconcile_datestyle_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override (see that file's header for why a wrapper around a plain pgTAP file
# exists at all, and bench/month_step_dst_gap.sh for a sibling of this one).
#
# What THIS file guards (issue #570): _regrain_reconcile renders each captured key's control value
# through _ts_text, never a bare ::text, so the fine child it files the key into does not depend on the
# session's DateStyle. Under SQL DateStyle and Asia/Kolkata a bare render reads 'IST', which parses back
# as Israel (+02), 3.5 hours late: a captured DELETE was consumed against the wrong fine child and the
# swap brought the row back, and a captured UPDATE or INSERT was reinserted into a child whose CHECK
# refused it, wedging the regrain. tests/136 witnesses the session's IST render and the 3.5-hour round
# trip, a fine child where the misread key would go, and the capture and reconcile of every change,
# then pins the rows through the swap by identity and by the fine child serving each.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_reconcile_bare_text  -- both branches of the per-row render (a timestamptz column's own
#                                   text, a naive column's instant) are a bare ::text again, which is
#                                   pre-#570 behaviour exactly
#
# Usage: regrain_reconcile_datestyle.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/136_regrain_reconcile_datestyle_test.sql}" \
GRID_TZ_LABEL="the reconcile files a captured key by its instant, in any DateStyle" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
