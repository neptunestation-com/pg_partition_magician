#!/usr/bin/env bash
# Run tests/archive/db/22_huffman_lock_entries_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 22 is a plain pgTAP file and the archive track already runs it, so
# on correct code this script adds nothing. What it adds is the standing proof that the file
# DISCRIMINATES. Its defect assertions are zeros ("N encodes in one transaction add no lock-table
# entry"), and a zero is what an instrument that sees nothing reports too. The file pins that with a
# control (a temp table created and dropped per call DOES leave entries it can count) and with
# witnesses that the calls built real codes on the dynamic-Huffman path, but nothing re-checks that
# the zeros themselves would move if the per-call temp table came back. Pointing the same file at the
# mutant checks that on every CI run, instead of once by hand in a commit message.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_huffman_temp_table -- archive._pq_huffman_lengths builds its merge queue in a temp table
#                                 created and dropped on every call again, the pre-#587 shape
#                                 exactly: ~15 lock-table entries per call held to transaction end,
#                                 three calls per GZIP encode, so one maintain() tick that archives
#                                 enough compressed chunks exhausts the cluster's shared lock table
#
# Usage: archive_huffman_lock_entries.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) for the module to install; it never touches
# MinIO. PGPM_HUFF_TEST_FILE overrides the test file's path inside the container.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
TEST_FILE="${PGPM_HUFF_TEST_FILE:-/repo/tests/archive/db/22_huffman_lock_entries_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the archive fixtures installed" "no"
  fail=1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "no"
  fail=1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ARCHIVE_INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the archive module under test installed" "$ARCHIVE_INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^(not ok [0-9]+ -|#  +have:)' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell apart from a real failure is a run that never reached the database at all, and
  # discriminate.sh reads a non-zero exit as "the guard caught the defect", so a harness broken enough
  # to fail against everything would be reported as proving the mutation. Hence the count, asserted
  # separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "GZIP encodes take no lock-table entry per call" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "GZIP encodes take no lock-table entry per call" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
