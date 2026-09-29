#!/usr/bin/env bash
# untransmute_monolith_identity.sh <container> <db> [install.sql]
#
# Run tests/177_untransmute_monolith_identity_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back: untransmute
# took the monolith to be the attached partition with the smallest lo, so once retention had retired the
# original table (or a regrain's swap had replaced it) a forward partition or a fine child holding every
# remaining row was handed back under the table's name as the restored original, instead of the refusal the
# one-way door promises (issue #672).
# The file is the acceptance test; this wrapper exists so the mutation has a guard the discriminate track
# can run against the mutant, in the shape of bench/retire_straddle.sh. The file's own LIVENESS witnesses
# (the original is gone, the stand-in is the smallest-lo partition and holds every remaining row) are what
# keep a green run from being a refusal the old door would have given anyway.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   untransmute_monolith_by_position -- the monolith looked up by smallest lo again, not by recorded oid
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/177_untransmute_monolith_identity_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "untransmute refuses once the recorded monolith is gone" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "untransmute refuses once the recorded monolith is gone" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
