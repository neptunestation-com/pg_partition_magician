#!/usr/bin/env bash
# Run tests/382, 383 and 387 against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh can point
# them at a mutant (issues #1134, #954, #1415).
#
# WHY A WRAPPER. The three files are plain pgTAP files and the default matrix already runs them on every version and
# channel, so on correct code this script adds nothing. What it adds is the standing proof that they DISCRIMINATE.
# Each contract is about retention meeting a state the operator or an older install left, and each has a negative
# half an idle run satisfies: "set_retain does not refuse" holds for a guard that never reads the row, "the job is
# idle after untransmute" for a retirement that never armed it, "the block is not lifted" for a step that never ran.
# Each file pairs those with liveness witnesses of its own; pointing it at a mutant is what shows the verdicts would
# fail without the fix.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   set_retain_counts_hand_detached   -- set_retain's would-drop guard reads pgpm.part.attached alone again, so a
#                                        tightening that reaches only a table the operator detached by hand is
#                                        refused, naming it: tests/382
#   untransmute_leaves_detach_armed   -- untransmute forgets a retiring row and leaves pgpm_detach armed with its
#                                        detach: tests/383 part A
#   untransmute_disarms_any_detach    -- untransmute returns the job to idle whatever it holds, another table's
#                                        detach included: tests/383 part B
#   write_block_stranger_block_unnamed -- the refusal to write-block an unanchored row's stranger no longer names
#                                        the block an older install put on it: tests/387
#
# Usage: retain_edges_tap.sh <container> <db> [install.sql]
# Runs on the plain core image (pgtap and pg_prove; tests/383 brings its own stand-in for pg_cron's catalog). About
# 5 s: tests/383 waits for a 1-second grid's forward cell to age past the horizon.
# RETAIN_EDGES_TEST_DIR overrides the directory holding the test files inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
DIR="${RETAIN_EDGES_TEST_DIR:-/repo/tests}"
FILES="382_set_retain_hand_detached_test.sql 383_untransmute_disarms_detach_test.sql 387_write_block_stranger_leftover_named_test.sql"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

for f in $FILES; do
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

  # A mutant that will not even install is NOT a pass, and not evidence either: say which happened.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-66s %s\n' "the module under test installed" "$INSTALL"
    fail=1; break
  fi

  # the invariant oracle (tests/formal/oracle.sql): the custody files call pgpm_formal.baseline()
  q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/formal/oracle.sql >/dev/null 2>&1
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $DIR/$f" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit status covers a failed assertion and a file that died short of its plan. What it cannot tell
  # apart from a real failure is a run that never reached the database, and discriminate.sh reads a non-zero exit
  # as "the guard caught the defect", so the count is asserted separately.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-66s %s\n' "$f" "$ran ran"
  else printf 'FAIL  %-66s %s\n' "$f" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-66s %s\n' "LIVENESS: $f: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
