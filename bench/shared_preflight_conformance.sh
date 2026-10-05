#!/usr/bin/env bash
# shared_preflight_conformance.sh <container> <db> [install.sql]
#
# Run tests/268_shared_preflight_refusals_test.sql and tests/269_resume_recorded_bounds_test.sql against an
# ARBITRARY copy of pgpm_core/install.sql, so that bench/discriminate.sh can show the files catch every
# defect their mutations put back (the shared-preflight lever, #966: issues #951, #952, #959). The invariant:
# a refusal the core makes before anything commits is made by one preflight every converting entry point
# calls before its first commit. The files are the acceptance test; this wrapper exists so the mutations
# have a guard the discriminate track can run against the mutant, in the shape of
# bench/null_arguments_refused.sh. Each file runs in its own fresh database, as the suite runs it.
#
#   tests/268 part A  sweeps every public routine of schema pgpm, enumerated from pg_proc, with null in each
#                     argument position, and requires pgpm's own null refusal naming that argument (the
#                     documented-null arguments are its case table); part A1 is suspend_incoming_fks'
#                     p_force => null on a live restored key (#951 bullet 1).
#   tests/268 part B  runs transmute through dblink on each refusal case (a null argument, a negative-scale
#                     numeric key whose step its bounds cannot represent, a bound past the column's
#                     precision, NOT VALID incoming and outgoing keys, a NaN key, and on 18 NOT ENFORCED
#                     keys) and asserts each refused before any commit, by identity.
#   tests/269         resumes claims an older install could have left: hi = NaN (#952 bullet 2) and a hi
#                     the column cannot hold, each refused in the first transaction; a finite claim resumes.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site:
#   null_refusal_dropped_<routine>    -- one per public routine of the core (28): its up-front
#                                        _refuse_null_arguments call neutralised, the pre-#951 shape.
#                                        tests/268 part A (and A1 for suspend_incoming_fks).
#   transmute_null_obtain_unlisted    -- transmute's p_obtain left out of the list again (#581's own check
#                                        answers instead of the shared refusal). tests/268 part A.
#   set_retain_refuses_null_retain    -- the over-correction: set_retain refuses its documented null.
#                                        tests/268 part A, the documented-null assertion.
#   id_step_contract_dropped          -- transmute no longer asks _id_step_contract (#952 bullet 1).
#                                        tests/268 part B2.
#   bound_contract_call_dropped       -- transmute no longer asks _control_bound_contract of the claim's
#                                        bound. tests/268 B3, tests/269 parts A and B.
#   bound_contract_finiteness_dropped -- the contract's finiteness arm skipped. tests/269 part A.
#   bound_contract_representability_dropped -- its round trip through the column's type skipped.
#                                        tests/268 B3, tests/269 part B.
#   incoming_gate_shared_check_dropped -- _transmute_incoming_gate no longer calls _refuse_unconvertible_keys.
#                                        tests/268 B4 (and tests/259).
#
# The NOT ENFORCED arm of _refuse_unconvertible_keys has no mutation here: it can only fire on PostgreSQL 18,
# and the discriminate track runs 17, where a mutant of it is indistinguishable from the clean install.
# tests/268 parts B7 and B8 run it on the core track's PostgreSQL 18.
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
  q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  if ! q -q -c "create database $DB" >/dev/null 2>&1 \
     || ! q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists pgtap;" >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "the scratch database $DB was set up" "$file"
    fail=1
    return
  fi
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

run_file 268_shared_preflight_refusals_test.sql "every entry point refuses what the core refuses, up front"
run_file 269_resume_recorded_bounds_test.sql "a resume refuses a recorded bound the column cannot hold"

q -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
