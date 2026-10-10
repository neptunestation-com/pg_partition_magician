#!/usr/bin/env bash
# Run tests/191 and 192 against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh can
# point them at a mutant (issues #729, #634).
#
# WHY A WRAPPER. The two files are plain pgTAP files and the default matrix already runs them on every
# version and channel, so on correct code this script adds nothing. What it adds is the standing proof
# that they DISCRIMINATE. Both contracts are about what the maintenance sweeps READ and in what ORDER, and
# both are negatives an idle run satisfies: "no regrain was prepared once auto-regrain was off" holds for a
# tick that never reached its regrain block, and "the table cut short last sweep led this one" holds for a
# sweep that never cut anything short. tests/191 makes its window with a dblink session that commits
# set_regrain from inside the tick's archive step; tests/192 makes its overrun with an event trigger that
# sleeps in one table's CREATE TABLE and counts its entries in a sequence. Each file pairs its verdicts
# with liveness witnesses of its own; pointing it at a mutant is what shows the verdicts would fail
# without the fix.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   maintain_regrain_stale_target          -- maintain dispatches auto-regrain from the regrain_to it
#                                             read at the top of the tick again: tests/191's rg_off tick
#                                             prepares a regrain after auto-regrain was turned off
#   maintain_obtain_all_fixed_order        -- maintain_obtain_all sweeps `order by parent_table` with no
#                                             turn stamps again: tests/192 obtains oa first, and sb is
#                                             starved behind sa on every sweep
#   maintain_obtain_all_no_first_turn_stamp -- the obtain sweep's first table is not stamped before it
#                                             starts: sa, whose own obtain overruns the clock, is never
#                                             stamped and leads, and is cancelled in, every sweep
#
# Usage: maintain_sweep_reads_tap.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has). About 6 s:
# tests/192 runs three sweeps under a 1.5 s statement_timeout, two of them cut short.
# SWEEP_READS_TEST_DIR overrides the directory holding the test files inside the container, for running
# from a worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
DIR="${SWEEP_READS_TEST_DIR:-/repo/tests}"
FILES="191_maintain_regrain_reads_target_under_lock_test.sql 192_maintain_obtain_all_sweep_turns_test.sql"
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
    printf 'FAIL  %-66s %s\n' "LIVENESS: $f: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
