#!/usr/bin/env bash
# transmute_cutover_names_held.sh <container> <db> [install.sql]
#
# Run tests/299_transmute_cutover_names_held_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defects its mutations put back (issues #1080,
# #1104, #1105 bullet 1): the two names the cutover takes, the staging name <table>_pgpm_new its CREATE TABLE
# builds the new parent under and the monolith's name <table>_p<lo>_to_<hi> its RENAME gives the table, were
# asked to be free up front only, so a table or a type committed at either after that, or created by a
# transaction still open when the cutover reached it, made the CREATE or the RENAME die raw after the
# write-rejecting bound and the claim had committed. Each statement now asks the up-front question again
# from its own failure. The file opens committed windows with an event trigger on phase 1's ADD of the bound
# and in-flight ones with a second dblink session that commits once it sees the cutover wait on it, and pairs
# every refusal with witnesses that the window opened and its holder committed. The file is the acceptance
# test; this wrapper exists so the mutations have a guard the discriminate track can run against the mutant,
# in the shape of bench/transmute_uncarried_shapes_under_lock.sh.
#
# The mutations required to fail against it (bench/mutations/mutate.py), one per helper call each naming
# statement's handler makes, the XX000 arm, and the isolation refusal:
#   transmute_staging_name_preflight_only  -- the CREATE does not ask the staging helper: (A), (B), (D) are
#                                             named in the general helper's words, not the pinned up-front ones
#   transmute_create_held_names_unchecked  -- the CREATE does not ask the general helper: (G), (J) 23505
#   transmute_monolith_name_preflight_only -- the first RENAME does not ask the monolith helper: (C), (E) are
#                                             named in the general helper's words, not the pinned up-front ones
#   transmute_rename_held_names_unchecked  -- the first RENAME's 23505 arm does not ask the general helper:
#                                             (H), (K)
#   transmute_own_array_unchecked          -- the first RENAME lets XX000 through: (I)
#   transmute_xx000_blames_preexisting     -- that XX000 arm blames a holder already there: (M)'s GRANT race
#   transmute_final_rename_unhandled       -- the second RENAME asks nothing: (L) 23505
#   transmute_isolation_unchecked          -- REPEATABLE READ is not refused up front: (F)'s handler asks from
#                                             a snapshot older than the holder and re-raises the raw 23505
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo. The file builds its own
# fixtures, so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/299_transmute_cutover_names_held_test.sql}"
WHAT="a name the cutover takes, held after the asking, is refused"
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
