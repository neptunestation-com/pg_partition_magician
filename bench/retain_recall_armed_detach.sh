#!/usr/bin/env bash
# retain_recall_armed_detach.sh <container> <db> [install.sql]
#
# Run tests/194_retain_recall_armed_detach_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #724):
# loosening retention (set_retain, or an id frontier moving back) never recalled a referenced partition's
# dispatched concurrent detach, so pg_cron detached a partition the policy now keeps and nothing put it
# back, and its rows vanished from every read of the parent with nothing logged. The file is the
# acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run
# against the mutant, in the shape of bench/retire_detached_unreferenced.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   retain_recall_never             -- nothing takes a retirement back, the pre-fix shape. Parts A, B, C.
#   retain_recall_clears_at_once    -- the recall clears the retiring marker in the same call, so a detach
#                                      pg_cron had already picked up lands on a partition that looks
#                                      detached by an operator and is never re-attached. Part B.
#   retain_recall_ignores_horizon   -- every retirement is taken back, reached or not, so a loosening that
#                                      still reaches the partition stalls its retirement. Part D.
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "loosened retention takes back an armed retirement" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "loosened retention takes back an armed retirement" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
