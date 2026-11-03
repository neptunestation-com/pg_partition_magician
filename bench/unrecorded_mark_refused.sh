#!/usr/bin/env bash
# unrecorded_mark_refused.sh <container> <db> [install.sql]
#
# Run tests/365_unrecorded_mark_refused_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issues #1432, #1434): a
# retirement mark that records no oid at all (a pgpm older than v0.5.0 wrote retiring_at alone) was judged by its
# row's name once the relation was out of the parent, so a table created under the name was disowned as the
# retirement with a remedy ATTACHing it, and blocked; with nothing under the name retire() raised every tick. The
# file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track can run
# against the mutant, in the shape of bench/write_block_reads_mark.sh.
#
# NINE mutations are required to fail against it (bench/mutations/mutate.py):
#   unrecorded_mark_pass_by_name      -- the install pass judges such a mark by its name out of the parent. Parts D, E.
#   retire_unrecorded_mark_unrefused  -- retire() takes it on by name: a raise, or a disown. Parts A, B, E.
#   recall_unrecorded_mark_disowned   -- the recall disowns it as the table under the name. Part C.
#   write_block_unrecorded_blocks     -- the write-block step blocks the table out of the parent. Parts B, E.
#   write_block_unrecorded_any_rel    -- no block for a row with no oid, even on its partition. Part F.
#   unrecorded_mark_job_armed         -- the refusal leaves the job armed with the detach. Part A.
#   unrecorded_mark_aside_block_unnamed -- the move-aside branch names no block on the table it moves. Part C.
#   unrecorded_mark_keep_clears       -- the keep-it way out clears the mark, half a repair. Parts E and G.
#   unrecorded_mark_kept_block_unnamed -- nothing under the name: the keep-it way out names no block. Part G.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/365_unrecorded_mark_refused_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a mark with no oid is refused, its table never blocked" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a mark with no oid is refused, its table never blocked" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
