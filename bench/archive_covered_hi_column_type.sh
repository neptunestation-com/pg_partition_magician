#!/usr/bin/env bash
# archive_covered_hi_column_type.sh <container> <db> [install.sql]
#
# Run tests/292_archive_covered_hi_column_type_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1071):
# pgpm._archive_contract_breach judged an id grid's covered_hi as numeric and never as the control column's
# own type, and the ledger stored it at the strategy's own scale, so a resumable strategy returning
# (lo + hi) / 2 on a bigint key ('15.0000000000000000', '22.5000000000000000') was recorded, and every later
# tick's _next_archive_chunk compared the column with that literal and raised 22P02 (skip_archive): the
# partition was never archived further and never retired, and a corrected strategy could not recover it. The
# file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track can
# run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   archive_covered_hi_scale_kept           -- the ledger records an id value at the strategy's scale again.
#                                              Parts A, B and C.
#   archive_contract_column_type_unchecked  -- the contract check's comparison after the round trip through
#                                              the column's type removed. Parts A and B.
#
# Runs on the plain core image (pgtap and pg_prove). The test file also loads scripts/archive_partition_whole.sql
# (part B), the tree's own copy. TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for
# a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/292_archive_covered_hi_column_type_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: pgpm_core installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the archive contract holds covered_hi to the column's type" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the archive contract holds covered_hi to the column's type" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
