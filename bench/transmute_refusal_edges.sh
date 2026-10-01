#!/usr/bin/env bash
# Run tests/189_transmute_refusal_edges_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by its
# GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same "the assertions
# were reached at all" count, so read that file's header for why a wrapper around a plain pgTAP file exists.
#
# What THIS file guards (issue #710): three refusals that used to arrive late or not at all. transmute of a
# table with an EXCLUDE constraint, and transmute by a role that does not own a publication naming the
# table, both died raw inside the cutover after phases 1 and 2 had committed the validated bound and the
# claim, leaving the table rejecting every write past hi; set_regrain accepted a target whose later cells'
# names do not fit, which every tick then refused. Most of tests/189 is negatives ("no claim left", "no
# bound left", "nothing recorded"), which a run that never set the shape up would satisfy as well, so the
# file pins the setup with witnesses (the constraint and its non-unique index, the publication the role
# does not own, the 64-byte name) and each refusal with a witness that the same call succeeds once the
# condition is gone. The failing conversions go through dblink, so a mutant really commits phases 1 and 2.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   transmute_exclude_not_refused         -- the EXCLUDE refusal in _transmute_carried_indexes, disarmed
#   transmute_publication_owner_late      -- the up-front publication-owner refusal, disarmed
#   set_regrain_anchor_name_only          -- set_regrain asks _part_name about the anchor cell only again
#
# Usage: transmute_refusal_edges.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${TRANSMUTE_REFUSAL_EDGES_TEST_FILE:-/repo/tests/189_transmute_refusal_edges_test.sql}" \
GRID_TZ_LABEL="EXCLUDE, unowned publication and long names refused up front" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
