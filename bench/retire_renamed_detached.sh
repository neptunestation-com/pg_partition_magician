#!/usr/bin/env bash
# retire_renamed_detached.sh <container> <db> [install.sql]
#
# Run tests/363_retire_renamed_detached_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1427): retire() met a
# detached retirement the operator renamed, while retention still reached it, and refused it as fail_retain_identity
# on every call, the mark kept, though the relation the row records stood whole under its new name. The file is the
# acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run against the
# mutant, in the shape of bench/retain_recall_renamed_detached.sh.
#
# FOUR mutations are required to fail against it (bench/mutations/mutate.py):
#   retire_rename_not_released        -- the pre-#1427 shape: refused as an identity failure. Parts A, B, D, E.
#   retire_release_keeps_mark         -- refused as detached by hand, the mark never released. Parts A, B, E.
#   retire_release_remedy_by_name     -- the release names the relation by the row's name, not the oid. Part E.
#   retire_release_marked_only        -- only the call that releases is a hand-detached refusal; every later call,
#                                        and a row with no mark, an identity failure again. Parts A, D.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/363_retire_renamed_detached_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "retire() releases a renamed detached retirement, never drops it" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "retire() releases a renamed detached retirement, never drops it" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
