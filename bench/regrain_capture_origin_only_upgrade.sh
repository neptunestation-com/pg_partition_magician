#!/usr/bin/env bash
# regrain_capture_origin_only_upgrade.sh <container> <db> [install.sql]
#
# Run tests/245_regrain_capture_origin_only_upgrade_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so that bench/discriminate.sh can show the file catches the defect its mutation puts
# back (issue #892, F3-04): a regrain in flight across the upgrade from v0.6.0 kept the origin-only capture
# trigger v0.6.0 minted (#450 made capture ENABLE ALWAYS only for regrains prepared after it), the upgrade's
# #878 restart kept capture as it was, and regrain_step asked only that the trigger exist, so DML applied
# with session_replication_role = replica after the upgrade was never captured and the swap reverted the
# UPDATE and resurrected the DELETE. The file models the upgraded state (a null source mark and an
# origin-only trigger) and is the acceptance test; this wrapper exists so the mutation has a guard the
# discriminate track can run against the mutant, in the shape of bench/regrain_null_source_mark.sh. The real
# upgrade from the released v0.6.0 is bench/upgrade_in_place.sh's in-flight stage.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   regrain_capture_unarmed_disabled_only -- the plausible-but-wrong fix: only a DISABLED capture trigger
#                                            counts as not live, so the origin-only one a v0.6.0 run carries
#                                            across the upgrade passes, nothing re-mints it, and the
#                                            replica-role DML is lost at the swap.
#
# Runs on the plain core image (pgtap and pg_prove; the test needs neither pg_cron nor dblink).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/245_regrain_capture_origin_only_upgrade_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "an upgraded run's origin-only capture is re-armed" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "an upgraded run's origin-only capture is re-armed" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
