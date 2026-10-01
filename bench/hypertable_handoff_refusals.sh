#!/usr/bin/env bash
# Run tests/timescale/db/34_from_hypertable_handoff_refusals_test.sql against an ARBITRARY copy of
# pgpm_hypertable/install.sql, so bench/discriminate.sh can point it at a mutant (issue #792).
#
# The file is plain pgTAP and the timescale track runs it already; this wrapper is the standing proof that
# its assertions DISCRIMINATE. The subjects are two of transmute's refusals that the hypertable already
# shows, which used to come only after the cutover's swap had dropped it: a bare unique index as the key,
# and a newest row past the frontier bound (#457), with p_force_frontier passed through to accept that.
# Every refusal is of a committing procedure, so it is wrapped by throws_like, and a procedure that wrongly
# does NOT refuse dies at its first COMMIT inside the wrapper with 2D000 and rolls back into the state a
# refusal leaves: the pinned message is the only thing that tells them apart, and pointing the file at a
# mutant is how that is known.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   hypertable_key_unchecked                    -- _from_hypertable_check_key asks nothing: the preflight,
#                                                  from_hypertable, the copy and the cutover all go on
#   hypertable_cutover_key_unchecked_under_lock -- the cutover's own key check deleted: a destination made
#                                                  by hand reaches the swap
#   hypertable_frontier_unchecked_up_front      -- from_hypertable does not ask the frontier before its copy
#   hypertable_cutover_frontier_unchecked       -- the cutover does not ask it under its lock
#   hypertable_cutover_force_frontier_dropped   -- the cutover does not pass p_force_frontier to transmute
#   hypertable_force_frontier_not_to_cutover    -- from_hypertable does not pass it to the cutover
#
# Usage: hypertable_handoff_refusals.sh <container> <db> [pgpm_hypertable/install.sql]
# Runs on the TIMESCALE track's container (supabase/postgres + TimescaleDB), which is why its mutations
# sit in MUTATION_TRACK=timescale. That image does not trust the local socket, so every psql call goes
# over TCP (see run_timescale). run_timescale also runs it against the real install, so a harness broken
# enough to fail against everything cannot read as discriminating.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
TEST_FILE="${HYPERTABLE_HANDOFF_REFUSALS_TEST_FILE:-/repo/tests/timescale/db/34_from_hypertable_handoff_refusals_test.sql}"
LABEL="key and frontier refusals come before the swap"
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
  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1)
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+ -')
  # Two failure shapes, reported apart. A file that died early leaves a raw ERROR: and few or no
  # assertions, which must NOT read the same as assertions that ran and failed: discriminate.sh treats
  # any non-zero exit as "the guard caught the defect", so a harness broken enough to fail against
  # everything would otherwise be reported as proving the mutation. And a plan shortfall is a failure
  # too (#601), which this runner, unlike pg_prove, has to look for itself.
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if echo "$out" | grep -qE '^# Looks like you planned'; then
    printf 'FAIL  %-58s %s\n' "the file ran every assertion it planned" "$(echo "$out" | grep -E '^# Looks like you planned')"
    fail=1
  fi
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran, $bad failed"; fail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
