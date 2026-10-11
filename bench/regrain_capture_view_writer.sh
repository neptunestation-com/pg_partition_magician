#!/usr/bin/env bash
# regrain_capture_view_writer.sh <container> <db> [install.sql]
#
# Run tests/294_regrain_capture_view_writer_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1073): the
# regrain capture trigger wrote its delta as the WRITER, and _regrain_capture_grant gives INSERT on the delta
# only to the grantees and owners of the parent and the source, so a role that writes the table through an
# ordinary view (checked as the view's owner, while the table's triggers fire as the session's role) got
# 42501 'permission denied for table <rel>_pgpm_regrain_delta' on every write into the regraining partition
# until the swap. The capture function now writes as its owner (pgpm._capture_definer). The file is the
# acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run against
# the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# SIX mutations are required to fail against it (bench/mutations/mutate.py), one per clause of the lever:
#   capture_definer_dropped               -- the function runs as the writer again. Parts A, B, D and E.
#   capture_definer_search_path_unpinned  -- definer, but its operators resolve through the writer's
#                                            search_path, so the writer's own `=` runs as the owner. Part B.
#   capture_definer_execute_owner_only    -- EXECUTE revoked from PUBLIC, so no role but the function's owner
#                                            can create a trigger with it (TimescaleDB's per-chunk CREATE
#                                            TRIGGER as a new owner). Part C.
#   capture_definer_not_rearmed           -- a tick never arms a capture minted before the fix. Part D.
#   capture_definer_owner_reach_unchecked -- definer even where the owner holds no USAGE on the delta's
#                                            schema, so every write into the source is refused. Part F.
#   capture_definer_reach_by_fn_schema    -- reach read from the function's schema, so a delta moved where
#                                            its owner cannot follow keeps the definer. Part G.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/294_regrain_capture_view_writer_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a view writer's writes into a regraining partition are captured" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a view writer's writes into a regraining partition are captured" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
