#!/usr/bin/env bash
# Run tests/155_uninstall_residue_test.sql against an ARBITRARY copy of pgpm_core/uninstall.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, reading the real uninstall.sql with \ir, so this script adds nothing on
# correct code. What it adds is the standing proof that the file DISCRIMINATES. Its load-bearing
# assertions are negatives, "no standalone copy survives the uninstall" and "the refusal dropped
# nothing", and a negative is equally satisfied by a run with no regrain in flight or by an uninstall
# that never ran at all (the file runs its first uninstall inside a transaction it rolls back, so "the
# schema is still there" is true of a script that refuses nothing). The file pins its setup with liveness
# witnesses of its own (the copy is a real table holding ids 1..3; the refusal's SQLSTATE and message are
# asserted, not just its effect), but nothing re-checks that they would fail with the defect back in.
# Pointing the same file at a mutant uninstall.sql is what checks that, every CI run.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), both of uninstall.sql:
#   uninstall_drops_pending_fk        -- uninstall neither restores a preserve-managed incoming key nor
#                                        refuses on one it cannot restore, so pgpm.dropped_fk, the only
#                                        record of it, goes with the schema: pre-#589 behaviour exactly
#   uninstall_keeps_regrain_copies    -- uninstall tears down regrain's change capture but does not
#                                        abandon the regrain, so its not-yet-attached copies stay behind
#                                        as standalone tables in the operator's schema, as before #589
#
# Usage: uninstall_residue.sh <container> <db> [uninstall.sql]
# The third argument is the UNINSTALL script under test, not an install: pgpm_core/install.sql is what
# gets installed, always. It is a path inside the container, which the file reads with psql's \ir.
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
# UNINSTALL_RESIDUE_TEST_FILE and UNINSTALL_RESIDUE_INSTALL override the test file's and the install's
# paths inside the container, for running from a worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; UNINSTALL="${3:-/repo/pgpm_core/uninstall.sql}"
INSTALL="${UNINSTALL_RESIDUE_INSTALL:-/repo/pgpm_core/install.sql}"
TEST_FILE="${UNINSTALL_RESIDUE_TEST_FILE:-/repo/tests/155_uninstall_residue_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A module that will not even install is NOT a pass: the guard would then be reported as failing for a
# reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi
# Likewise a mutant path that is not there: \ir would fail, the file would die early, and the guard
# would read as having caught the defect.
if ! docker exec "$C" test -r "$UNINSTALL"; then
  printf 'FAIL  %-58s %s\n' "the uninstall script under test exists" "$UNINSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set uninstall=$UNINSTALL $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell apart from a real failure is a run that never reached the database at all, and
  # discriminate.sh reads a non-zero exit as "the guard caught the defect", so a harness broken enough to
  # fail against everything would be reported as proving the mutation. Hence the count, asserted
  # separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "uninstall loses no pending key and leaves no regrain copy" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "uninstall loses no pending key and leaves no regrain copy" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
