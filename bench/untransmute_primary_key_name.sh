#!/usr/bin/env bash
# untransmute_primary_key_name.sh <container> <db> [install.sql]
#
# Run tests/257_untransmute_primary_key_name_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #901): a
# PRIMARY KEY made on the managed table since the conversion came back from untransmute under the monolith
# clone's auto-name (<monolith>_pkey), because #830's hand-back skipped every primary-key index to spare a
# pre-#789 conversion's original key. The file is the acceptance test; this wrapper exists so the mutations
# have a guard the discriminate track can run against the mutant, in the shape of
# bench/untransmute_index_names.sh (which keeps holding the pre-#789 key's exception, tests/221 part B).
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   untransmute_pkey_name_kept             -- the pre-fix filter, no primary key handed back. Parts A, B and C.
#   untransmute_pkey_clone_name_unclipped  -- the clone-name test compares the monolith's WHOLE name, never
#                                             clipped to fit 63 bytes, so a long-named table's key is kept.
#                                             Part C.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo. The file builds its own fixtures,
# so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/257_untransmute_primary_key_name_test.sql}"
WHAT="untransmute hands back a primary key made since"
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
