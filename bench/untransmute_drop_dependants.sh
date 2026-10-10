#!/usr/bin/env bash
# untransmute_drop_dependants.sh <container> <db> [install.sql]
#
# Run tests/223_untransmute_drop_dependants_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect each of its mutations puts back (#831, and
# #815's bullet F10-06): untransmute's refusal asked pg_depend about the parent's pg_class row alone, so a
# function typed by the parent's row type, or a view over one of the empty forward partitions the DROP
# cascades to, made the reverse die raw with 2BP01 at its DROP instead of refusing with pgpm's message.
# One mutation per site, so each is shown to be caught on its own:
#   oid_bound_dependants_row_type_unasked          (judged by bench/transmute_row_type_dependants.sh; this
#                                                  file's part A catches it too)
#   untransmute_dependants_parent_only             the partitions the DROP takes are not asked about. Part B.
#   untransmute_dependants_monolith_counted        the monolith, handed back, is asked about too, a false
#                                                  refusal. Parts A and B.
#   untransmute_dependants_partition_rules_named   a rule on a dropped partition is refused, though it goes
#                                                  with its partition without an error. Part B.
# The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate
# track can run against the mutant, in the shape of bench/transmute_oid_bound_dependants.sh.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo. The file builds its own
# fixtures, so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/223_untransmute_drop_dependants_test.sql}"
WHAT="untransmute refuses what its DROP would fail on"
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
