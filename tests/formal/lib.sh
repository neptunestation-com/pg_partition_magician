# shellcheck shell=bash
# Shared by tests/formal/harness.sh and tests/formal/measure_cost.sh; sourced, never run. Needs $c, the container
# (a pgpm_test image with this repository mounted at /repo).

# psql in the container, against $DB (default postgres), quiet, unaligned, stopping on the first error
q() { docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "${c:?the container}" psql -U postgres -d "${DB:-postgres}" -v ON_ERROR_STOP=1 -qtA "$@"; }

# The pgTAP template test.sh's run_version builds (pgtap, pgpm's core, the demo fixtures), plus the oracle.
build_template() {  # <template db> [oracle: 1 (default) or 0]
  local t="$1" oracle="${2:-1}"
  q -c "drop database if exists $t" >/dev/null
  q -c "create database $t" >/dev/null
  DB="$t" q -c "create extension if not exists pgtap" >/dev/null
  DB="$t" q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
  DB="$t" q -c "alter database \"$t\" set poc.seed_count = 8000; alter database \"$t\" set poc.events_count = 4000;" >/dev/null
  DB="$t" q -f /repo/fixtures/demo.sql >/dev/null
  if [ "$oracle" = 1 ]; then DB="$t" q -f /repo/tests/formal/oracle.sql >/dev/null; fi
}
