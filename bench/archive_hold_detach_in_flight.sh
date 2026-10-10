#!/usr/bin/env bash
# archive_hold_detach_in_flight.sh <container> <db> [install.sql | archive_partition_whole.sql]
#
# Run tests/325_archive_hold_detach_in_flight_test.sql against an ARBITRARY copy of pgpm_core/install.sql or of
# scripts/archive_partition_whole.sql, so that bench/discriminate.sh can show the file catches the defects its
# mutations put back (issue #1159, the per-PR verification's V-01): both archive paths asked
# pgpm._part_detached_by_hand only in their candidate query and locked nothing before reading the candidate, so
# an operator's DETACH PARTITION in flight when the query ran was waited out by the first read instead of being
# seen, a strategy reading through the parent found none of the table's rows, and [lo, hi) was recorded as
# covered; attached back, retain() dropped rows nothing had archived. The file drives the race through dblink
# (a detach session holding its locks until told, the call run asynchronously, its lock wait witnessed in
# pg_locks before the detach commits), so the order is set by held locks, not by sleeps. The file is the
# acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run against
# the mutant, in the shape of bench/archive_whole_skips_hand_detached.sh.
#
# The third argument is either module the mutations touch: a copy of the script (recognised by the function
# it defines) is loaded in place of the tree's, with the tree's pgpm_core; anything else is installed as
# pgpm_core, with the tree's script.
#
# FOUR mutations are required to fail against it (bench/mutations/mutate.py):
#   archive_hold_unlocked             -- pgpm._archive_hold_partition asks again without taking the parent's
#                                        lock, so it asks while the detach is still uncommitted. Parts A, B, D.
#   archive_hold_recheck_by_snapshot  -- it asks pgpm._part_detached_by_hand, under the statement's snapshot,
#                                        which under REPEATABLE READ predates the detach's commit. Part D.
#   archive_step_hold_skipped         -- pgpm._archive_step reads its candidate without the hold. Part B.
#   archive_whole_hold_skipped        -- the script reads its candidate without the hold. Parts A and D.
#
# A copy that does not even load is not a catch: that is reported as a `fixture:` failure, which
# bench/discriminate.sh reads as a starved fixture rather than as discrimination.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, TAP_GUARD_INSTALL the core install's and TAP_GUARD_SCRIPT the script's, for a
# worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; FILE="${3:-}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/325_archive_hold_detach_in_flight_test.sql}"
INSTALL="${TAP_GUARD_INSTALL:-/repo/pgpm_core/install.sql}"
SCRIPT="${TAP_GUARD_SCRIPT:-/repo/scripts/archive_partition_whole.sql}"
LABEL="both archive paths wait out a detach in flight"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

if [ -n "$FILE" ]; then
  if docker exec "$C" grep -q 'function pgpm_archive_next_partition_whole' "$FILE"; then SCRIPT="$FILE"; else INSTALL="$FILE"; fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: pgpm_core installed" "$INSTALL"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$SCRIPT" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: the script under test loaded" "$SCRIPT"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB -S archive_whole_script=$SCRIPT $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
