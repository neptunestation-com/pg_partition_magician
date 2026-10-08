#!/usr/bin/env bash
# obtain_backoff_hole.sh <container> <db> [install.sql]
#
# Run tests/298_obtain_backoff_hole_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1078):
# maintain_obtain's back-off walk counted a step as coverage whenever an attached pgpm.part row overlapped
# it, so a cell dropped or detached by hand inside the frontier's cell or the ceil(obtain / 2) steps past it
# kept the back-off honoured after a lost lock race, and every write into the hole stayed refused for the
# back-off window. And the other way round: a hole obtain CANNOT build (its name held by a stranger, #710)
# must not bypass the back-off, or every tick queues another ACCESS EXCLUSIVE behind the contention for a
# cell obtain only logs. The file is the acceptance test; this wrapper exists so the mutations have a guard
# the discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   obtain_backoff_counts_hole         -- the walk's _cell_attached read as the bare row overlap, the
#                                         pre-fix judgement of a step. Parts A, C and D.
#   obtain_backoff_bypasses_held_name  -- the walk's _obtain_name dropped, so a held-name hole bypasses
#                                         the back-off. Part F.
#   obtain_backoff_walk_commits_forget -- the walk's writes (its _cell_attached forgets) committed rather
#                                         than rolled back, so a forget stands under a lost race. Part G.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/298_obtain_backoff_hole_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a hole in the lookahead bypasses the obtain back-off" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a hole in the lookahead bypasses the obtain back-off" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
