#!/usr/bin/env bash
# archive_remedy_encoded_bounds.sh <container> <db> [install.sql]
#
# Run tests/358_archive_remedy_encoded_bounds_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1371): the three
# skip_archive remedies (_archive_unheld_reason's two, _archive_left_reason's) spelled the ATTACH PARTITION an
# operator types over pgpm.part's native bounds, unencoded, so on a uuidv7 grid it was refused ('invalid input
# syntax for type uuid') and on a text_time grid its bounds held none of the table's rows. The file types each remedy
# out of its log row and shows it attaches the table back; this wrapper exists so the mutation has a guard the
# discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_remedy_bounds_unencoded  -- pgpm._attach_back_sql spells the native bounds, the pre-fix remedy. Parts U
#                                       and T.
#
# Runs on the plain core image (pgtap and pg_prove; no pg_cron). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/358_archive_remedy_encoded_bounds_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "each skip_archive ATTACH remedy attaches as typed" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "each skip_archive ATTACH remedy attaches as typed" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
