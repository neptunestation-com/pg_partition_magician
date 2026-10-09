#!/usr/bin/env bash
# transmute_publication_change_refused.sh <container> <db> [install.sql]
#
# Run tests/300_transmute_publication_change_refused_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so that bench/discriminate.sh can show the file catches the defect its mutation puts
# back (issues #766 bullet 4, #1105 bullet 2): the publication refusals, a row filter or a column list without
# publish_via_partition_root (#566) and a publication the caller does not own (#710), were asked in the
# preflight only, so a publication change committed after it (a filtered or unowned membership added while
# phases 1 and 2 had let go of the table, or publish_via_partition_root turned off inside the cutover while
# step 7a waited on a referenced table) made step 7c's ALTER PUBLICATION ... ADD TABLE die raw, after the
# write-rejecting bound and the claim had committed. Step 7c now asks again from its own failure. The file
# opens its windows with an event trigger on phase 1's ADD of the bound and with a second dblink session that
# flips the flag once it sees the cutover queued in step 7a, and pairs every refusal with witnesses that the
# window opened and its change committed. The file is the acceptance test; this wrapper exists so the
# mutation has a guard the discriminate track can run against the mutant, in the shape of
# bench/transmute_uncarried_shapes_under_lock.sh.
#
# The mutation required to fail against it (bench/mutations/mutate.py):
#   transmute_publication_preflight_only -- 7c's handler no longer asks: (A) and (C) die on 7c's raw
#                                           WHERE-clause error, (B) on its raw "must be owner"
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's
# path inside the container, for a worktree mounted somewhere other than /repo. The file builds its own
# fixtures, so fixtures/demo.sql is not loaded.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/300_transmute_publication_change_refused_test.sql}"
WHAT="a publication change after the preflight is refused"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

# the file's dblink sessions can outlive a run that died short of their disconnect
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
