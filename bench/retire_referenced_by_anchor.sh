#!/usr/bin/env bash
# retire_referenced_by_anchor.sh <container> <db> [install.sql]
#
# Run tests/355_retire_referenced_by_anchor_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defect its mutations put back (issue #1365): retire()'s
# referenced path picked the partition to retire out of pg_inherits by RELNAME alone, so an operator's namesake in
# another schema, attached to the same parent and listed first, was recorded as retiring_oid and its detach
# dispatched, and every later retire() of the aged cell refused as fail_retain_identity. The one-detach-in-flight
# check read another retirement's partition the same way, so a namesake of a dropped partition held every
# referenced retirement off. The file is the acceptance test; this wrapper exists so the mutations have a guard
# the discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# EIGHT mutations are required to fail against it (bench/mutations/mutate.py):
#   retire_referenced_by_relname  -- the referenced path resolves its partition by relname again, the pre-fix
#                                    shape: the namesake is recorded and detached (part A).
#   retire_yield_by_relname       -- the in-flight check reads another mark's partition by relname again: the
#                                    namesake of a dropped partition holds the other parent's retirement off (part B).
#   disown_namesake_mark_kept     -- the install pass leaves an older retire()'s mark on the namesake in place, so
#                                    the cell is still refused on identity after the upgrade (part C).
#   child_oid_backfill_by_relname -- the #421 backfill adopts a namesake without asking for the row's range, and
#                                    retire() drops the operator's table as the cell's (parts D and F).
#   child_nsp_fallback_by_relname -- _child_nsp's fallback takes a namesake's schema for an unanchored row without
#                                    asking for the row's range, and retire() drops the operator's table (E and F).
#   part_bound_raw_quoted_only    -- a bound is read only in its quoted spelling, so an int4 grid's bare bounds
#                                    match nothing: no anchor at the upgrade, a moved parent's row not found, and
#                                    adopt_partition refuses (parts H, I and J).
#   retire_unanchored_stranger_unchecked -- retire() does not compare an unanchored row's relation by its range,
#                                    and drops the operator's table in the parent's own schema (part G).
#   write_block_unanchored_stranger_unchecked -- the write block goes on that table (part G).
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). The file re-runs install.sql through the psql variable `install`, set here to the copy under test.
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted somewhere
# other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/355_retire_referenced_by_anchor_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "retire() retires the anchored partition, not a namesake" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "retire() retires the anchored partition, not a namesake" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
