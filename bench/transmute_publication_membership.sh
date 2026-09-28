#!/usr/bin/env bash
# Run tests/132_transmute_publication_membership_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant (issue #566).
#
# WHY A WRAPPER EXISTS AT ALL. The file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so on correct code this adds nothing. What it adds is the standing proof
# that the file DISCRIMINATES. The defect it exists for is an absence (the new parent is in no
# publication, so rows past the monolith are silently not replicated), and an absence is equally
# satisfied by a run in which the table was never published at all. The file pins its setup with
# witnesses of its own (the table really is in two publications, one with a row filter; the new row
# really was routed past the monolith), and pointing it at a mutant is what shows, every CI run, that
# its membership assertions fail when the carry-over is gone.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_publication_not_carried -- the cutover never adds the new parent to the table's
#                                        publications, which is pre-#566 behaviour exactly: the
#                                        membership stays on the monolith's oid and every forward
#                                        partition is in no publication
#
# Usage: transmute_publication_membership.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
# PUBLICATION_MEMBERSHIP_TEST_FILE overrides the test file's path inside the container, for running
# from a worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${PUBLICATION_MEMBERSHIP_TEST_FILE:-/repo/tests/132_transmute_publication_membership_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the parent takes the table's place in its publications" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the parent takes the table's place in its publications" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
