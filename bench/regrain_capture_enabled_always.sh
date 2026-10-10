#!/usr/bin/env bash
# regrain_capture_enabled_always.sh <container> <db> [install.sql]
#
# Run tests/244_regrain_capture_enabled_always_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defects its mutations put back (issue #892,
# F3-01): regrain_step resumed a run whenever the source carried a trigger NAMED pgpm_regrain_capture, never
# asking whether it fires, so a capture trigger an owner disabled (ALTER TABLE <partition> DISABLE TRIGGER
# USER for a bulk load) or left origin-only (the matching ENABLE TRIGGER USER) still counted as live capture,
# and the swap attached copies that missed the changes made meanwhile: an UPDATE reverted, a DELETE
# resurrected. The file is the acceptance test (the finder's reproduction, statements unchanged, plus the
# restart asserted by identity, a negative witness and the swap's own check); this wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/regrain_null_source_mark.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   regrain_capture_unarmed_ignored   -- the resuming tick never asks whether capture is ENABLE ALWAYS, the
#                                        pre-fix shape. Part A (no restart; the swap's own check then
#                                        refuses every swap, so the run never finishes).
#   regrain_capture_unarmed_no_remint -- the plausible-but-wrong fix: the run restarts but capture is not
#                                        re-minted, so the trigger stays disabled and every tick restarts
#                                        again. Part A.
#   regrain_swap_capture_unchecked    -- the swap does not ask again under its DETACH, so a trigger disabled
#                                        after the tick's own check is never seen. Part C.
#
# Runs on the plain core image (pgtap and pg_prove; the test needs neither pg_cron nor dblink, and creates
# an event trigger, which the harness's postgres superuser may). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/244_regrain_capture_enabled_always_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "capture not ENABLE ALWAYS restarts the run, and stops a swap" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "capture not ENABLE ALWAYS restarts the run, and stops a swap" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
