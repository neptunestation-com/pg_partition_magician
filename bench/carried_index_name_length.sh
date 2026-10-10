#!/usr/bin/env bash
# Run tests/143_carried_index_name_length_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that the file DISCRIMINATES. Its subject is a refusal, and a refusal is a negative
# ("transmute did not convert this table, and did not tell the operator to drop their own index"),
# equally satisfied by a harness that never presented the condition. The file pins its setup with
# liveness witnesses of its own (the auto-named index really is 63 bytes, <it>_pgpm really casts back to
# exactly it, the renamed index really is 58 bytes and really converts), but nothing re-checks that the
# refusal assertion would fail without the length check. Pointing the same file at a mutant does that.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_index_name_unchecked  -- the <index>_pgpm length refusal is removed, the pre-#592 shape
#                                      exactly: the 63-byte index reaches the #311 collision guard,
#                                      which finds its own name taken and calls it a leftover to drop
#
# Usage: carried_index_name_length.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
# CARRIED_INDEX_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${CARRIED_INDEX_TEST_FILE:-/repo/tests/143_carried_index_name_length_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised" -- a file
  # that dies early reports a bad plan and exits non-zero. What it cannot tell us apart from a real
  # failure is a run that never reached the database at all, and in THIS script that distinction
  # matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the defect",
  # so a harness broken enough to fail against everything would be reported as proving the mutation.
  # Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "no <index>_pgpm name is truncated or misread as a leftover" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "no <index>_pgpm name is truncated or misread as a leftover" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
