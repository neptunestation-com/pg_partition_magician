#!/usr/bin/env bash
# Run tests/timescale/db/347_from_hypertable_drain_probe_by_oid_test.sql against an ARBITRARY copy of
# pgpm_hypertable/install.sql, so bench/discriminate.sh can point it at a mutant (issue #1356), through
# bench/hypertable_by_oid_after_wait.sh, whose harness and pgTAP verdict it shares.
#
# The two drains asked whether anything was left with an EXISTS on the source or the delta, and the append step
# read its watermark from the source, each named before it waited for its lock and none locked by oid first: a
# schema renamed aside during that wait with an EMPTY namesake committed made the drains return converged and the
# step return its input watermark, the recorded source and delta still holding undrained rows. Each probe's relation
# is now locked by its oid first and named by its oid's rendering, so the drains follow it and drain it.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   hypertable_drain_appends_probe_unlocked      -- the append drain's residual probe unlocked: part A
#   hypertable_drain_delta_probe_unlocked        -- the delta drain's residual probe unlocked: part B
#   hypertable_drain_appends_step_source_unlocked -- the append step's watermark probe unlocked: part C
#
# Usage: hypertable_drain_probe_by_oid.sh <container> <db> [pgpm_hypertable/install.sql]
set -uo pipefail
HYPERTABLE_BY_OID_TEST_FILE=/repo/tests/timescale/db/347_from_hypertable_drain_probe_by_oid_test.sql \
HYPERTABLE_BY_OID_LABEL="the drains never read an empty namesake as converged" \
  exec bash "$(dirname "$0")/hypertable_by_oid_after_wait.sh" "$@"
