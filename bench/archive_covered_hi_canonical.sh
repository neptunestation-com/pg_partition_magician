#!/usr/bin/env bash
# archive_covered_hi_canonical.sh <container> <db> [install.sql]
#
# Run tests/273_archive_covered_hi_canonical_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #977):
# _archive_step checked an archive_fn's covered_hi with a parse in the tick's session and then wrote the
# strategy's text into pgpm.archive_ledger.hi verbatim, so an offset-less value checked in a UTC tick as
# three hours short of the partition's hi read as past it from an America/New_York session, and retire()
# there dropped the partition with the rows the strategy was never handed. The file is the acceptance test;
# this wrapper exists so the mutation has a guard the discriminate track can run against the mutant, in the
# shape of bench/retain_recall_moved_parent.sh.
#
# The mutation it must fail against (bench/mutations/mutate.py):
#   archive_covered_hi_verbatim  -- the ledger row takes the strategy's covered_hi as written again, the
#                                   pre-fix shape. Parts A and B catch it (the ledger's hi is the
#                                   offset-less text, and retire() from New York drops the row 'late').
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/273_archive_covered_hi_canonical_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the archive ledger records the instant its check accepted" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the archive ledger records the instant its check accepted" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
