#!/usr/bin/env bash
# retire_crossing_parent_rls.sh <container> <db> [install.sql]
#
# Run tests/266_retire_crossing_delete_parent_rls_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #890, the
# "Reads under RLS" bullet): retire()'s crossing DELETE read the PARENT under the caller's row-level security
# and nothing asked pgpm._refuse_filtered_reads of the parent first, so a non-BYPASSRLS owner of a FORCE'd
# parent on a time grid deleted only the referenced rows its policy admits, the declared CASCADE reached their
# referencing rows alone, and the detach it dispatched was refused forever by the others. The file is the
# acceptance test; this wrapper exists so the mutation has a guard the discriminate track can run against the
# mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   retire_crossing_parent_rls_unasked -- the parent's refusal before the crossing DELETE is taken out.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's catalog).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted somewhere
# other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/266_retire_crossing_delete_parent_rls_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "retire refuses a crossing DELETE the parent's RLS would filter" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "retire refuses a crossing DELETE the parent's RLS would filter" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
