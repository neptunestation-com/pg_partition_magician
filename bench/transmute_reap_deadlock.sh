#!/usr/bin/env bash
# Run tests/377_transmute_reap_deadlock_defers_claim_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant (issue #1231, B17-03).
#
# maintain_all's sweep reaps abandoned conversions one claim at a time and keeps the lock of a table it has reaped
# until the tick commits, so waiting on the next claim's table behind a reader that then touches the first, it is
# the deadlock detector's victim. The per-claim handler caught only lock_not_available, and the 40P01 ended the
# whole tick, rolling back the reap already done and skipping _detach_reap and every parent. The file needs a
# second and a third session (dblink): the sweep, and the reader that closes the cycle. Its LIVENESS lines pin
# that the sweep held the reaped table while it waited on the next, and that the deadlock was what it met, so a
# run whose reader was the victim (or whose sweep never waited) is a starved fixture, not a pass.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_reap_deadlock_escapes -- the per-claim handler catches the lock timeout alone again, pre-#1231
#
# Usage: transmute_reap_deadlock.sh <container> <db> [install.sql]
# Runs on the plain core image (pgtap, pg_prove and dblink). TRANSMUTE_REAP_DEADLOCK_TEST_DIR overrides the
# directory of the test file inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_DIR="${TRANSMUTE_REAP_DEADLOCK_TEST_DIR:-/repo/tests}"
FILES=(377_transmute_reap_deadlock_defers_claim_test.sql)
LABEL="a deadlock in the reap's lock wait defers that claim"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

for f in "${FILES[@]}"; do
  q -q -c "drop database if exists $DB with (force)" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

  # A mutant that will not even install is NOT a pass: say which happened.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
    fail=1
    break
  fi

  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_DIR/$f" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL (${f%%_*})" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL (${f%%_*})" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -q -c "drop database if exists $DB with (force)" >/dev/null 2>&1
exit "$fail"
