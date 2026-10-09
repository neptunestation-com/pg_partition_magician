#!/usr/bin/env bash
# retain_horizon_ambiguous_wall_time.sh <container> <db> [install.sql]
#
# Run tests/311_retain_horizon_ambiguous_wall_time_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so that bench/discriminate.sh can show the file catches the defect its mutation puts
# back (issue #627): the retain horizon was ((now() at time zone partition_tz) - retain) at time zone
# partition_tz, a wall-clock round trip of now()'s own reading, and `at time zone` resolves an ambiguous
# fall-back wall time to its LATER instant. At 01:30 EDT on the first pass through the repeated hour, retain
# '0' put the horizon at 06:30Z, an hour past now(); on an hourly grid retain() dropped the partition taking
# writes with its rows, and regrain_step discarded the same sub-range as aged at its swap. The file is the
# acceptance test; this wrapper exists so the mutation has a guard the discriminate track can run against the
# mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   retain_horizon_wall_round_trip -- _retain_horizon is the single-expression wall-clock round trip again,
#                                     the pre-fix shape, in the one helper both sites call. Parts A, B, C.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own clock, a clk.now() shim ahead of
# pg_catalog in search_path). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a
# worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/311_retain_horizon_ambiguous_wall_time_test.sql}"
LABEL="the retain horizon never passes now() in a fall-back hour"
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
