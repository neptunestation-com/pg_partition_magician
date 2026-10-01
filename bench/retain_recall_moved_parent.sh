#!/usr/bin/env bash
# retain_recall_moved_parent.sh <container> <db> [install.sql]
#
# Run tests/204_retain_recall_moved_parent_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #778):
# _retain_recall resolved a retiring partition in the PARENT's current schema, the one lifecycle step #727
# left there, so after ALTER TABLE <parent> SET SCHEMA a loosening logged fail_retain_identity, could not
# disarm the detach retire() had armed in the partition's own schema, pg_cron took the partition out of the
# parent, and nothing put it back. The file is the acceptance test; this wrapper exists so the mutations
# have a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_armed_detach.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   retain_recall_parent_schema  -- _retain_recall takes the parent's schema again, the pre-fix shape.
#                                   Parts A, B and C.
#   retain_recall_by_oid         -- the plausible-but-wrong fix: resolve the partition by its recorded oid
#                                   instead of by name in its own schema, so a squatter on the name is
#                                   never refused. Part C.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/204_retain_recall_moved_parent_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a moved parent's loosened retention takes back its retirement" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a moved parent's loosened retention takes back its retirement" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
