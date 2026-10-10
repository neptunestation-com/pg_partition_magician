#!/usr/bin/env bash
# identity_sequence_grants.sh <container> <db> [install.sql]
#
# Run tests/297_identity_sequence_grants_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1076): the
# identity sequence transmute builds on the parent, and the one untransmute builds on the restored table, kept
# the converting role's ALTER DEFAULT PRIVILEGES and none of the source sequence's grants, so the app lost
# USAGE and SELECT on <table>_id_seq and a role the operator had revoked got UPDATE (setval) back. The file is
# the acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run
# against the mutant, in the shape of bench/identity_sequence_name.sh.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   identity_sequence_acl_unreset      -- _identity_acl_carry_ddl replays the source's grants without the
#                                         reset, so what the default privileges gave the new sequence stays.
#                                         Parts A, B and C, both sites.
#   transmute_identity_seq_grantor_unchecked -- transmute's preflight asks about the table's grantors and not
#                                         its identity sequences', so a grant on the sequence made through a
#                                         grant option by a role the session cannot become dies inside the
#                                         cutover, after phases 1 and 2 committed. Part D.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo. The file builds its own fixtures,
# so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/297_identity_sequence_grants_test.sql}"
WHAT="the identity sequences keep their grants"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$WHAT" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$WHAT" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
