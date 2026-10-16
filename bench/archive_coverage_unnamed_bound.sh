#!/usr/bin/env bash
# archive_coverage_unnamed_bound.sh <container> <db> [install.sql | archive_partition_whole.sql]
#
# Run tests/346_archive_coverage_unnamed_bound_test.sql against an ARBITRARY copy of pgpm_core/install.sql, or of
# scripts/archive_partition_whole.sql, so that bench/discriminate.sh can show the file catches the defect its
# mutations put back (issue #1336, bullet 8). Before #977 the archive step checked a strategy's covered_hi in
# whatever session ran it and stored the text as written; one with no offset names a different instant in every zone,
# and the zone that checked it was recorded nowhere. _archive_fully_covered read such a live hi in the CALLER's zone,
# so retain() from a session west of the writer's dropped a partly archived partition with rows no strategy was
# handed; reading it on the grid's clock instead drops it from the grid's own zone when the writer sat east of it.
# The file holds that such coverage opens no drop gate from any session (written as UTC, from Asia/Tokyo and from
# America/New_York, each attacked from a session whose own parse reads it past the partition's hi, with a LIVENESS
# witness of that), that the archive step and the whole-partition script discard it and re-archive from lo, and the
# orphan discard's and the upgrade's handling. The file is the acceptance test; this wrapper exists so the mutations
# have a guard the discriminate track can run against the mutant, in the shape of
# bench/over_retired_chunks_grid_zone.sh. Each failed assertion is printed as its `not ok` line, which is what
# discriminate.sh's starved() reads, so a mutant that failed only a LIVENESS witness is not certified as a catch.
#
# The third argument is told apart by what it defines: a copy of the whole-partition script (it defines
# pgpm_archive_next_partition_whole) is handed to the test file as its archive_whole_script psql variable over the
# tree's core; anything else is the core install, with the tree's script.
#
# EIGHT mutations are required to fail against it (bench/mutations/mutate.py):
#   archive_fully_covered_unnamed_counted -- the gate counts such a hi, read in the caller's zone. Parts A to C.
#   archive_fully_covered_grid_zone       -- the gate reads it on the grid's clock (PR #1351's first head). Part B.
#   next_archive_chunk_unnamed_resumed    -- the archive step resumes from it. Part D.
#   archive_whole_unnamed_resumed         -- the script resumes from it. Part G.
#   archive_orphan_discard_unnamed_kept   -- the orphan discard keeps an orphan it cannot place. Part E.
#   mark_retired_chunks_unnamed_placed    -- the upgrade places a chunk by such a hi, in its session's zone. Part F.
#   mark_retired_chunks_unplaced_live_marked -- the upgrade marks a live partition's unplaceable chunk on any later
#                                           drop. Parts F and D.
#   mark_gone_chunks_casts_unnamed        -- _mark_gone_chunks casts a pre-#500 bound for its log row and raises. Part F.
# next_archive_chunk_unnamed_resumed restores a wedge rather than the data loss: with the gate still refusing, a
# resume from the unnamed watermark leaves the partition uncovered for good, which part D's remedy checks catch.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the
# container, and TAP_GUARD_INSTALL the core install's and TAP_GUARD_SCRIPT the script's, for a worktree mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUTANT="${3:-}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/346_archive_coverage_unnamed_bound_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "coverage that names no instant opens no drop gate" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "coverage that names no instant opens no drop gate" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
