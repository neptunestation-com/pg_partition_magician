#!/usr/bin/env bash
# regrain_null_source_mark.sh <container> <db> [install.sql]
#
# Run tests/243_regrain_null_source_mark_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #878 bullet
# 2): a regrain in flight across the upgrade that added config.regrain_source_mark carries a NULL mark, and
# regrain_step took a null mark for "no drift" and then recorded the source as it is now, blessing copies
# made before a rewrite that fires no row trigger. The swap attached them: the regrained range served the
# pre-rewrite values. The file is the acceptance test (the verifier's reproduction, statements unchanged,
# plus the restart asserted by identity); this wrapper exists so the mutation has a guard the discriminate
# track can run against the mutant, in the shape of bench/regrain_drift_values.sh.
#
# This guard proves regrain_step's lever, the null mark over copies treated as drift. The other lever, the
# upgrade block in install.sql that restarts such a run at the upgrade itself, is proved by the in-flight
# stage of bench/upgrade_in_place.sh (assertion 8); this file models the upgraded state with an UPDATE and
# never runs that block.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   regrain_null_mark_adopted -- _regrain_source_drift answers null for a null mark, the pre-#878 shape, so
#                                the next tick records the source as the mark over the copies. Parts A and
#                                B of the file.
#
# Runs on the plain core image (pgtap and pg_prove; the test needs neither pg_cron nor dblink).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/243_regrain_null_source_mark_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a null source mark over copies restarts the run" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a null source mark over copies restarts the run" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
