#!/usr/bin/env bash
# schema_swap_leftovers.sh <container> <db> [install.sql]
#
# Run tests/359_schema_swap_relation_leftovers_test.sql and tests/360_schema_swap_function_leftovers_test.sql against
# an ARBITRARY copy of pgpm_core/install.sql, so that bench/discriminate.sh can show the files catch the defects their
# mutations put back (the schema-swap class, closed as one lever with scripts/check_by_name_after_wait.py): the
# statements the per-family fixes (#1399, #1400, #1402) did not own named a relation or a function pgpm identified by
# oid through a name rendered before the statement waited for its lock, and checked nothing after. A schema renamed
# aside during the wait, with a namesake committed in its place, was what they reached: a namesake's maximum read as
# the frontier, a partition made under a namesake parent, an abandoned detach left pending while the FINALIZE met the
# namesakes, a namesake table or function handed to another owner, an operator's function replaced by pgpm's capture
# or dropped in place of pgpm's. The files are the acceptance tests; this wrapper exists so the mutations have a guard
# the discriminate track can run against the mutant, in the shape of bench/transmute_by_oid.sh.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per clause:
#   frontier_native_unlocked           -- _frontier_native reads the parent with no lock by oid first (359 A).
#   create_partition_parent_unlocked   -- _create_partition's CREATE ... PARTITION OF waits by the parent's name (359 B).
#   detach_reap_finalize_unlocked      -- _detach_reap's FINALIZE waits by the names it read before (359 F).
#   own_like_parent_unchecked          -- _own_like_parent's ALTER ... OWNER is not checked by its effect (360 C).
#   scratch_mint_fn_unchecked          -- _scratch_mint_fn's ALTER FUNCTION ... OWNER is not checked (360 D).
#   scratch_owner_follow_fn_unchecked  -- _scratch_owner_follow's function branch is not checked (360 E).
#   capture_fn_create_or_replace       -- the capture function is minted by CREATE OR REPLACE again (360 G).
#   drop_fn_by_oid_unchecked           -- pgpm._drop_fn_by_oid does not ask whether the oid is gone (360 H).
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_DIR overrides the tests' directory inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
DIR="${TAP_GUARD_TEST_DIR:-/repo/tests}"
TEST_FILES="$DIR/359_schema_swap_relation_leftovers_test.sql $DIR/360_schema_swap_function_leftovers_test.sql"
LABEL="statements reach what pgpm identified, or refuse"
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
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILES" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -40
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
