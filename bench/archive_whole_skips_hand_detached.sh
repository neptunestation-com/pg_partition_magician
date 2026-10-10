#!/usr/bin/env bash
# archive_whole_skips_hand_detached.sh <container> <db> [archive_partition_whole.sql]
#
# Run tests/313_archive_whole_skips_hand_detached_test.sql against an ARBITRARY copy of
# scripts/archive_partition_whole.sql, so that bench/discriminate.sh can show the file catches the defect its
# mutation puts back (issue #1159): the operator utility pgpm_archive_next_partition_whole chose its candidate
# on pgpm.part.attached, which an operator's own DETACH PARTITION never touches, so it handed a table detached
# by hand to the strategy (which, reading through the parent, found none of its rows) and recorded [lo, hi) as
# covered; once the table was attached back, retain() dropped rows nothing had archived. pgpm._archive_step has
# left such a table out since #705. The file is the acceptance test; this wrapper exists so the mutation has a
# guard the discriminate track can run against the mutant, in the shape of
# bench/archive_partition_whole_follows_step.sh. Nothing installs the script, so the third argument is the
# script's path, which the test file reads through its archive_whole_script psql variable; pgpm_core is always
# the tree's own.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   archive_whole_trusts_part_attached -- the candidate query's `not pgpm._part_detached_by_hand(...)` clause
#                                         removed, the pre-fix shape. Part A.
#
# A copy of the script that does not even load is not a catch: that is reported as a `fixture:` failure,
# which bench/discriminate.sh reads as a starved fixture rather than as discrimination.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, and TAP_GUARD_INSTALL the core install's, for a worktree mounted somewhere other
# than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; SCRIPT="${3:-/repo/scripts/archive_partition_whole.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/313_archive_whole_skips_hand_detached_test.sql}"
INSTALL="${TAP_GUARD_INSTALL:-/repo/pgpm_core/install.sql}"
LABEL="the whole-partition script skips a hand-detached table"
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
