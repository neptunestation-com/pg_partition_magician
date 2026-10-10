#!/usr/bin/env bash
# Run tests/timescale/db/54_uninstall_drops_renamed_scratch_test.sql against an ARBITRARY copy of
# pgpm_core/uninstall.sql, so bench/discriminate.sh can point it at a mutant (issue #985).
#
# Same shape and same reason as bench/uninstall_hypertable_copy.sh: the copy, delta and capture trigger this
# file asserts uninstall removes exist only where from_hypertable_copy can run, which needs a real TimescaleDB.
# The file's load-bearing assertions are negatives ("the renamed copy, delta, function and the trigger on the
# hypertable and every chunk are gone"), and a negative is equally satisfied by a copy that never ran or an
# uninstall that never did. The file pins both with liveness witnesses (each renamed object is recorded and
# still carries the copy's comment, the trigger sits on the hypertable and its chunks and logged a write; the
# pgpm schema is gone after), and its survivor (the operator's table under the copy's old name) is a positive
# that a sweep by name breaks.
#
# The mutation it is required to fail against (bench/mutations/mutate.py), of uninstall.sql:
#   uninstall_scratch_record_skips_capture_fn -- the record sweep takes the copy and the delta by oid but leaves
#                                                the capture function to the comment sweep, which derives it
#                                                from the delta's name, so a renamed delta's function and its
#                                                trigger on the live hypertable survive
#
# Usage: uninstall_hypertable_scratch_by_record.sh <container> <db> [uninstall.sql]
# The third argument is the UNINSTALL script under test, a path inside the container, which the file reads with
# psql's \ir. Runs on the TIMESCALE track's container, which is why the mutation sits in MUTATION_TRACK=timescale;
# run_timescale also runs it against the real install, so a harness that fails against everything cannot read as
# discriminating.
#
# psql, not pg_prove: the supabase/postgres image has no pg_prove, so TAP is parsed out of psql -tAq here
# exactly as run_timescale does, including the ERROR: check and the plan check (#601).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUTANT="${3:-}"
UNINSTALL=/repo/pgpm_core/uninstall.sql
TEST_FILE=/repo/tests/timescale/db/54_uninstall_drops_renamed_scratch_test.sql
LABEL="uninstall drops renamed recorded scratch by oid"
fail=0

q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@"; }

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
q -d postgres -q -c "create database $DB" >/dev/null 2>&1
q -d postgres -q -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant path that is not there must not read as the guard having caught the defect.
if [ -n "$MUTANT" ]; then
  if ! docker exec "$C" test -r "$MUTANT"; then
    printf 'FAIL  %-58s %s\n' "the mutant under test exists" "$MUTANT"
    fail=1
  else
    UNINSTALL="$MUTANT"
  fi
fi

# An install that fails is NOT a pass: say which happened.
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/pgpm_hypertable/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the hypertable module installed" "/repo/pgpm_hypertable/install.sql"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the timescale fixtures loaded" "tests/timescale/fixtures.sql"
  fail=1
fi

if [ "$fail" = 0 ]; then
  # >>> pgTAP verdict: the same in every timescale wrapper; bench/wrapper_tap_verdicts.sh evaluates it.
  out=$(q -d "$DB" -tAq -v "uninstall=$UNINSTALL" -f "$TEST_FILE" 2>&1); rc=$?
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
