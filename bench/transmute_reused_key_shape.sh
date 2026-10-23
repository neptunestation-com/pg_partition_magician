#!/usr/bin/env bash
# transmute_reused_key_shape.sh <container> <db> [install.sql]
#
# Run tests/356_transmute_reused_key_shape_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #766, bullets 1 and
# 2): transmute's step 8 declared the reused key on the parent from its column list, so a PRIMARY KEY ...
# INCLUDE failed the cutover with "multiple primary keys" after phases 1 and 2 had committed the bound, and a
# UNIQUE NULLS NOT DISTINCT key was built a second time on the monolith under the lock and lost on the parent
# and every forward partition. With the key carried whole, regrain reads a parent key that can hold INCLUDE
# columns, and has to take its KEY columns only. The file is the acceptance test; this wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/cutover_secondary_unique_constraint.sh.
#
# FOUR mutations are required to fail against it (bench/mutations/mutate.py), one per site:
#   transmute_key_redeclared_from_columns  -- step 8 declares the key from its column list again, the pre-fix
#                                             shape. Parts A to E.
#   regrain_key_include_refused            -- the capture's nullable-key refusal reads the INCLUDE columns too.
#                                             Parts D and E.
#   regrain_copy_joins_include_columns     -- the copy's anti-join joins on the INCLUDE columns too. Parts D
#                                             and E.
#   regrain_capture_keys_include_columns   -- the capture's delta and its drift check are keyed by the INCLUDE
#                                             columns too. Part E.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo. The file builds its own fixtures,
# so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/356_transmute_reused_key_shape_test.sql}"
WHAT="the reused key is carried with its whole definition"
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
