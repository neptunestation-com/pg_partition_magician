#!/usr/bin/env bash
# Run tests/157, 158 and 159 against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh
# can point them at a mutant (issues #656, #666, #630).
#
# WHY A WRAPPER. The three files are plain pgTAP files and the default matrix already runs them on every
# version and channel, so on correct code this script adds nothing. What it adds is the standing proof
# that they DISCRIMINATE for the sites bench/cutover_reread_window.sh cannot reach. That guard drives a
# second session into transmute's cutover window, and a second session cannot change the owner or the RLS
# flags there (both need ACCESS EXCLUSIVE, which the resume's own ACCESS SHARE excludes); tests/159 makes
# that window with an event trigger instead. And untransmute's window is tests/157's part (B) and
# tests/158, each a dblink session that writes while the reversal is queued for its lock. Each file pairs
# its verdicts with liveness witnesses of its own; pointing it at a mutant is what shows the verdicts
# would fail without the fix.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   transmute_owner_rls_before_like          -- the owner and RLS flags are read before the staging LIKE
#                                               again: tests/159's parent keeps the old owner, RLS off
#   untransmute_trigger_capture_before_lock  -- untransmute captures the triggers before its lock again:
#                                               tests/158's restored table lacks tg158_b
#   untransmute_identity_reseed_before_lock  -- untransmute reads the reseed before its lock again:
#                                               tests/157's first insert after the reversal collides
#
# Usage: reread_under_lock_tap.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has).
# REREAD_TEST_DIR overrides the directory holding the test files inside the container, for running
# from a worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
DIR="${REREAD_TEST_DIR:-/repo/tests}"
FILES="157_identity_reseed_under_lock_test.sql 158_untransmute_trigger_capture_under_lock_test.sql 159_cutover_rereads_carried_state_test.sql"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

for f in $FILES; do
  q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

  # A mutant that will not even install is NOT a pass, and not evidence either: say which happened.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-66s %s\n' "the module under test installed" "$INSTALL"
    fail=1; break
  fi

  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $DIR/$f" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit status covers a failed assertion and a file that died short of its plan. What it cannot
  # tell apart from a real failure is a run that never reached the database, and discriminate.sh reads a
  # non-zero exit as "the guard caught the defect", so the count is asserted separately.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-66s %s\n' "$f" "$ran ran"
  else printf 'FAIL  %-66s %s\n' "$f" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-66s %s\n' "$f: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
