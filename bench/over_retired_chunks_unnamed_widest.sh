#!/usr/bin/env bash
# over_retired_chunks_unnamed_widest.sh <container> <db> [install.sql]
#
# Run tests/347_over_retired_chunks_unnamed_widest_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1336, the sibling of
# bullet 8). A retired pgpm.archive_ledger row an older install wrote can carry a bound that names no instant by
# itself (before #977 a strategy's covered_hi was stored as written, checked in a session whose zone nothing
# recorded). pgpm._over_retired_chunks read it on the grid's clock (#1264), so a hi a session west of the grid wrote
# read below its own lo, a partition an operator re-created over the chunk was not held, and the archive step PUT it
# over the retired chunk's object, the only copy of the dropped rows. The file pins which partitions are held, by
# name and by chunk, from four sessions (each with a LIVENESS witness that its own parse gives another answer), that
# the archive step, scripts/archive_partition_whole.sql and retain() leave them alone and no PUT lands over a retired
# object, and the remedy the skip row names, typed. The file is the acceptance test; this wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/over_retired_chunks_grid_zone.sh. Each failed assertion is printed as its `not ok` line, which is what
# discriminate.sh's starved() reads, so a mutant that failed only a LIVENESS witness is not certified as a catch.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   over_retired_chunks_unnamed_grid_clock   -- such a bound is read on the grid's clock again (#1264's rule).
#                                               Parts A to G.
#   over_retired_chunks_unnamed_session_zone -- the retired rows are read in the caller's TimeZone again (the
#                                               pre-#1264 shape). Parts A to G.
#   native_bound_reach_unparsed_raises       -- a bound no DateStyle parses raises out of the call again, and so
#                                               out of every archive step and retain() (#1351's P1-02). Part G.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the
# container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/347_over_retired_chunks_unnamed_widest_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a retired chunk's unnamed bound holds at its widest" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a retired chunk's unnamed bound holds at its widest" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
