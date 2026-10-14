#!/usr/bin/env bash
# retain_disown_remedy.sh <container> <db> [install.sql]
#
# Run tests/339_retain_disown_remedy_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1272): the remedy a
# retain_disown row logs said to drop the disowned table by hand and left out its pgpm.part row, which then
# stayed attached and anchored to a relation that no longer exists, so every later retire() and retain() refused
# it as fail_retain_identity and status().retain_drop_failures climbed for good. The file types the remedy out of
# the log row and shows retention runs clean after it; this wrapper exists so the mutation has a guard the
# discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   retain_disown_remedy_keeps_row        -- pgpm._disown_retirement's remedy names the DROP and not the DELETE
#                                            of the row, the pre-fix remedy. Parts A and B.
#   retain_disown_remedy_drops_unreached  -- the drop remedy is written whatever the partition's state, so the row
#                                            _retain_recall logs for a partition the lengthened policy keeps spells
#                                            a DROP that loses its rows. Part C.
#
# Runs on the plain core image (pgtap and pg_prove; no pg_cron, which is what makes retire()'s dispatch fail).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted somewhere
# other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/339_retain_disown_remedy_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "retain_disown's remedy, typed as logged, ends the matter" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "retain_disown's remedy, typed as logged, ends the matter" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
