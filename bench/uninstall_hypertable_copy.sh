#!/usr/bin/env bash
# Run tests/timescale/db/48_uninstall_drops_abandoned_copy_test.sql against an ARBITRARY copy of
# pgpm_core/uninstall.sql or of pgpm_hypertable/install.sql, so bench/discriminate.sh can point it at a mutant
# (issue #773, its last bullet).
#
# Same shape and same reason as bench/uninstall_hypertable_capture.sh: the copy this file asserts uninstall
# removes exists only where from_hypertable_copy can run, which needs a real TimescaleDB. The file's
# load-bearing assertions are negatives ("the abandoned copy and its key index are gone"), and a negative is
# equally satisfied by a copy that never ran or an uninstall that never did. The file pins both with
# liveness witnesses (each copy holds its rows, its key index and its replayed foreign key, which blocks a
# delete, before; the pgpm schema is gone after), and its survivors (an operator's look-alike with the
# module's name and no record; a copy whose hypertable is gone; a migrated table) are positives that a sweep
# by name, a sweep that ignores whose rows a copy holds, or a swap that leaves its record behind, break.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   uninstall_keeps_hypertable_copy       -- the sweep is gone: the pre-#773 script, which left the copy and
#                                            its key index behind (uninstall.sql)
#   uninstall_hypertable_copy_by_name     -- the sweep keys on the _pgpm_dest name instead of the copy's
#                                            record, so it drops the operator's look-alike too (uninstall.sql)
#   uninstall_drops_orphaned_copy         -- the sweep drops a copy whose hypertable is gone, the only home
#                                            of its rows (uninstall.sql)
#   hypertable_swap_keeps_copy_record     -- the swap sets the migrated table's comment only when the source
#                                            had one, so the copy's record survives onto it
#                                            (pgpm_hypertable/install.sql)
#
# Usage: uninstall_hypertable_copy.sh <container> <db> [mutant]
# The third argument is a path inside the container. A copy of the hypertable module (it defines
# pgpm.from_hypertable_copy) is installed in place of pgpm_hypertable/install.sql; anything else is the
# UNINSTALL script under test, which the file reads with psql's \ir. Runs on the TIMESCALE track's
# container, which is why these mutations sit in MUTATION_TRACK=timescale; run_timescale also runs it
# against the real install, so a harness that fails against everything cannot read as discriminating.
#
# psql, not pg_prove: the supabase/postgres image has no pg_prove, so TAP is parsed out of psql -tAq here
# exactly as run_timescale does, including the ERROR: check and the plan check (#601).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUTANT="${3:-}"
UNINSTALL=/repo/pgpm_core/uninstall.sql; HT=/repo/pgpm_hypertable/install.sql
TEST_FILE=/repo/tests/timescale/db/48_uninstall_drops_abandoned_copy_test.sql
LABEL="uninstall drops abandoned copies and only those"
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
  elif docker exec "$C" grep -q '^create or replace procedure pgpm.from_hypertable_copy(' "$MUTANT"; then
    HT="$MUTANT"
  else
    UNINSTALL="$MUTANT"
  fi
fi

# An install that fails is NOT a pass: say which happened.
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the hypertable module under test installed" "$HT"
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
