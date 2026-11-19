#!/usr/bin/env bash
# idle_reads_indexed.sh <container> <db> [install.sql]
#
# Run tests/391_idle_reads_indexed_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issues #1219 and #1038):
# every archive step's _mark_gone_chunks and #511 orphan query read every RETIRED ledger row of the parent to find
# the few that are not, so an idle tick's cost grew with the whole archive history; and _obtain_name's stand-in
# lookup read the whole of pgpm.log, which is never pruned, while obtain could hold ACCESS EXCLUSIVE on the parent.
# The file counts the tuples each call reads (pg_stat_get_xact_* inside one transaction, the instrument's liveness
# a plain read of the history), and shows each read still finds what it exists to find. This wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   archive_ledger_live_index_dropped -- archive_ledger has no index over the rows not retired again.
#   log_parent_action_index_dropped   -- pgpm.log has no (parent_table, action) index again.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/391_idle_reads_indexed_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "an idle archive step and the stand-in lookup read a slice" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "an idle archive step and the stand-in lookup read a slice" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
