#!/usr/bin/env bash
# Run tests/378_resume_claim_zone_not_recordable_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant (issue #1111, V-02).
#
# A resumed transmute adopts the zone its claim recorded (#506), and adopted it unasked, so a claim an install from
# before #1086 recorded in localtime registered config.partition_tz = 'localtime' after the upgrade: a grid that
# moves with the host. The resume now refuses such a claim in its first transaction, naming transmute_abort. The
# refusal is of a committing procedure, wrapped by throws_like, so a resume that does NOT refuse dies at its first
# COMMIT with 2D000 inside the wrapper: the pinned message is what discriminates, and a twin claim recorded in UTC,
# which must resume, is the witness that the refusal is the zone's.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   resume_claim_zone_unasked -- the resume adopts the claim's zone without asking _canonical_tz, pre-#1111
#
# Usage: resume_claim_zone.sh <container> <db> [install.sql]
# Runs on the plain core image (pgtap and pg_prove). RESUME_CLAIM_ZONE_TEST_DIR overrides the directory of the
# test file inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_DIR="${RESUME_CLAIM_ZONE_TEST_DIR:-/repo/tests}"
FILES=(378_resume_claim_zone_not_recordable_test.sql)
LABEL="a resume refuses a claim zone pgpm never records"
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
