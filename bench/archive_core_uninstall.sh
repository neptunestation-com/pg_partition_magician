#!/usr/bin/env bash
# Run tests/archive/db/57_core_uninstall_with_archive_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL (issue #1040). Test 57 is a plain pgTAP file and the archive track already runs it,
# so on correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# pgpm_core's uninstall refuses while anything outside schema pgpm depends on an object in it, and tells the
# operator to save, drop and recreate each such object without pgpm: the wrong advice for an object of pgpm's own
# archive module. The module has none today (its strategies live in schema pgpm; nothing in schema archive has a
# catalog dependency on pgpm), and the file pins that with the module in use: the uninstall raises nothing,
# removes schema pgpm, and leaves the module's configuration and the managed table's rows as they were. A run
# where the module was never configured would satisfy "the uninstall went through" too, so two LIVENESS witnesses
# check that archive.config holds the table and that the table archives through one of the module's strategies.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_config_references_pgpm -- archive.config's parent_table gains a foreign key to pgpm.config, a module
#                                     object depending on pgpm that the refusal would name with the operator's
#                                     remedy
#
# Usage: archive_core_uninstall.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove). It does not need MinIO: nothing is sent.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree mounted somewhere other than /repo can point it at its own copy of the file.
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/archive/db/57_core_uninstall_with_archive_test.sql}"
LABEL="the core uninstall goes through with pgpm_archive in use (#1040)"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

# --- the database: fixtures, core, and the archive module under test ------------------------------
q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: the archive fixtures installed" "no"
  fail=1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: pgpm_core installed" "no"
  fail=1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ARCHIVE_INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: the archive module under test installed" "$ARCHIVE_INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  # the invariant oracle (tests/formal/oracle.sql): the test file calls pgpm_formal.baseline()
  q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/formal/oracle.sql >/dev/null 2>&1
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit status covers "fewer assertions ran than planned"; the count separates a real
  # failure from a run that never reached the database, which discriminate.sh would otherwise read as
  # "the guard caught the defect".
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
