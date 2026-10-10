#!/usr/bin/env bash
# Run tests/timescale/db/40_from_hypertable_cutover_foreign_keys_test.sql against an ARBITRARY copy of
# pgpm_hypertable/install.sql, so bench/discriminate.sh can point it at a mutant (issue #840).
#
# THE DEFECT. Outgoing foreign keys reach the migrated table only through from_hypertable_copy, and the
# cutover's shape check (#738), the one place it compares the copy with the source, compared columns,
# defaults and CHECKs but not foreign keys. A key added to the hypertable between the copy and the cutover
# was dropped with the source (the migrated table accepted orphans), and a key dropped in that window came
# back. _from_hypertable_shape_diff now compares the outgoing keys by name and definition, so both shape
# checks (up front and under the lock) refuse. The file adds one key and drops the other in the window,
# and pins the refusal naming both by its message: a cutover that does not refuse dies at its first COMMIT
# inside throws_like with 2D000 and rolls back into the state a refusal leaves.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   hypertable_shape_ignores_foreign_keys -- the pre-#840 shape diff, without its three foreign-key arms.
#                                            The refusal assertion fails; the invariants and the remedy pass.
#
# Usage: hypertable_cutover_foreign_keys.sh <container> <db> [pgpm_hypertable/install.sql]
# Runs on the TIMESCALE track's container, which is why this mutation sits in MUTATION_TRACK=timescale.
# run_timescale also runs it against the unmutated module, so a harness that failed against everything
# would not read as discrimination. psql, not pg_prove: the fleet image has none, so the TAP is judged here
# exactly as run_timescale judges it.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
TEST_FILE=/repo/tests/timescale/db/40_from_hypertable_cutover_foreign_keys_test.sql
LABEL="the cutover refuses outgoing keys changed since the copy"
fail=0

q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@"; }

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
q -d postgres -q -c "create database $DB" >/dev/null 2>&1
q -d postgres -q -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened. The core goes in first and is
# never the mutated file; only pgpm_hypertable is.
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
  # A file that reached no assertion failed on its fixture, whatever stopped it, so its setup lines are
  # premises then and discriminate.sh's starved() does not read them as a catch (#1177).
  unreached=""; [ "$ran" -gt 0 ] || unreached="fixture: "
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "${unreached}the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ "$rc" != 0 ]; then
    printf 'FAIL  %-58s %s\n' "${unreached}psql ran the file to its end" "exit $rc"
    echo "$out" | grep -E 'FATAL:|connection' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ -z "$planned" ] || [ "$ran" != "$planned" ]; then
    printf 'FAIL  %-58s %s\n' "${unreached}the file ran every assertion it planned" "planned ${planned:-nothing}, $ran ran"
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
