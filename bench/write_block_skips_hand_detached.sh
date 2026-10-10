#!/usr/bin/env bash
# write_block_skips_hand_detached.sh <container> <db> [install.sql]
#
# Run tests/307_write_block_skips_hand_detached_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #705):
# _enforce_write_blocks, _archive_step and maintain()'s auto-regrain candidate scan trusted
# pgpm.part.attached, which an operator's own DETACH PARTITION never touches, so a maintain() tick put
# pgpm_write_block on a table the operator had detached to keep (every write to it refused "past its
# retention boundary"), the archive step handed such a table to the strategy and recorded coverage for it,
# and auto-regrain put its capture and TRUNCATE guard on a detached coarse child and wedged on it (or, for a
# run already in flight when the source was detached, left it there for good), while retire() refused it
# as detached by the operator (#652). The file is the acceptance test; this wrapper exists so the mutations have a guard the
# discriminate track can run against the mutant, in the shape of bench/obtain_rebuilds_detached_cell.sh.
#
# EIGHT mutations are required to fail against it (bench/mutations/mutate.py):
#   write_block_trusts_part_attached     -- _enforce_write_blocks walks every attached row again, the
#                                           pre-fix shape. Part A.
#   archive_trusts_part_attached         -- _archive_step's candidate query trusts attached again, the
#                                           pre-fix shape: the detached table takes archive_batch's one
#                                           turn (#1159's hold then refuses it). Part B.
#   detached_by_hand_ignores_retiring_at -- the over-correction: any child outside pg_inherits reads as
#                                           detached by hand, so a partition pgpm's own retirement detached
#                                           (retiring_at set) is no longer blocked. Part C.
#   detached_by_hand_counts_dropped      -- the over-correction: a partition dropped by hand reads as
#                                           detached too, so the write-block step skips it silently instead
#                                           of logging skip_write_block (tests/94's path). Part D.
#   regrain_trusts_part_attached         -- the auto-regrain candidate scan trusts attached again, the
#                                           pre-fix shape. Part E.
#   progress_coarse_counts_hand_detached -- progress().coarse_frozen stops mirroring that scan and counts
#                                           the detached coarse child. Part E.
#   regrain_detached_source_orphaned     -- a run already in flight when its source is detached by hand is
#                                           never ended: triggers, copies and cursor stay. Part F.
#   regrain_detached_logged_as_cancel    -- the run is ended but logged regrain_cancel. Part F.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/307_write_block_skips_hand_detached_test.sql}"
LABEL="maintain leaves a hand-detached partition writable"
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
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
