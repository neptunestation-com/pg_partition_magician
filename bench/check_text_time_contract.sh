#!/usr/bin/env bash
# Run tests/301 and tests/302 against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh
# can point them at a mutant (issues #1081, #1084, #1039 bullet 3).
#
# WHY A WRAPPER. The two files are plain pgTAP files and the default matrix already runs them on every
# version and channel, so on correct code this script adds nothing. What it adds is the standing proof that
# they DISCRIMINATE: that check_text_time's report is wrong, or raises, or accepts a shape transmute refuses,
# when one of its three contracts is taken out. Each file pairs its verdicts with liveness witnesses of its
# own (the session really misreads a bare render of the epoch; the bad row really has the declared shape and
# really overflows the plain decode; transmute really refuses the radix).
#
# tests/301's witnesses that a session misreads a bare render hold below PostgreSQL 18 only (18 reads the
# session zone's own abbreviations first), so its mutant is caught on the discriminate track's PostgreSQL 17
# and would not be on 18; the file skips those witnesses there rather than failing them.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   check_text_time_epoch_spliced        -- p_epoch spliced into the dynamic query with %L again: tests/301's
#                                           maxima and plausible counts in Asia/Kolkata and Europe/Dublin
#   check_text_time_decode_unbounded     -- _text_time_to_ts_bounded without its range check: tests/302 (A)
#                                           raises 'interval out of range' instead of reporting
#   check_text_time_radix_floor_dropped  -- check_text_time's supplied-alphabet branch without the radix
#                                           floor: tests/302 (B) samples radix 1 and radix 0
#
# Usage: check_text_time_contract.sh <container> <db> [install.sql]
# Runs on the plain core image (pgtap and pg_prove). CHECK_TEXT_TIME_TEST_DIR overrides the directory holding
# the test files inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
DIR="${CHECK_TEXT_TIME_TEST_DIR:-/repo/tests}"
FILES="301_check_text_time_epoch_bound_test.sql 302_check_text_time_overflow_radix_test.sql"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

for f in $FILES; do
  q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

  # A mutant that will not even install is NOT a pass, and not evidence either: say which happened.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-66s %s\n' "the module under test installed" "$INSTALL"
    fail=1; break
  fi

  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $DIR/$f" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit status covers a failed assertion and a file that died short of its plan. What it cannot
  # tell apart from a real failure is a run that never reached the database, and discriminate.sh reads a
  # non-zero exit as "the guard caught the defect", so the count is asserted separately.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ ')
  if [ "$rc" = 0 ]; then printf 'PASS  %-66s %s\n' "$f" "$ran ran"
  else printf 'FAIL  %-66s %s\n' "$f" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-66s %s\n' "$f: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
