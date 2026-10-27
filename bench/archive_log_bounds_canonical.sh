#!/usr/bin/env bash
# archive_log_bounds_canonical.sh <container> <db> [install.sql]
#
# Run tests/357_archive_log_bounds_canonical_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1370): the archive step's
# archive_chunk_retired row (pgpm._mark_gone_chunks) and its #511 orphan discard's archive_coverage_reset row logged
# the range they aggregate with a bare ::text of min(lo::timestamptz) and max(hi::timestamptz), so the session's
# DateStyle and zone leaked into the stored bounds: under 'SQL, DMY' in Asia/Kolkata they read
# '01/12/2026 05:30:00 IST', which names no instant and reads back elsewhere as 12 January or not at all. This wrapper
# exists so the mutation has a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_log_bounds_session_render  -- pgpm._typed_text renders without its DateStyle pin, in the calling
#                                         session's style again, the pre-fix rendering. Parts A and B.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the
# container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/357_archive_log_bounds_canonical_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the archive step logs its ranges as canonical bounds" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the archive step logs its ranges as canonical bounds" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
