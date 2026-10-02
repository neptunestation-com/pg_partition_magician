#!/usr/bin/env bash
# untransmute_index_names.sh <container> <db> [install.sql]
#
# Run tests/221_untransmute_index_names_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #830): a UNIQUE
# constraint or index made on the managed table since the conversion came back from untransmute under the
# monolith clone's auto-name, because the DETACH keeps the clones' names and #789's reverse renamed only the
# key. The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate
# track can run against the mutant, in the shape of bench/cutover_key_name.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py), one per rule:
#   untransmute_index_names_kept                -- nothing but the key is renamed back, the pre-fix shape.
#                                                  Parts A and B.
#   untransmute_index_names_carried_renamed     -- a carried index takes its <name>_pgpm parent copy's name.
#                                                  Part A.
#   untransmute_index_names_legacy_key_renamed  -- a pre-#789 conversion's original key takes its parent
#                                                  copy's auto-name. Part B.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo. The file builds its own fixtures,
# so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/221_untransmute_index_names_test.sql}"
WHAT="untransmute hands back the parent's index names"
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
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
