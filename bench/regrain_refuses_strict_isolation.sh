#!/usr/bin/env bash
# regrain_refuses_strict_isolation.sh <container> <db> [install.sql]
#
# Run tests/329_regrain_refuses_strict_isolation_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1258): regrain(),
# regrain_history() and regrain_step() ran in a REPEATABLE READ or SERIALIZABLE transaction, so the copy read the
# source and the swap read the captured delta through the transaction's first snapshot, and the swap dropped with
# the source a row committed after it (regrain_history) or a writer's committed UPDATE and DELETE (a hand swap
# step); maintain's tick took the same path under a stricter default_transaction_isolation. The file is the
# acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run against the
# mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   regrain_step_isolation_unchecked     -- regrain_step's call of the refusal dropped. Parts C and D.
#   regrain_isolation_serializable_only  -- the refusal asks for SERIALIZABLE alone. Parts A, C and D.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/329_regrain_refuses_strict_isolation_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap; create extension if not exists dblink;" >/dev/null 2>&1

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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "every regrain driver refuses a stricter isolation level" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "every regrain driver refuses a stricter isolation level" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
