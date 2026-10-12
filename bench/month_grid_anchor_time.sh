#!/usr/bin/env bash
# month_grid_anchor_time.sh <container> <db> [install.sql]
#
# Run tests/342_month_grid_anchor_time_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (#1276): a whole-month time
# grid an older install anchored off its control column's unit (a date key at 12:00 UTC, a timestamptz(0) key
# 0.4 s off the second, a uuidv7 key half a millisecond off) has every bound where pgpm.part records it, since a
# calendar step's bounds are midnight on the 1st whatever the anchor's time, yet the upgrade's
# warn_grid_off_unit said every partition obtain mints is attached at other bounds than pgpm.part records, and
# set_regrain refused a whole-month target on it for the same false reason. A fixed step, registered or target,
# still counts from the anchor and is still refused.
# The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate track can
# run against the mutant, in the shape of bench/regrain_registered_grid_off_unit.sh. The file re-runs the
# install with \ir, handed the copy under test as the psql variable `install`, so the upgrade block judged is the
# mutant's.
#
# Mutations (bench/mutations/mutate.py):
#   upgrade_month_grid_anchor_bounds_claimed                -- the upgrade's whole-month test (the false claim).
#   regrain_month_grid_anchor_month_target_refused          -- _regrain_step_shape's fixed-target test, time key.
#   regrain_month_grid_encoded_anchor_month_target_refused  -- the same for an encoded (uuidv7) key.
#   regrain_month_grid_encoded_epoch_unasked                -- the encoded exemption without its epoch test, so a
#                                                              text_time epoch off the unit is exempted too.
#
# Runs on the plain core image (pgtap and pg_prove). The install path is read inside the container.
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted somewhere
# other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/342_month_grid_anchor_time_test.sql}"
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
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set install=$INSTALL $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a whole-month grid's anchor is held only where a step counts" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a whole-month grid's anchor is held only where a step counts" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
