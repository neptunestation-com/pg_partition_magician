#!/usr/bin/env bash
# native_bound_reach_every_offset.sh <container> <db> [install.sql]
#
# Run tests/354_native_bound_reach_every_offset_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1363). A retired
# pgpm.archive_ledger row an older install wrote can carry a bound that names no instant by itself (before #977 a
# strategy's covered_hi was stored as written, in a session whose zone nothing recorded), and
# pgpm._native_bound_reach reads it at its widest. It widened a hi by 12 hours and a lo by 14, the zones tzdata
# names today, but a session goes to 168 hours either side of UTC (a POSIX zone, 'XYZ167:59:60'; an interval; a
# number of hours) and tzdata's LMT past both (Asia/Manila -15:56:08, America/Metlakatla +15:13:42). A hi written
# further west read below its own lo, a lo written further east past its own hi, the partition re-created over the
# chunk was not held, and the archive step PUT it over the retired chunk's object, the only copy of the dropped
# rows. The file pins PostgreSQL's limit (GUARD lines), which partitions are held, by name and by chunk, from three
# sessions, that the archive step PUTs over no retired object and archives the hours just past the widest reach,
# and that retain() keeps the held hours. The file is the acceptance test; this wrapper exists so the mutations
# have a guard the discriminate track can run against the mutant, in the shape of
# bench/over_retired_chunks_unnamed_widest.sh. Each failed assertion is printed as its `not ok` line, which is what
# discriminate.sh's starved() reads, so a mutant that failed only a LIVENESS witness is not certified as a catch.
#
# TWO mutations are required to fail against it (bench/mutations/mutate.py):
#   native_bound_reach_civil_zones     -- the reach is UTC-12 for a hi and UTC+14 for a lo again (#1354's
#                                         constants). Every held hour.
#   native_bound_reach_sixteen_hours   -- the plausible-but-wrong fix: 16 hours either side, past every LMT but
#                                         short of a POSIX zone. The POSIX and interval hours.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the
# container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/354_native_bound_reach_every_offset_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "an unnamed bound reaches every session offset" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "an unnamed bound reaches every session offset" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
