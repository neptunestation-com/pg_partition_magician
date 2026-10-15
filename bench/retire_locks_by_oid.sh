#!/usr/bin/env bash
# retire_locks_by_oid.sh <container> <db> [install.sql]
#
# Run tests/345_retire_locks_by_oid_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1335 bullet 10):
# retire() vouched for a partition by name and then locked it BY NAME, and LOCK TABLE resolves the name again once
# the lock is granted, so a rename of the partition and a table created under its old name, committed while
# retire() waited, left the lock on that table, and the one-step DROP took it, rows and all, and reported the drop.
# ATTACH PARTITION re-resolves its name the same way, which is how the regrain swap attached a table that took a
# renamed copy's name and dropped the source whose rows only the copy held, and how _retain_recall attached a
# table that took a detached partition's name in its place. pgpm._lock_oid asks the lock manager
# whether the lock is on the oid the caller vouched for. The file is the acceptance test; this wrapper exists so
# the mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh.
#
# TEN mutations are required to fail against it (bench/mutations/mutate.py):
#   retire_lock_answer_ignored    -- retire() takes the lock through _lock_oid and ignores the answer, the
#                                    pre-fix shape: the partition is dropped with no lock on it while the
#                                    stranger holds the name (part A), and a rename with nothing in its place
#                                    fails raw (part B).
#   regrain_swap_attach_unlocked  -- the swap ATTACHes a copy by the name its oid had when the statement was
#                                    built, with no lock on the oid first: the stranger is attached and the
#                                    copied rows leave the table (part C).
#   retain_recall_attach_unchecked -- the recall does not ask whether the relation its ATTACH reached is the one
#                                    it vouched for: the stranger is attached in the partition's place and the
#                                    retirement's mark cleared (part D).
#   lock_oid_vanished_name_null   -- _lock_oid answers NULL, not false, when its vouched name denotes nothing
#                                    under a lock already held, and callers read that as not refused (part E).
#   retire_drop_unverified, retire_crossing_unverified, write_block_create_unverified, write_block_enable_unverified,
#   untransmute_gate_unverified, regrain_reconcile_unverified
#                                 -- the check after each statement that names a relation and then waits for a
#                                    lock of its own is gone, so a schema renamed during the wait sends it to a
#                                    namesake (parts F, G, H, H2, J and K).
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/345_retire_locks_by_oid_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a lock taken by name is checked against the vouched oid" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a lock taken by name is checked against the vouched oid" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
