#!/usr/bin/env bash
# Run tests/137_archive_chunk_uuidv7_ties_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. The defect it guards against (#571) is a read that only one path
# reaches: #513's tie extension in _next_archive_chunk runs only when a chunk ends inside one native unit,
# which on a uuidv7 table means a millisecond holding at least a chunk's worth of rows. A fixture whose
# ids are a millisecond apart never gets there, and tests/125_uuidv7_regrain_archive (which guards #507's
# other two reads) passed with this one still an aggregate. The file pins its setup with liveness
# witnesses (the burst really decodes to one millisecond, the budget really holds fewer rows than the
# burst, the first chunk really stopped at the burst's edge), and its one negative ("nothing was deferred
# or refused") is paired with the ledger identity that shows the archive step ran. Pointing the same file
# at a mutant is what checks, every CI run, that the assertions after those witnesses fail when the
# aggregate is put back.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_chunk_native_tie_min_uuid  -- the tie extension's read of the first row past the unit is
#                                         min(<control>) again: 42883 on PostgreSQL 15 to 17, so the
#                                         direct pick dies, every archive tick logs skip_archive and the
#                                         2020 child is never covered nor retired
#
# It needs PostgreSQL before 18 to discriminate (18 has min(uuid)); the perf and discriminate tracks run
# on 17.
#
# Usage: archive_chunk_uuidv7_ties.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). ARCHIVE_U7_TIES_TEST_FILE
# overrides the test file's path inside the container, for running from a worktree that is mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${ARCHIVE_U7_TIES_TEST_FILE:-/repo/tests/137_archive_chunk_uuidv7_ties_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell apart from a real failure is a run that never reached the database at all, and
  # discriminate.sh reads a non-zero exit as "the guard caught the defect", so a harness broken enough
  # to fail against everything would be reported as proving the mutation. Hence the count, asserted
  # separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a uuidv7 millisecond of ties travels whole, no min(uuid)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a uuidv7 millisecond of ties travels whole, no min(uuid)" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
