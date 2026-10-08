#!/usr/bin/env bash
# archive_partition_whole_follows_step.sh <container> <db> [archive_partition_whole.sql]
#
# Run tests/289_archive_partition_whole_follows_step_test.sql against an ARBITRARY copy of
# scripts/archive_partition_whole.sql, so that bench/discriminate.sh can show the file catches the defects its
# mutations put back (issue #1054, bullets 1 to 3): the operator utility pgpm_archive_next_partition_whole
# picked, resumed and resolved a partition differently from pgpm._archive_step. It ordered its candidates by
# pgpm.part.lo as text, so [1000, 1100) went ahead of the older [200, 300); it rendered its resume watermark
# in the caller's DateStyle and wrote that text as a ledger lo, which _archive_step's #511 discard query then
# failed to parse on every tick once the partition was retired; and it looked the partition up in the
# parent's schema, so after the parent moved it refused the intact partition it had recorded. The file is
# the acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run
# against the mutant, in the shape of bench/archive_partition_whole_contract.sh. Nothing installs the script,
# so the third argument is the script's path, which the test file reads through its archive_whole_script
# psql variable; pgpm_core is always the tree's own.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   archive_whole_order_by_text           -- candidates ordered by pgpm.part.lo as text again. Part A.
#   archive_whole_resume_session_render   -- the resume watermark rendered by a bare ::text in the caller's
#                                            DateStyle again. Part B.
#   archive_whole_parent_schema           -- the partition looked up in the parent's schema again, not
#                                            through pgpm._child_nsp. Parts C and D.
#
# A copy of the script that does not even load is not a catch: that is reported as a `fixture:` failure,
# which bench/discriminate.sh reads as a starved fixture rather than as discrimination.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, and TAP_GUARD_INSTALL the core install's, for a worktree mounted somewhere other
# than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; SCRIPT="${3:-/repo/scripts/archive_partition_whole.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/289_archive_partition_whole_follows_step_test.sql}"
INSTALL="${TAP_GUARD_INSTALL:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the whole-partition script follows _archive_step" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the whole-partition script follows _archive_step" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
