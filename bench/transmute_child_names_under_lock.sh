#!/usr/bin/env bash
# transmute_child_names_under_lock.sh <container> <db> [install.sql]
#
# Run tests/321_transmute_child_names_under_lock_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defects its mutations put back (issues #1167,
# #1135): the names the cutover's forward partitions take, <table>_p<label>, were asked to be free in the
# preflight only (the orphan-child guard), so a table or a type committed at one after that was stepped over
# by the cutover's obtain and the conversion completed with that cell unbuilt, and one a transaction still
# open was creating made the partition's CREATE die raw 23505 once it committed, after the write-rejecting
# bound and the claim had committed. The cutover now asks the guard again once its obtain has asked, and
# asks it and the general names helper from the forward CREATE's own failure. The file opens committed
# windows with an event trigger on phase 1's ADD of the bound and in-flight ones with a second dblink session
# that commits once it sees the cutover wait on it, and pairs every refusal with witnesses that the window
# opened and its holder committed. The file is the acceptance test; this wrapper exists so the mutations have
# a guard the discriminate track can run against the mutant, in the shape of
# bench/transmute_cutover_names_held.sh.
#
# The mutations required to fail against it (bench/mutations/mutate.py):
#   transmute_child_names_preflight_only   -- no asking after the cutover's obtain: (A) and (B) convert with
#                                             a hole in the forward grid
#   transmute_forward_create_unhandled     -- the forward CREATE's 23505 goes out raw: (C), (D)
#   transmute_forward_orphan_unasked       -- that handler does not ask the guard: (C) is named in the
#                                             general helper's words, not the pinned up-front ones
#   transmute_forward_held_names_unchecked -- that handler does not ask the general helper: (D) 23505
#   transmute_forward_blames_preexisting   -- that helper is not told what held the names before obtain
#                                             ran: (F) is blamed on the enum that was there first, which
#                                             PostgreSQL steps around, not the one the CREATE met
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo. The file builds its own
# fixtures, so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/321_transmute_child_names_under_lock_test.sql}"
WHAT="a forward partition's name, held after the asking, is refused"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

# the file's dblink sessions can outlive a run that died short of its disconnect
q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-62s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-62s %s\n' "$WHAT" "$ran ran"
  else printf 'FAIL  %-62s %s\n' "$WHAT" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-62s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
