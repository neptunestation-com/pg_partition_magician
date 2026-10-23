#!/usr/bin/env bash
# regrain_copy_by_oid.sh <container> <db> [install.sql]
#
# Run tests/350_regrain_copy_by_oid_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1358): regrain_step's
# copy batch named the copy and the source by names rendered before the INSERT waited for its locks, the copy's
# making named the copy by name after waits of its own, and the reconcile named the capture delta by a name read
# before the tick's first wait on it. A schema renamed aside during such a wait, with namesakes committed in its
# place, was what the statement reached: a batch copied from or into a stranger (rows lost at the swap, or a
# stranger's rows served), a stranger minted, constrained and anchored as the copy, a namesake delta consumed, or
# (the swap's TRUNCATE of a never-written delta, judged by a catalog write a GRANT also makes) emptied. The
# file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run
# against the mutant, in the shape of bench/retire_locks_by_oid.sh.
#
# FIVE mutations are required to fail against it (bench/mutations/mutate.py):
#   regrain_copy_batch_unlocked        -- the copy and the source are not locked by oid before the INSERT, so it
#                                         waits by name and reaches the namesakes (parts A and B).
#   regrain_copy_make_returns_by_name  -- _regrain_copy_make hands back the copy by its name after its statements
#                                         waited, so the caller mints, constrains, anchors and fills a namesake
#                                         (part C).
#   regrain_reconcile_delta_unlocked   -- the reconcile does not lock the delta by oid first, so its batch read
#                                         waits by name and reads a namesake's rows as the batch (part D).
#   truncate_checked_inplace_by_catalog_write
#                                      -- _truncate_checked's in-place branch asks who last wrote the delta's
#                                         pg_class row, which the swap tick's GRANT to a new writer does, so a
#                                         never-written delta passes while the swap's TRUNCATE empties a namesake
#                                         (part E).
#   truncate_checked_inplace_by_creation
#                                      -- the in-place branch asks whether this transaction created the delta, so a
#                                         second regrain_cancel in one transaction, whose TRUNCATE empties in place
#                                         the file the first gave it, is refused as a redirection (part E2).
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/350_regrain_copy_by_oid_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the regrain copy reaches the relations it identified" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the regrain copy reaches the relations it identified" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
