#!/usr/bin/env bash
# transmute_skew_value_zone_free.sh <container> <db> [install.sql]
#
# Run tests/404_transmute_skew_value_zone_free_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1414 bullet 2):
# transmute's skew refusal on a uuidv7 key named the value to delete rows above as the encoding of its limit's
# ::text, which under DateStyle 'SQL, DMY' in Asia/Kolkata renders the zone as IST and reads back as Israel time,
# three and a half hours past the limit. The limit is now encoded from pgpm._ts_text. The file is the acceptance
# test; this wrapper gives the mutation a guard the discriminate track can run, in the shape of
# bench/extend_to_counts_new.sh. The track runs PostgreSQL 17, where the default abbreviations read IST as Israel.
#
# ONE mutation is required to fail against it (bench/mutations/mutate.py):
#   transmute_skew_value_from_session_text -- the limit encoded from its ::text again: the named value decodes
#                                              3.5 hours past the limit
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test
# file's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/404_transmute_skew_value_zone_free_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the skew refusal names the value encoding its limit" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the skew refusal names the value encoding its limit" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
