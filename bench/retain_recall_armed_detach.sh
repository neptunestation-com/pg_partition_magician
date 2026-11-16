#!/usr/bin/env bash
# retain_recall_armed_detach.sh <container> <db> [install.sql]
#
# Run tests/194_retain_recall_armed_detach_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defects its mutations put back (issues #724, #1438):
# loosening retention (set_retain, or an id frontier moving back) after a referenced partition's concurrent detach
# was dispatched left its rows out of the parent with nothing in pgpm saying so, first because nothing looked at
# the armed command again (#724), then because #724's recall idled the job and re-attached the partition in a
# transaction a pg_cron run already carrying the detach could outlast (#1438). The file is the acceptance test; this
# wrapper exists so the mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/retire_detached_unreferenced.sh.
#
# SIX mutations are required to fail against it (bench/mutations/mutate.py):
#   retain_recall_never             -- nothing settles a retirement retention no longer reaches, the pre-#724
#                                      shape. Parts A, B, C and F.
#   retain_recall_ignores_horizon   -- every retirement is settled, reached or not, so a reached partition's
#                                      landed detach is released rather than dropped. Part D.
#   recall_idles_armed_detach       -- #724's recall of an armed detach: the job idled in the loosening's
#                                      transaction, the mark cleared on the next tick, and a run that had already
#                                      read the command strands the rows. Parts A and F.
#   recall_reattaches_landed_detach -- #1438's pre-fix shape: the landed partition re-attached in the idle's
#                                      transaction, and taken out again by a late run. Part B.
#   recall_release_uncounted        -- the release logged under an action status() does not count. Parts A, C, F.
#   recall_release_leaves_job_armed -- the release leaves the job holding the detach, which undoes the operator's
#                                      ATTACH. Part A.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/194_retain_recall_armed_detach_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "loosened retention never strands a retirement unrecorded" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "loosened retention never strands a retirement unrecorded" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
