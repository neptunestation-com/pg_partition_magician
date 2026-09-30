#!/usr/bin/env bash
# Run tests/timescale/db/22_from_hypertable_conservation_identity_test.sql against an ARBITRARY copy of
# pgpm_hypertable/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# Same shape and same reason as bench/hypertable_late_appends.sh: run_timescale fails the track on any
# `ERROR:` line, so a refusing cutover has to be wrapped by throws_like, and a cutover that WRONGLY
# proceeds cannot be observed committing -- it dies at its own COMMIT inside the function context and
# rolls back into the same end state as a correct refusal. The refusal's message, pinned down to the
# EQUAL counts and "not the same rows", is therefore the whole guard for parts A, B and C of the file,
# and pointing the file at a mutant is the only standing proof that it is load-bearing. Part D is a
# positive assertion (the same bag of rows after a successful cutover), which a mutant can only fail
# honestly.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   hypertable_cutover_conservation_by_count -- the pre-#653 check: count(*) of the source against the
#                                               destination's carried-in count, no content fingerprint.
#                                               Compensating changes (a delete plus a late append behind
#                                               the watermark, an update of a copied row, a write that
#                                               bypassed the capture trigger) pass it, so parts A, B and C
#                                               see no refusal and the cutover runs on to its COMMIT.
#
# Usage: hypertable_cutover_conservation.sh <container> <db> [pgpm_hypertable/install.sql]
# Runs on the TIMESCALE track's container, which is why the mutation sits in MUTATION_TRACK=timescale;
# run_timescale also runs it once against the clean install, the half of the pair discriminate.sh does
# not.
#
# psql, not pg_prove: the supabase/postgres image has no pg_prove, so TAP is parsed out of psql -tAq here
# exactly as run_timescale does, including the ERROR: check -- a mutant that dies with a raw error
# instead of a failed assertion must not read as a pass.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
TEST_FILE=/repo/tests/timescale/db/22_from_hypertable_conservation_identity_test.sql
fail=0

q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@"; }

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
q -d postgres -q -c "create database $DB" >/dev/null 2>&1
q -d postgres -q -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened. The core goes in first and is
# never the mutated file -- only pgpm_hypertable is.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$HT"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the timescale fixtures loaded" "tests/timescale/fixtures.sql"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1)
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+ -')
  # Two failure shapes, reported apart. A file that died early leaves a raw ERROR: and few or no
  # assertions, which must NOT read the same as assertions that ran and failed -- discriminate.sh
  # treats any non-zero exit as "the guard caught the defect", so a harness broken enough to fail
  # against everything would otherwise be reported as proving the mutation.
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  # The plan shortfall too, the verdict run_timescale applies (#601): an assertion that silently never
  # ran must not read as a pass.
  if echo "$out" | grep -qE '^# Looks like you planned'; then
    printf 'FAIL  %-58s %s\n' "every planned assertion ran" "$(echo "$out" | grep -E '^# Looks like you planned' | head -1)"
    fail=1
  fi
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "the cutover swaps only when both sides hold the same rows" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "the cutover swaps only when both sides hold the same rows" "$ran ran, $bad failed"; fail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
