#!/usr/bin/env bash
# Run tests/380_transmute_regrain_batch_positive_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant (issue #1243).
#
# transmute asked its grid arguments' rules and not p_regrain_batch's, so a zero or negative batch was recorded in
# config.regrain_batch for the life of the table and regrain_step clamped it to one row per tick. It is refused now
# with the other argument rules, in _refuse_bad_transmute_arguments, before anything is read or committed. The
# refusals are of a committing procedure, wrapped by throws_like, so one that does NOT refuse dies at its first
# COMMIT with 2D000 inside the wrapper: the pinned message is what discriminates, and the same call with a positive
# batch, which must convert and record it, is the witness that the call shape reaches the rules.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   transmute_regrain_batch_unchecked -- the batch rule asks nothing again, pre-#1243
#
# Usage: transmute_regrain_batch_positive.sh <container> <db> [install.sql]
# Runs on the plain core image (pgtap and pg_prove). TRANSMUTE_REGRAIN_BATCH_TEST_DIR overrides the directory of
# the test file inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_DIR="${TRANSMUTE_REGRAIN_BATCH_TEST_DIR:-/repo/tests}"
FILES=(380_transmute_regrain_batch_positive_test.sql)
LABEL="transmute refuses a regrain batch that is not positive"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

for f in "${FILES[@]}"; do
  q -q -c "drop database if exists $DB with (force)" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

  # A mutant that will not even install is NOT a pass: say which happened.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
    fail=1
    break
  fi

  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_DIR/$f" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL (${f%%_*})" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL (${f%%_*})" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -q -c "drop database if exists $DB with (force)" >/dev/null 2>&1
exit "$fail"
