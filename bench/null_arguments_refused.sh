#!/usr/bin/env bash
# null_arguments_refused.sh <container> <db> [install.sql]
#
# Run tests/248_transmute_null_arguments_refused_test.sql and tests/249_extend_to_text_time_null_arguments_refused_test.sql
# against an ARBITRARY copy of pgpm_core/install.sql, so that bench/discriminate.sh can show the files catch
# the defects their mutations put back (issue #896): transmute and extend_to never refused a null argument,
# and three-valued logic read each null as "not true", so p_force_frontier, p_force_uuidv7 and
# p_force_text_time => null acted as true, p_incoming_fks => null left an incoming key on the monolith,
# p_regrain_batch, p_paused and p_tt_epoch => null committed a write-rejecting bound before failing, and
# extend_to's p_max or p_value => null walked without end. The files are the acceptance test; this wrapper
# exists so the mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/retain_recall_moved_parent.sh. Each file runs in its own fresh database, as the suite runs it.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   transmute_null_arguments_accepted  -- _transmute's up-front null check removed, the pre-fix shape.
#                                         tests/248 parts A to D, tests/249 parts B and C.
#   extend_to_null_arguments_accepted  -- extend_to's up-front null check removed. tests/249 part A.
#   transmute_refuses_null_retain      -- the over-correction: p_retain, whose null is documented (keep
#                                         everything) and is its default, joins the refused list.
#                                         tests/248: every refusal names p_retain too, and the liveness
#                                         conversions, which pass p_retain => null, are refused.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_DIR overrides the tests
# directory's path inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_DIR="${TAP_GUARD_TEST_DIR:-/repo/tests}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

run_file() {  # <test file name> <what it proves>
  local file="$1" what="$2" out rc ran
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1
  # A mutant that will not even install is NOT a pass: say which happened.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
    fail=1
    return
  fi
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_DIR/$file" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$what" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$what" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions of $file were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
}

run_file 248_transmute_null_arguments_refused_test.sql "transmute refuses a null argument up front, naming it"
run_file 249_extend_to_text_time_null_arguments_refused_test.sql "extend_to, uuidv7 and text_time refuse a null too"

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
