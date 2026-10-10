#!/usr/bin/env bash
# regrain_target_encoded_unit.sh <container> <db> [install.sql]
#
# Run tests/308_regrain_target_encoded_unit_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutations put back: set_regrain (and
# regrain_step, regrain() and a tick) accepted a regrain target that is not a whole number of an encoded
# key's unit ('1.5 seconds' on an ObjectId text_time key, '1500 microseconds' on a uuidv7 key), so the copy
# placed each row by bounds floored to the unit while the reconcile placed a captured change by the unfloored
# grid, and a row deleted mid-regrain came back at the swap (#1039 bullet 2, pass 10 F3-01 and F3-04).
# Mutations (bench/mutations/mutate.py), each required to fail against it:
#   regrain_step_unit_uuidv7_unasked          -- a uuidv7 key has no unit; the ObjectId refusals still pass.
#   regrain_step_unit_text_time_seconds_unread -- a text_time key is held to a millisecond whatever its
#                                                 text_time_unit, so 1.5 seconds passes on an ObjectId key.
#   transmute_uuidv7_anchor_unasked            -- transmute registers a uuidv7 anchor off the millisecond
#                                                 (pass-10 per-PR verification V-01).
#   transmute_uuidv7_step_unasked              -- transmute takes a uuidv7 step off the millisecond (#1113).
#   regrain_step_registered_anchor_unasked     -- a regrain on a grid registered with an off-unit anchor is
#                                                 accepted.
#   regrain_step_registered_step_unasked       -- likewise for an off-unit registered step.
# The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track
# can run against the mutant, in the shape of bench/regrain_target_time_precision.sh.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/308_regrain_target_encoded_unit_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a regrain target is whole units of an encoded key" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a regrain target is whole units of an encoded key" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
