#!/usr/bin/env bash
# bound_contract_remedy.sh <container> <db> [install.sql]
#
# Run tests/305_bound_contract_remedy_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1088):
# _control_bound_contract's fresh-bound refusal offered "or use a smaller step" whatever the bound's cause, so
# on a numeric(4,0) key whose newest value is 9999 the operator who followed it (step 1) was refused with the
# same bound, [9000, 10000). The refusal now offers a smaller step only when the finest step the column
# admits gives a bound its type can store, and names that bound. The file is the acceptance test; this
# wrapper exists so the mutations have a guard the discriminate track can run against the mutant, in the
# shape of bench/retain_recall_moved_parent.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   bound_contract_finest_step_unchecked  -- the finest bound is never tried in the column's type, so the
#                                            step remedy is offered again whatever the bound. Parts A, C,
#                                            E and F.
#   bound_contract_finest_step_headroom   -- the finest bound leaves p_bound_headroom out, so headroom that
#                                            tips it over the top still gets the step remedy. Part E.
#   bound_contract_finest_step_unit_one   -- the finest step is 1 whatever the column's scale, so a
#                                            numeric(p,-2) key is judged on bounds it cannot hold. Part C.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/305_bound_contract_remedy_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a bound refusal offers a smaller step only when one works" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a bound refusal offers a smaller step only when one works" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
