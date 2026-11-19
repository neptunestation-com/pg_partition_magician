#!/usr/bin/env bash
# retire_default_partition.sh <container> <db> [install.sql]
#
# Run tests/366_retire_default_partition_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1453): with a DEFAULT
# partition on the parent, which makes PostgreSQL refuse every concurrent detach, retire() re-dispatched a referenced
# partition's detach on every tick, logged retain_detach (a success action), counted nothing, and its mark held the
# database's one detach slot, so no other table's referenced retirement was dispatched. The file is the acceptance
# test; this wrapper exists so the mutations have a guard the discriminate track can run against the mutant, in the
# shape of bench/unrecorded_mark_refused.sh.
#
# SIX mutations are required to fail against it (bench/mutations/mutate.py):
#   retire_default_dispatched          -- the detach is dispatched under the DEFAULT, uncounted. Parts A, B.
#   retire_default_holds_slot          -- the refused retirement keeps the one detach slot. Parts B, C.
#   retire_default_slot_skips_pending  -- a PENDING retirement under a DEFAULT loses the slot too. Part D.
#   retire_default_refuses_pending     -- a pending detach, which FINALIZE completes, is refused. Part D.
#   retire_default_uncounted           -- the refusal is logged under an action status() does not count. Parts A, B.
#   retire_default_after_crossing      -- a crossing row is deleted, and the detach dispatched, before any refusal.
#                                         Part A.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/366_retire_default_partition_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a detach a DEFAULT refuses is refused, holding no slot" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a detach a DEFAULT refuses is refused, holding no slot" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
