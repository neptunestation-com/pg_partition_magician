#!/usr/bin/env bash
# Run tests/328_regrain_swap_waits_for_older_snapshots_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant (issue #1241).
#
# WHY A WRAPPER EXISTS AT ALL. The file is a plain pgTAP file and the default matrix already runs it on every version
# and channel, so this script adds nothing on correct code. What it adds is the standing proof that the file
# DISCRIMINATES. Its subject is a negative ("the swap did not run under the reader", "the reader lost no row"), and a
# negative is equally satisfied by a run that never had the swap in front of it, so the file pins its setup with
# liveness witnesses of its own (the copies ran; the reader's snapshot cannot see even their log rows; the reader
# holds no lock on the table, so no lock made the swap wait; the run reached the swap), and this wrapper re-checks,
# every CI run, that the file fails when the wait is taken away. The reader needs a second session, which the file
# opens with dblink.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   regrain_swap_no_snapshot_wait         -- the swap waits for nothing: the tick swaps under the open reader, which
#                                            then reads the range empty (part A), and regrain() does not refuse
#                                            (part B)
#   regrain_written_xid_first_copy        -- the run records its first copy's transaction, not its last, so a
#                                            reader opened between the two is swapped under (part D)
#   regrain_snapshot_wait_masked_type_dropped -- a reader in a role the maintaining owner cannot see the
#                                            backend_type of is dropped from the list (parts E and H)
#   regrain_snapshot_wait_older_transactions_only -- under regrain(), only transactions older than the call are
#                                            listed (parts F and H)
#   snapshot_wait_masked_state_dropped    -- a predicate over state and xact_start, NULL to an owner without
#                                            pg_read_all_stats, drops the other role's reader (parts F and H)
#   snapshot_wait_running_statement_exempt -- a reader running a statement is not waited for (part F)
#   snapshot_wait_settles_running         -- at the budget, a swap with only running statements left goes ahead
#                                            (part G)
#   snapshot_wait_no_blocked_exemption    -- a session waiting on a lock the regrain holds is waited for, so
#                                            regrain() refuses instead of completing (part C)
#   snapshot_wait_list_captured_once      -- the sessions are listed once, so a snapshot imported after the wait
#                                            began is never waited for (part I)
#
# Usage: regrain_swap_waits_for_older_snapshots.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has). TAP_GUARD_TEST_FILE
# overrides the test file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/328_regrain_swap_waits_for_older_snapshots_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the regrain swap waits for snapshots older than it" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the regrain swap waits for snapshots older than it" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
