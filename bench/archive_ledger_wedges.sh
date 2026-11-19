#!/usr/bin/env bash
# archive_ledger_wedges.sh <container> <db> [install.sql]
#
# Run tests/367_archive_ledger_wedges_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issues #1439, #1440): a ledger
# row a partition's next chunk collides with on the primary key stopped that partition being archived for good, and at
# archive_batch's default of 1 the parent's other partitions too, while the skip_archive it logged every tick moved no
# counter of status(). The rows: one covering nothing that an install older than #454's check left (#1439), and rows
# left under names an operator swapped, which are still tracked (#1440). The file re-runs install.sql with \ir; this
# wrapper hands it the copy under test as the psql variable `install`, as bench/install_keeps_dependent_views.sh does.
#
# ELEVEN mutations are required to fail against it (bench/mutations/mutate.py):
#   ledger_empty_chunk_kept        -- the install pass discards no row covering nothing. Part A.
#   ledger_empty_equal_text_only   -- only a row whose hi is lo as written, not one below lo. Part A.
#   ledger_empty_discards_retired  -- a retired row covering nothing is discarded too. Part A.
#   ledger_empty_cast_aborts       -- the bounds are cast, so a non-numeric hi aborts the install. Part A.
#   ledger_swap_by_name_only       -- the orphan discard asks only whether the name is tracked. Part B.
#   archive_skips_uncounted        -- status() counts no skip_archive. Part C.
#   archive_skips_never_reset      -- every skip_archive a partition ever logged is counted. Part C.
#   archive_skips_whole_step_dropped -- maintain()'s skip for the step as a whole is not counted. Part C.
#   archive_skips_parent_wide      -- a partition's skips reset on a sibling's chunk. Part D.
#   archive_skips_mark_per_child   -- the mark is read per pgpm.part row, not per lo, so a regrain's
#                                     copy at its source's lo counts every skip of it. Part E.
#   skip_archive_method_truncated  -- the skip's method is cut at 200 characters again. Part C.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/367_archive_ledger_wedges_test.sql}"
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
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set install=$INSTALL $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a ledger row that wedges a partition is discarded, a skip counted" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a ledger row that wedges a partition is discarded, a skip counted" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
