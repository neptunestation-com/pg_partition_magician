#!/usr/bin/env bash
# archive_retired_chunk_kept.sh <container> <db> [install.sql]
#
# Run tests/309_archive_retired_chunk_kept_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1141 bullet 1).
# After retire() dropped a partition, its chunks' ledger rows are the record of the only copy of its rows. A
# partition re-created over the range and recorded with pgpm.adopt_partition met five archive_coverage_reset
# sites that could not tell a retired chunk from coverage of a live partition: _archive_step's orphan discard
# deleted the retired row and the same tick archived the new partition to the same object key, over the only
# copy; under the dropped partition's own name, adopt_partition, retire(), _enforce_write_blocks and regrain's
# swap deleted it by name, and _next_archive_chunk and _archive_fully_covered read it as the new partition's
# coverage. The file is the acceptance test (its stub strategy keys an object by parent and lo, as
# pgpm_archive's transports do, so the overwrite is visible without MinIO); this wrapper exists so the
# mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh.
#
# Every mutation of the archive_retired_ family in bench/mutations/mutate.py must fail against it, one per
# site: the orphan discard (archive_retired_orphan_discard, the issue's own path), adopt_partition, retire(),
# _enforce_write_blocks, regrain's swap and its #266 rename, the two coverage readers, the candidate
# exclusion, retire()'s marking, and the upgrade backfill's timing.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/309_archive_retired_chunk_kept_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a retired chunk's ledger row and object outlive a re-created range" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a retired chunk's ledger row and object outlive a re-created range" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
