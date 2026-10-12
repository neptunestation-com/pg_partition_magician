#!/usr/bin/env bash
# retirement_mark_needs_dispatch.sh <container> <db> [install.sql]
#
# Run tests/330_retirement_mark_needs_dispatch_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1259): the
# readers of a retirement mark (pgpm._part_built and through it _part_detached_by_hand, and
# _archive_hold_partition) vouched for pgpm.part.retiring_at by itself, without the record of pgpm's dispatch
# (detach_dispatched_oid) that retire() requires (#705). A mark whose dispatch failed (no pg_cron) on a table the
# operator then detached by hand read as pgpm's own retirement in flight: the next maintain() tick, whose archive
# step runs before retain(), handed the operator's table to the archive strategy and recorded coverage for it, and
# retention dropped it on that coverage once the operator attached it back, its rows archived nowhere. The file is
# the acceptance test; this wrapper exists so the mutation has a guard the discriminate track can run against the
# mutant, in the shape of bench/write_block_skips_hand_detached.sh.
#
# The per-PR verification's V-01 is the converse state, guarded by the same file: a mark WITH its record (pgpm's own
# detach landed) on a table archiving was configured for only after the mark was stamped. _archive_hold_partition
# vouched for it, so the step handed the detached table to the strategy, which reading through the parent read none
# of its rows; the range was recorded as covered with 0 rows and retire() dropped the table. No detached table is
# held now: nothing is recorded, retire() keeps it, and the step logs skip_archive with the remedy.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   retirement_mark_vouches_alone            -- pgpm._retirement_vouched answers from the mark alone, without
#                                               _detach_dispatched's record. Part B (the predicates and the
#                                               write-block step).
#   archive_hold_vouches_detached_retirement -- the hold vouches for a detached table carrying pgpm's own
#                                               retirement again (V-01). Parts B and D.
#   retirement_mark_readers_whole            -- #1259's defect whole, both readers. Parts A to D.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the
# container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/330_retirement_mark_needs_dispatch_test.sql}"
LABEL="a retirement mark vouches only with its dispatch record"
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
