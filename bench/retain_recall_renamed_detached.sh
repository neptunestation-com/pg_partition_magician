#!/usr/bin/env bash
# retain_recall_renamed_detached.sh <container> <db> [install.sql]
#
# Run tests/361_retain_recall_renamed_detached_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1424):
# _retain_recall resolved a retirement only by name, so once pgpm's detach had taken the partition out of the
# parent and the operator renamed the detached table, the recall logged fail_retain_identity on every tick and
# kept the mark, where a hand rename of a detached retirement hands the table to the operator (released,
# retain_disown, never re-attached). The file is the acceptance test; this wrapper exists so the mutations have a
# guard the discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# EIGHT mutations are required to fail against it (bench/mutations/mutate.py), one per clause of the release:
#   recall_rename_not_released         -- the pre-fix shape: no release at all. Parts A and B.
#   recall_release_attached            -- a renamed partition still attached to the parent is released. Part D.
#   recall_release_gone                -- a recorded relation that no longer exists is "released". Part C.
#   recall_release_anchors_disagree    -- the mark's relation is released when the row's anchor names another. Part E.
#   recall_release_unqualified         -- the method names the new name through the search path. Part A.
#   recall_release_any_parent          -- a table attached to the operator's own parent is refused. Part G.
#   recall_release_name_unchanged      -- a table only moved to another schema is released. Part H.
#   recall_release_remedy_no_rename    -- the remedy ATTACHes without renaming the table back. Part A.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/361_retain_recall_renamed_detached_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a renamed detached retirement is released, not re-attached" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a renamed detached retirement is released, not re-attached" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
