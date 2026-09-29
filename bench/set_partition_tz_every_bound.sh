#!/usr/bin/env bash
# Run tests/151_set_partition_tz_every_bound_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override (see that file's header for why a wrapper around a plain pgTAP file
# exists at all).
#
# What THIS file guards (issue #583): set_partition_tz judges every attached bound that is a grid boundary
# in the recorded zone, not only the newest one. tests/151 builds a month grid whose top is on the new
# zone's lattice and whose monolith hi is not (UTC -> Europe/London, or Atlantic/Azores -> UTC, chosen
# from the date so the premise always holds, and witnessed), and pins the refusal, the bound it names,
# and that nothing changed; its liveness side is that the grid's own zone, a finer regrain's bounds and
# the upgrade case are all still accepted.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   set_partition_tz_newest_bound_only  -- the every-bound check disabled, the newest-bound check left:
#                                          the zone change is accepted and the monolith can never be
#                                          regrained, which is #583 exactly
#
# Usage: set_partition_tz_every_bound.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/151_set_partition_tz_every_bound_test.sql}" \
GRID_TZ_LABEL="set_partition_tz refuses a zone any grid bound is not on" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
