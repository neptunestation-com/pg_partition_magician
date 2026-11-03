#!/usr/bin/env bash
# write_block_reads_mark.sh <container> <db> [install.sql]
#
# Run tests/364_write_block_reads_mark_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1435): the write-block
# step compared a name against child_oid alone, so an older install's row (v0.5.0 recorded retiring_oid only) whose
# detached retirement the operator renamed had the operator's own table under the old name blocked, and once
# retire() anchored the row the block was never lifted. The file is the acceptance test; this wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/retire_renamed_detached.sh.
#
# EIGHT mutations are required to fail against it (bench/mutations/mutate.py):
#   write_block_mark_unanchored     -- the pre-fix shape: the mark's oid anchors nothing. Parts A, B, D.
#   write_block_stale_kept          -- refused, but a block an earlier tick laid stays. Part B.
#   write_block_lift_under_parent   -- a block on an impostor attached to the parent is lifted too. Part D.
#   write_block_mark_refuses_all    -- every marked row with no child_oid refused, the partition never blocked. Part C.
#   coverage_reset_mark_unanchored  -- the renamed table's coverage discarded as unguarded. Part E.
#   write_block_stale_lift_once     -- no lift once retire() has anchored the row first. Part G.
#   write_block_mark_shadows_stranger -- a mark's oid hides a partition over another range under the name. Part H.
#   write_block_lift_own_schema_only -- the lift looks only where the anchor now lives, missing the parent's schema. Part I.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/364_write_block_reads_mark_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the write-block step anchors an older row by its mark" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the write-block step anchors an older row by its mark" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
