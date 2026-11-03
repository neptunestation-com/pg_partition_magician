#!/usr/bin/env bash
# write_block_reads_mark.sh <container> <db> [install.sql]
#
# Run tests/364_write_block_reads_mark_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1435): the write-block
# step compared a name against child_oid alone, so an older install's row (v0.5.0 recorded retiring_oid only) whose
# detached retirement the operator renamed had the operator's own table under the old name blocked, and once
# retire() anchored the row nothing ever said why. A block an older tick laid is named, never lifted. The file is the
# acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run against the
# mutant, in the shape of bench/retire_renamed_detached.sh.
#
# FIFTEEN mutations are required to fail against it (bench/mutations/mutate.py):
#   write_block_mark_unanchored        -- the pre-fix shape: the mark's oid anchors nothing. Parts A, B, D.
#   write_block_refusal_names_no_block -- the refusal is silent about a block an earlier tick laid. Part B.
#   write_block_refusal_lifts          -- the refusal lifts what holds the name. Parts B, D.
#   write_block_note_silent            -- no site names the block, the refusal nor the release. Parts B, G, I, K.
#   write_block_note_names_partition   -- an impostor attached to the parent is named as a block to lift. Part D.
#   write_block_note_skips_any_partition -- a partition of the operator's own partitioned table is not named. Part R.
#   write_block_note_names_tracked     -- a twin parent's partition detached by hand is named. Part K.
#   disown_remedy_names_no_block       -- the release's remedy does not name the block. Parts G, I, K.
#   disown_release_lifts               -- the release lifts the block it names. Part G.
#   disown_remedy_row_schema_only      -- the release looks only in the row's schema. Part I.
#   disown_remedy_parent_schema_rendered -- the parent's schema quoted twice, so nothing is named. Part Q.
#   disown_remedy_names_own_retirement -- a row with no oid names its own retirement's block. Part P.
#   write_block_mark_refuses_all       -- every marked row with no child_oid refused, the partition never blocked. Part C.
#   coverage_reset_mark_unanchored     -- the renamed table's coverage discarded as unguarded. Part E.
#   write_block_mark_shadows_stranger  -- a mark's oid hides a partition over another range under the name. Part H.
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
