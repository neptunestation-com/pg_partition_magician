#!/usr/bin/env bash
# Run tests/140_transmute_reap_identity_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by
# its GRID_TZ_TEST_FILE override (see that file's header for why a wrapper around a plain pgTAP file
# exists at all).
#
# What THIS file guards (issue #575): the transmute reaper and transmute_abort find a half-converted table
# by the claim's oid, not by the schema and name the claim recorded, so a table renamed or moved to another
# schema after its conversion failed has its write-rejecting bound dropped rather than orphaned. tests/140's
# witnesses pin that each conversion really failed and left a claim and a bound, that the renamed and
# moved relations really are the same oids, and that the bound really rejected a write before the sweep;
# this wrapper proves those witnesses would notice the name-based lookup put back.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_reap_by_name  -- the reaper's "relation is gone" test and both ALTERs resolve nsp/rel again,
#                              which is pre-#575 behaviour exactly: the renamed table reads as gone, its
#                              claim is deleted and its bound stays, and the abort alters a name that no
#                              longer exists
#
# Usage: transmute_reap_identity.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/140_transmute_reap_identity_test.sql}" \
GRID_TZ_LABEL="the reaper and abort find the table by oid, not name" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
