#!/usr/bin/env bash
# Run tests/timescale/db/37_from_hypertable_reads_caller_rls_test.sql against an ARBITRARY copy of
# pgpm_hypertable/install.sql, so bench/discriminate.sh can point it at a mutant (issue #825).
#
# The file is plain pgTAP and the timescale track runs it already; this wrapper is the standing proof that
# its assertions DISCRIMINATE. The subject is the caller's row-level security: on a hypertable with FORCE
# ROW LEVEL SECURITY a non-superuser owner without BYPASSRLS reads only the rows its policies admit, so the
# chunk copy held only those, the conservation check read the source the same way and agreed, and the swap
# dropped the rest. Each phase now refuses such a caller up front through pgpm._refuse_filtered_reads. The
# file runs the refused calls as the owner inside a function, where a phase that does not refuse dies at
# its first COMMIT with 2D000; the message pins are what tell that apart from the refusal.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   hypertable_preflight_reads_under_caller_rls -- the preflight's call deleted, so from_hypertable and
#                                                  from_hypertable_copy copy as the filtered owner
#   hypertable_cutover_reads_under_caller_rls   -- the cutover's call deleted, so its catch-up and its
#                                                  conservation check read the source as that owner
#
# Usage: hypertable_reads_caller_rls.sh <container> <db> [pgpm_hypertable/install.sql]
# Runs on the TIMESCALE track's container (supabase/postgres + TimescaleDB), which is why its mutations sit
# in MUTATION_TRACK=timescale. That image does not trust the local socket, so every psql call goes over TCP
# (see run_timescale). run_timescale also runs it against the real install, so a harness broken enough to
# fail against everything cannot read as discriminating.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
TEST_FILE="${HYPERTABLE_READS_CALLER_RLS_TEST_FILE:-/repo/tests/timescale/db/37_from_hypertable_reads_caller_rls_test.sql}"
LABEL="a caller whose reads RLS filters is refused before any copy"
fail=0

q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@"; }

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
q -d postgres -q -c "create database $DB" >/dev/null 2>&1
q -d postgres -q -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1

if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$HT"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the timescale fixtures loaded" "tests/timescale/fixtures.sql"
  fail=1
fi

if [ "$fail" = 0 ]; then
  # >>> pgTAP verdict: the same in every timescale wrapper; bench/wrapper_tap_verdicts.sh evaluates it.
  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+' | sed 's/^/    /' | head -20
  planned=$(echo "$out" | sed -nE 's/^1\.\.([0-9]+)$/\1/p' | head -1)
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+( |$)')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+( |$)')
  # pg_prove's verdict, which this runner has to apply itself. Three ways a file fails with no `not ok`,
  # each reported apart from assertions that ran and failed (discriminate.sh reads any non-zero exit as
  # "the guard caught the defect", so a harness that fails everything must say why): a raw ERROR:; a
  # psql exit other than 0, which is how a session that died part-way (FATAL, no ERROR:) shows, since it
  # never reaches finish() to print "# Looks like you planned" (#795); and a count of assertions
  # that is not the 1..N plan's, which a silently skipped assertion leaves (#601, #712).
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ "$rc" != 0 ]; then
    printf 'FAIL  %-58s %s\n' "psql ran the file to its end" "exit $rc"
    echo "$out" | grep -E 'FATAL:|connection' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ -z "$planned" ] || [ "$ran" != "$planned" ]; then
    printf 'FAIL  %-58s %s\n' "the file ran every assertion it planned" "planned ${planned:-nothing}, $ran ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran, $bad failed"; fail=1
  fi
  # <<< pgTAP verdict
fi

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
