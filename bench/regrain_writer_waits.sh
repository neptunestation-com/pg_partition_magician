#!/usr/bin/env bash
# Run tests/149_regrain_writer_waits_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its contract is a negative -- "the synchronous regrain() and a write
# issued while it runs do not deadlock" -- and a negative is equally satisfied by a run in which the
# write arrived after the swap had committed, or before regrain() took any lock at all. The file pins its
# setup with liveness witnesses (regrain() was seen holding the capture trigger's lock on the source
# while it copied, and the write was seen waiting on a lock of that table while regrain() still ran), but
# nothing re-checks that those witnesses would still let the file fail if the fix they guard were
# removed. Pointing the same file at a mutant is what checks that, every CI run, instead of once by hand
# in a commit message (#580).
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_sync_no_parent_lock  -- regrain() no longer takes SHARE on the parent before its first step,
#                                   which is pre-#580 behaviour exactly: the write takes ROW EXCLUSIVE on
#                                   the parent, queues on the source behind the capture trigger's SHARE
#                                   ROW EXCLUSIVE, and the swap's DETACH waits on it in turn, so
#                                   PostgreSQL aborts one side with 40P01 and tests/149 sees it
#
# Usage: regrain_writer_waits.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has).
# REGRAIN_WRITER_WAITS_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${REGRAIN_WRITER_WAITS_TEST_FILE:-/repo/tests/149_regrain_writer_waits_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for a
# reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it cannot
  # tell us apart from a real failure is a run that never reached the database at all, and here that
  # matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the defect", so a
  # harness broken enough to fail against everything would be reported as proving the mutation. Hence the
  # count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "regrain() and a concurrent write do not deadlock" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "regrain() and a concurrent write do not deadlock" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
