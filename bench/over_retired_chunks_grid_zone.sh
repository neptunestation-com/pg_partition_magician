#!/usr/bin/env bash
# over_retired_chunks_grid_zone.sh <container> <db> [install.sql]
#
# Run tests/334_over_retired_chunks_grid_zone_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1264).
# pgpm._over_retired_chunks compared the bounds of the retired chunks with ::timestamptz in the CALLER's session,
# and a retired ledger row an older install wrote can carry a bound with no offset (a pre-#977 strategy's
# covered_hi, stored verbatim; no upgrade rewrites a retired row), so the same call held a partition from pg_cron's
# UTC session and not from an operator's Asia/Kolkata one. The file pins what the call returns, by partition and by
# chunk, from five sessions on four zones and three DateStyles, over a grid registered in Asia/Tokyo, each with a
# LIVENESS witness that the session's own parse would give another answer. The file is the acceptance test; this
# wrapper exists so the mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh. Each failed assertion is printed as its `not ok` line, which is what
# discriminate.sh's starved() reads, so a mutant that failed only a LIVENESS witness is not certified as a catch.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   over_retired_chunks_session_zone     -- the bounds are read in the caller's TimeZone again, the pre-fix
#                                           shape. Parts B to E.
#   native_bound_key_utc                 -- the plausible-but-wrong fix: a bound with no offset is read as UTC,
#                                           not on the grid's clock. Parts A to E (the grid is Asia/Tokyo's).
#   native_bound_key_session_datestyle   -- the parse is not pinned to ISO, MDY, so a DateStyle-shaped bound
#                                           reads by the caller's DateStyle. Parts C and E.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the
# container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/334_over_retired_chunks_grid_zone_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a retired chunk's bounds read the same from every session" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a retired chunk's bounds read the same from every session" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
