#!/usr/bin/env bash
# retain_unanchored_marks.sh <container> <db> [install.sql]
#
# Run tests/362_retain_unanchored_marks_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issues #1429 and #1430): the
# install pass judged a v0.5.0 row's unanchored mark by its name, so a squatter under the name of a renamed
# retirement was disowned as it and its remedy spelled an ATTACH of the squatter; and the recall skipped a v0.4.0
# mark with no oid and nothing under its name on every tick, logging and counting nothing. The file is the
# acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run against the
# mutant, in the shape of bench/retain_recall_renamed_detached.sh.
#
# FIVE mutations are required to fail against it (bench/mutations/mutate.py):
#   install_pass_unanchored_by_name   -- the pre-#1429 shape: the pass judges the name alone. Part A.
#   install_pass_v040_unjudged        -- a mark with no oid is never judged by the name. Part E.
#   install_pass_namesake_unjudged    -- a mark on the relation under the name, or a namesake, is skipped. Parts B, C.
#   recall_v040_skipped_silently      -- the pre-#1430 shape: the v0.4.0 mark is skipped, nothing logged. Part D.
#   recall_v040_job_left_armed        -- the refusal leaves the job armed with the detach. Part D.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/362_retain_unanchored_marks_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "an unanchored mark is judged by what it marks, never skipped" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "an unanchored mark is judged by what it marks, never skipped" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
