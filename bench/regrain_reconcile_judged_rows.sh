#!/usr/bin/env bash
# regrain_reconcile_judged_rows.sh <container> <db> [install.sql]
#
# Run tests/291_regrain_reconcile_judged_rows_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1070): the
# regrain reconcile judged a batch of eligible delta rows (control below the cursor) and then applied and
# consumed every row carrying one of their pgpm_seq values. pgpm_seq is not unique and every writer of the
# table holds INSERT on the delta, which allows OVERRIDING SYSTEM VALUE, so a role with INSERT alone put a key
# from the sub-range still being copied on an eligible row's pgpm_seq; the tick wrote that key into the
# part-copied sub-range, the copy resumed above it and the swap dropped the rows it skipped with the source.
# The file is the acceptance test; this wrapper exists so the mutation has a guard the discriminate track can
# run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# And the junk no reconcile can consume, which the swap gate's purge must discard: a delta row whose control
# value is NULL (any writer can write one) was never purged (`not (NULL)` is NULL) but always counted, so more
# of them than the batch held the regrain at reconciling:N on every tick after the copy had finished.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   regrain_reconcile_batch_by_seq -- the reconcile addresses the judged rows by their pgpm_seq values alone,
#                                     without their ctids, as before #1070.
#   regrain_delta_purge_null_blind -- the purge deletes `not (<ctl> in range)` again, which keeps a NULL-key row.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/291_regrain_reconcile_judged_rows_test.sql}"
LABEL="a reconcile tick applies and consumes only the rows it judged"
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
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
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
