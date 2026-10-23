#!/usr/bin/env bash
# transmute_by_oid.sh <container> <db> [install.sql]
#
# Run tests/351_transmute_abort_by_oid_test.sql, tests/352_transmute_bound_by_oid_test.sql and
# tests/353_transmute_cutover_names_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the files catch the defects their mutations put back (issues #1364, #1355, #1367):
# transmute, transmute_abort and the incoming-key helpers named the tables they acted on by names rendered before a
# lock wait, so a schema renamed during the wait, with a namesake schema and table committed in its place, was what
# the statement reached; and transmute's cutover made its names from the name its unlocked preflight read, so a
# RENAME committed between phase 2 and the cutover was undone. The files are the acceptance tests; they drive their
# waits with dblink holder sessions. This wrapper exists so the mutations have a guard the discriminate track can
# run against the mutant, in the shape of bench/retire_locks_by_oid.sh.
#
# SEVEN mutations are required to fail against it (bench/mutations/mutate.py):
#   transmute_abort_drop_unlocked      -- #1364: transmute_abort's DROP of the bound named before its own wait, with
#                                         no lock by oid first: the namesake loses its constraint, the claimed table
#                                         keeps the bound (tests/351).
#   transmute_bound_add_unlocked       -- #1355: phase 1's ADD of the bound named before its own wait: the namesake
#                                         gets the write-rejecting CHECK (tests/352 part A).
#   transmute_validate_unlocked        -- phase 2's VALIDATE the same way: a namesake's constraint of the bound's name
#                                         is validated, the table's left NOT VALID (tests/352 part B).
#   transmute_preflight_read_unlocked  -- the preflight's reads with no first lock through the name it read: they read
#                                         a namesake, and a bound sized from it is committed on the table and fails
#                                         its VALIDATE, the claim left behind (tests/352 part C).
#   transmute_cutover_lock_follows_rename -- #1367: the cutover's first lock follows a rename instead of refusing it,
#                                         and the renames put the table back under the old name (tests/353 part A).
#   transmute_cutover_schema_unasked   -- the schema is not asked again after the cutover's waits: the triggers and
#                                         the policy it replays by name land on a namesake (tests/353 part B).
#   incoming_key_effect_unchecked      -- an incoming key's ADD, DROP or VALIDATE is not checked by its effect on the
#                                         referencing table's oid: restore_incoming_fks re-adds the key on a namesake
#                                         and marks the record restored (tests/353 part C).
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_DIR overrides the test files' directory
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
DIR="${TAP_GUARD_TEST_DIR:-/repo/tests}"
TEST_FILES="$DIR/351_transmute_abort_by_oid_test.sql $DIR/352_transmute_bound_by_oid_test.sql $DIR/353_transmute_cutover_names_test.sql"
LABEL="transmute acts on the table it identified, by oid"
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
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILES" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -40
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
