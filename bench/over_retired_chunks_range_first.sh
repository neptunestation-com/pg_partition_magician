#!/usr/bin/env bash
# over_retired_chunks_range_first.sh <container> <db> [install.sql]
#
# Run tests/317_over_retired_chunks_range_first_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1163).
# pgpm._over_retired_chunks, called twice by every tick with an archive_fn (_archive_step and retain()), read
# every retired pgpm.archive_ledger row of the parent, with a catalog probe per row, before filtering by range: a
# retired row is never discarded, so the cost of a call that holds nothing grew with the parent's whole archive
# history. The file counts the ledger tuples one call reads (pg_stat_get_xact_* inside one transaction, with the
# instrument's own liveness: a plain read of the retired rows moves it by their number) and pins what the call
# returns by identity, on an id parent and on a time parent whose bounds' text order is not their order. The
# file is the acceptance test; this wrapper exists so the mutation has a guard the discriminate track can run
# against the mutant, in the shape of bench/retain_recall_moved_parent.sh. Each failed assertion is printed as
# its `not ok` line, which is what discriminate.sh's starved() reads, so a mutant that failed only a LIVENESS
# witness is not certified as a catch.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   over_retired_chunks_reads_all -- the floor clause on the ledger read is gone, so the call reads every
#                                    retired row of the parent again (the pre-#1163 read); what it returns is
#                                    unchanged, and only the bounded-read assertions fail.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/317_over_retired_chunks_range_first_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a call reads only the retired chunks that can overlap" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a call reads only the retired chunks that can overlap" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
