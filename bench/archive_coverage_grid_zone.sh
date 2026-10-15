#!/usr/bin/env bash
# archive_coverage_grid_zone.sh <container> <db> [install.sql | archive_partition_whole.sql]
#
# Run tests/346_archive_coverage_grid_zone_test.sql against an ARBITRARY copy of pgpm_core/install.sql, or of
# scripts/archive_partition_whole.sql, so that bench/discriminate.sh can show the file catches the defect its
# mutations put back (issue #1336, bullet 8). Every reader of a stored archive-ledger bound but
# _over_retired_chunks (#1264) cast it in the CALLER's session, and a ledger row an older install wrote can carry a
# hi with no offset (a pre-#977 strategy's covered_hi, stored verbatim; no upgrade rewrites a row): read in a zone
# west of the grid's, _archive_fully_covered opened retire()'s drop gate and retain() from America/New_York dropped
# a partly archived partition with rows no strategy was handed. The file pins each reader's answer from sessions on
# zones either side of the grid's (Asia/Tokyo), each with a LIVENESS witness that the session's own parse gives the
# other answer. The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate
# track can run against the mutant, in the shape of bench/over_retired_chunks_grid_zone.sh. Each failed assertion is
# printed as its `not ok` line, which is what discriminate.sh's starved() reads, so a mutant that failed only a
# LIVENESS witness is not certified as a catch.
#
# The third argument is told apart by what it defines: a copy of the whole-partition script (it defines
# pgpm_archive_next_partition_whole) is handed to the test file as its archive_whole_script psql variable over the
# tree's core; anything else is the core install, with the tree's script.
#
# SIX mutations are required to fail against it (bench/mutations/mutate.py):
#   archive_fully_covered_session_zone   -- the coverage watermark read in the caller's zone. Parts A and F.
#   next_archive_chunk_session_zone      -- the resume watermark read in the caller's zone. Part B.
#   contradicted_coverage_session_zone   -- a 0-row chunk's hi encoded in the caller's zone. Part C.
#   archive_orphan_discard_session_zone  -- the orphan discard's overlap judged in the caller's zone. Part D.
#   mark_retired_chunks_session_zone     -- the upgrade's #1141 pass reads in the install session's zone. Part E.
#   archive_whole_resume_session_zone    -- the script's resume watermark read in the caller's zone. Part F.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the
# container, and TAP_GUARD_INSTALL the core install's and TAP_GUARD_SCRIPT the script's, for a worktree mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUTANT="${3:-}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/346_archive_coverage_grid_zone_test.sql}"
INSTALL="${TAP_GUARD_INSTALL:-/repo/pgpm_core/install.sql}"
SCRIPT="${TAP_GUARD_SCRIPT:-/repo/scripts/archive_partition_whole.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

if [ -n "$MUTANT" ]; then
  if docker exec "$C" grep -q 'function pgpm_archive_next_partition_whole' "$MUTANT"; then SCRIPT="$MUTANT"
  else INSTALL="$MUTANT"; fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install, or a script that will not load, is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: the module under test installed" "$INSTALL"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "every ledger bound reads the same from every session" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "every ledger bound reads the same from every session" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
