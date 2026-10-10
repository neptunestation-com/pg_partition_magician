#!/usr/bin/env bash
# regrain_reconcile_unshaped_key.sh <container> <db> [install.sql]
#
# Run tests/323_regrain_reconcile_unshaped_key_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #709, review
# pass 11 F3-01, #1123 P1-02): the regrain reconcile grouped every batch by _grid_floor(_decode(key)), and
# _decode raises 22P02 on a text_time key the table accepts but that lacks the declared shape (too short, or a
# character outside the alphabet). One such key in the delta, from an ordinary DELETE of a row the copy had
# already moved or written there by any role with INSERT on the table, raised on every tick and at the swap
# until regrain_cancel. The file is the acceptance test; this wrapper exists so the mutations have a guard the
# discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   regrain_reconcile_decodes_unshaped_key  -- the shape test is gone, so every key is decoded again: the tick
#                                              raises 22P02 on the first off-shape key, as before #709.
#   regrain_reconcile_drops_unshaped_key    -- the plausible-but-wrong fix: an off-shape key no longer raises,
#                                              but it is consumed without being reconciled, so a DELETE of a
#                                              row the copy had moved comes back at the swap and an INSERT
#                                              is lost with the source.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/323_regrain_reconcile_unshaped_key_test.sql}"
LABEL="an off-shape text_time key is reconciled, never wedges a regrain"
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
