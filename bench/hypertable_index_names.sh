#!/usr/bin/env bash
# Run tests/timescale/db/29_from_hypertable_index_names_test.sql against an ARBITRARY copy of
# pgpm_hypertable/install.sql, so bench/discriminate.sh can point it at a mutant (issues #735 and #707).
#
# The file is plain pgTAP and the timescale track runs it already; this wrapper is the standing proof that
# its assertions DISCRIMINATE. Its subjects are the index pre-builds the copy and the cutover run (a name
# holding a space, a 63-byte key name) and the up-front refusal of a grid whose monolith name transmute
# would refuse after the swap. That refusal is of from_hypertable and from_hypertable_cutover, committing
# procedures, so it is wrapped by throws_like, and a procedure that wrongly does NOT refuse dies at its first
# COMMIT inside the wrapper with 2D000 and rolls back into the state a refusal leaves: the pinned message is
# the only thing that tells them apart, and pointing the file at a mutant is how that is known.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per defect:
#   hypertable_index_ddl_by_pattern -- the pre-builds rewrite pg_get_indexdef by the space-delimited
#                                      pattern again (#735); part A fails
#   hypertable_tmp_name_cut         -- the temp names are cut to 63 bytes again (#707); part B fails
#   hypertable_handoff_unchecked    -- the monolith name is not asked for up front (#707); part C fails
#
# Usage: hypertable_index_names.sh <container> <db> [pgpm_hypertable/install.sql]
# Runs on the TIMESCALE track's container (supabase/postgres + TimescaleDB), which is why its mutations
# sit in MUTATION_TRACK=timescale. That image does not trust the local socket, so every psql call goes
# over TCP (see run_timescale). run_timescale also runs it against the real install, so a harness broken
# enough to fail against everything cannot read as discriminating.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
TEST_FILE="${HYPERTABLE_INDEX_NAMES_TEST_FILE:-/repo/tests/timescale/db/29_from_hypertable_index_names_test.sql}"
LABEL="from_hypertable builds its indexes by identity, names whole"
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
