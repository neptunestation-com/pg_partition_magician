#!/usr/bin/env bash
# regrain_capture_delta_by_record.sh <container> <db> [install.sql]
#
# Run tests/288_regrain_capture_delta_by_record_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1051):
# the capture function _regrain_capture_install mints inserted into <rel>_pgpm_regrain_delta by NAME, while
# every reader of the delta (the reconcile, the swap gate, the swap, regrain_cancel) resolves it by the oid
# pgpm.config recorded (#496). Renaming the recorded delta mid-regrain refused every write into the
# regraining source (42P01) for the life of the regrain, and a table the operator then created under the
# freed name took the captured keys, which the swap never read. The file is the acceptance test; this
# wrapper exists so the mutation has a guard the discriminate track can run against the mutant, in the shape
# of bench/retain_recall_moved_parent.sh. It is the core sibling of bench/hypertable_capture_delta_by_record.sh
# (#1037 bullet 1).
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_capture_delta_insert_by_name -- the capture inserts into the delta by its minted name alone, the
#                                           pre-#1051 shape (not regrain_capture_by_name, which is #496's
#                                           READERS by name, guarded by bench/regrain_capture_identity.sh).
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/288_regrain_capture_delta_by_record_test.sql}"
LABEL="the regrain capture writes the delta it recorded, renamed or not"
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
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
