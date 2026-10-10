#!/usr/bin/env bash
# Run tests/160_regrain_capture_name_fits_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its load-bearing assertions are negatives, "the managed table still
# holds its rows" after regrain_cancel, untransmute, an upgrade and uninstall.sql, and a negative is equally
# satisfied by a run in which the delta name never met the parent's (a parent one byte shorter, or a
# resolver that found something recorded). The file pins its setup with witnesses of its own (the name cut
# to 63 bytes IS the parent's, nothing is recorded, the capture really works under the names that replace
# it), but nothing re-checks that they would fail with the defect back in. Pointing the same file at a
# mutant is what checks that, every CI run. The file re-runs install.sql (the upgrade path) with \ir, so
# the mutant is handed to it as the psql variable `install` as well as installed first.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   regrain_capture_name_cut                -- _regrain_capture_derive cuts its names to 63 bytes again,
#                                              the pre-#655 shape: for a 63-byte parent the delta IS the
#                                              parent, and regrain_cancel, untransmute and uninstall.sql
#                                              act on the managed table
#   regrain_capture_backfill_adopts_parent  -- the upgrade backfill takes whatever sits under the cut name
#                                              for the delta, so a re-run of install.sql records a 63-byte
#                                              parent as its own delta and regrain_cancel truncates it
#
# Usage: regrain_capture_name_fits.sh <container> <db> [install.sql]
# The install is a path inside the container. Runs on the plain core image (it needs pgtap and pg_prove,
# both of which it has). REGRAIN_CAPTURE_NAME_TEST_FILE overrides the test file's path inside the
# container, for running from a worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${REGRAIN_CAPTURE_NAME_TEST_FILE:-/repo/tests/160_regrain_capture_name_fits_test.sql}"
LABEL="a 63-byte parent is never taken for its own capture delta"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for a
# reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set install=$INSTALL $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell apart from a real failure is a run that never reached the database at all, and
  # discriminate.sh reads a non-zero exit as "the guard caught the defect", so a harness broken enough to
  # fail against everything would be reported as proving the mutation. Hence the count, asserted
  # separately and printed either way.
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
