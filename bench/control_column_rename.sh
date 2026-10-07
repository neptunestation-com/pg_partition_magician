#!/usr/bin/env bash
# control_column_rename.sh <container> <db> [install.sql]
#
# Run tests/219_control_column_rename_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #826): every
# reader of pgpm.config.control_column resolved the control column by the NAME recorded at transmute, so
# after ALTER TABLE ... RENAME COLUMN of the partition key obtain's ceiling check raised a syntax error on
# every tick (skip_obtain, and the forward grid never grew again), the id frontier, extend_to, regrain and
# untransmute named a column that no longer exists, and set_partition_tz and set_regrain failed open on a
# type lookup that found nothing. The file is the acceptance test; this wrapper exists so the mutations
# have a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh.
#
# FOUR mutations are required to fail against it (bench/mutations/mutate.py):
#   control_followed_noop              -- pgpm._control_followed hands back the recorded name, the pre-fix
#                                         shape at every reader. Parts A to E.
#   control_followed_obtain_only       -- the per-site fix: only obtain's ceiling-check type lookup follows
#                                         the partition key, so the reported symptom is gone and every other
#                                         reader still uses the stale name. Parts B to E.
#   control_followed_missing_at_retain -- one config load (pgpm.retain's) left without the follow, a reader
#                                         no part exercises after a rename. Part F, the class check.
#   control_followed_missing_at_for_loop_load -- the same load written as a FOR loop
#                                         (`for cfg in select * from pgpm.config ... loop end loop;`), the shape
#                                         status() and progress() use, without the follow. Part F found loads by
#                                         the SELECT INTO spelling alone and never saw it (#999).
#
# Runs on the plain core image (pgtap and pg_prove; the test needs no pg_cron). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/219_control_column_rename_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "every reader follows a renamed control column" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "every reader follows a renamed control column" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
