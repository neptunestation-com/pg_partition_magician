#!/usr/bin/env bash
# Run tests/218_transmute_reads_caller_rls_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant. The harness is bench/grid_timezone.sh's, selected by its
# GRID_TZ_TEST_FILE override: same fresh database, same install-must-succeed check, same "the assertions
# were reached at all" count, so read that file's header for why a wrapper around a plain pgTAP file exists.
#
# What THIS file guards (issue #825, the transmute half): transmute's bound reads ran under the caller's
# row-level security, so a non-superuser owner without BYPASSRLS of a FORCE'd table committed a monolith
# bound sized from the rows its policies admit, died at phase 2's VALIDATE with a raw 23514, and left that
# bound rejecting every write below it. transmute now refuses that caller up front
# (pgpm._refuse_filtered_reads). tests/218 runs the refused conversion through dblink, so the pre-fix code
# really commits phase 1 and the state assertions discriminate, and pairs it with an owner on an ENABLEd but
# not FORCEd table and a superuser on a FORCE'd one, both of which must still convert every row.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_reads_under_caller_rls  -- _transmute's call to the refusal deleted
#
# Usage: transmute_reads_caller_rls.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${TRANSMUTE_READS_CALLER_RLS_TEST_FILE:-/repo/tests/218_transmute_reads_caller_rls_test.sql}" \
GRID_TZ_LABEL="transmute refuses a caller whose reads RLS filters" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
