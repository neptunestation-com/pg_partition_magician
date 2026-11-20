#!/usr/bin/env bash
# archive_chunk_unshaped_key.sh <container> <db> [install.sql]
#
# Run tests/389_archive_chunk_unshaped_key_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #709, the archive
# step's bullet): pgpm._next_archive_chunk decoded the window's newest control value, the next distinct value past
# it, and the first row past a native unit, so a text_time key without the declared shape (string bounds admit
# one) at any of those three reads raised on every tick, the step logged skip_archive each time, and the aged
# partition was never covered nor retired. The file puts one such key at each read; this wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per read:
#   archive_chunk_decodes_window_newest   -- the window's newest value is decoded again.
#   archive_chunk_next_distinct_unshaped  -- the next-distinct read takes a key without the shape again.
#   archive_chunk_unit_next_unshaped      -- the read past a native unit takes a key without the shape again.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/389_archive_chunk_unshaped_key_test.sql}"
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
  # the invariant oracle (tests/formal/oracle.sql): the test file calls pgpm_formal.baseline()
  q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/formal/oracle.sql >/dev/null 2>&1
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a chunk never ends at a key it cannot decode" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a chunk never ends at a key it cannot decode" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
