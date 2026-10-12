#!/usr/bin/env bash
# Run tests/333_snapshot_wait_foreign_floor_holder_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant (issue #1263).
#
# The subject: while a transaction older than the copies runs in ANOTHER database, every snapshot of the cluster
# has an xmin at or before the copies' last write, so the regrain swap's snapshot wait lists sessions that see the
# copies along with ones that cannot, and nothing a caller reads tells the two apart. The swap keeps waiting (the
# file builds the indistinguishable pair: a READ COMMITTED statement begun after the copies and a REPEATABLE READ
# importer of a snapshot exported before them), and the refusal names the transaction that holds the floor, by
# database, pid and xid, instead of calling every listed session a reader that would find the range empty. Ending
# that transaction is the remedy, and the file types it. The file needs second sessions and another database,
# which it opens with dblink and makes itself (<db>_x, dropped at its end).
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   snapshot_wait_holder_this_database_only -- the holder is looked for in this database only, so the other
#                                              database's transaction is never named (part A)
#   snapshot_wait_foreign_floor_exempt      -- the exemption the issue asked for: a session whose xmin another
#                                              database's transaction explains is not listed, so the swap goes
#                                              through under the importer, which reads the range empty (part A)
#
# Usage: snapshot_wait_foreign_floor_holder.sh <container> <db> [install.sql]
# Runs on the plain core image (pgtap, dblink and pg_prove). It holds a transaction open across several seconds,
# which holds back every snapshot of the cluster, so it must run alone (the perf track runs its guards one at a
# time; the core suite runs the file after its parallel files). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/333_snapshot_wait_foreign_floor_holder_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists ${DB}_x" >/dev/null 2>&1
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a foreign floor holder is named, never passed" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a foreign floor holder is named, never passed" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

# a run that died with the other database's connections still open leaves it behind: close them first
q -q -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '${DB}_x'" >/dev/null 2>&1
q -q -c "drop database if exists ${DB}_x" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
