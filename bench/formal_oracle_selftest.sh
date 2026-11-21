#!/usr/bin/env bash
# The invariant oracle's own guard, against an ARBITRARY copy of tests/formal/oracle.sql (formal methods Phase 3 W5,
# docs/formal/phase3-design.md "Guards on the oracle"), so bench/discriminate.sh can require it to FAIL against the
# oracle_* mutations: each takes out the one clause that makes one invariant judge, or zeroes what judged() reports.
# Runs tests/formal/oracle_selftest_test.sql in a fresh database holding pgtap, pgpm's core, the demo fixtures and that
# oracle (tests/formal/harness.sh's template, the oracle swapped), and prints its TAP, so discriminate.sh's starved()
# rule reads the self-test's own `not ok` lines: a mutant caught only by a LIVENESS: or fixture: premise is unverified.
# run_perf runs it against the real oracle, the clean-code half of the pairs.
# Usage: formal_oracle_selftest.sh <container> <db> [tests/formal/oracle.sql]
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ORACLE="${3:-/repo/tests/formal/oracle.sql}"
q() { docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$C" psql -U postgres -d "${QDB:-postgres}" -v ON_ERROR_STOP=1 -qtA "$@"; }
q -c "drop database if exists $DB" >/dev/null
q -c "create database $DB" >/dev/null
if ! { QDB="$DB" q -c "create extension if not exists pgtap" >/dev/null &&
       QDB="$DB" q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null &&
       QDB="$DB" q -c "alter database \"$DB\" set poc.seed_count = 8000; alter database \"$DB\" set poc.events_count = 4000;" >/dev/null &&
       QDB="$DB" q -f /repo/fixtures/demo.sql >/dev/null &&
       QDB="$DB" q -f "$ORACLE" >/dev/null; }; then
  echo "FAIL  GUARD: the self-test's database (pgpm's core, the fixtures and $ORACLE) did not build"
  q -c "drop database if exists $DB" >/dev/null 2>&1
  exit 1
fi
rc=0
docker exec -e PGOPTIONS="-c client_min_messages=warning" "$C" pg_prove -v -U postgres -d "$DB" /repo/tests/formal/oracle_selftest_test.sql || rc=1
q -c "drop database if exists $DB" >/dev/null 2>&1
if [ "$rc" = 0 ]; then echo "PASS  the oracle's self-test"; else echo "FAIL  the oracle's self-test (its not ok lines above)"; fi
exit "$rc"
