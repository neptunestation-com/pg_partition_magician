#!/usr/bin/env bash
# transmute_reap_reread.sh <container> <db> [install.sql]
#
# Run tests/320_transmute_reap_rereads_claim_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1166):
# _transmute_reap judged each claim by the row its FOR cursor read when the sweep began, so a conversion an
# operator's re-run took over while the sweep waited on another table (the documented resume) was reaped as
# abandoned: its validated bound dropped, its claim deleted, its cutover failed. The fix re-reads the claim
# FOR UPDATE under the table's ACCESS EXCLUSIVE and leaves one that is gone or whose owner is alive. The file
# is the acceptance test, and its dblink sessions (a reader, a gate, the sweep, the re-run transmute) are
# the concurrent sessions the contract needs; this wrapper exists so the mutation has a guard the
# discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_reap_reread_ignores_owner -- the re-read under the lock keeps only its "gone" test and drops
#                                          the liveness test of the owner it reads, so a claim taken over
#                                          while the sweep waited is reaped as if still abandoned.
#
# Runs on the plain core image (pgtap, dblink and pg_prove; the test needs no pg_cron). TAP_GUARD_TEST_FILE
# overrides the test file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/320_transmute_reap_rereads_claim_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the reaper leaves a claim taken over while it waited" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the reaper leaves a claim taken over while it waited" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
