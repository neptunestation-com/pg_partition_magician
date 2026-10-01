#!/usr/bin/env bash
# Run tests/timescale/db/25_from_hypertable_replica_role_capture_test.sql against an ARBITRARY copy of
# pgpm_hypertable/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# Same shape and same reason as bench/hypertable_late_appends.sh and bench/hypertable_cutover_identity.sh:
# run_timescale fails the track on any `ERROR:` line, so a refusing cutover has to be wrapped by
# throws_like, and a cutover that WRONGLY proceeds cannot be observed committing -- it dies at its own
# COMMIT inside the function context and rolls back into the same end state as a correct refusal. The
# refusal's message, with the unmatched count and the key it names, is therefore the whole guard for
# parts A and B of the file, and pointing the file at a mutant is the only standing proof that the message
# assertion is load-bearing. Parts C and D are positive assertions (every origin write survives by
# identity, no false refusal), which a mutant can only fail honestly.
#
# THREE mutations are required to fail against it, one per half of the #654 fix and one for its order
# (bench/mutations/mutate.py):
#   hypertable_cutover_untracked_unchecked -- the refusal disabled: the pre-#654 count-only cutover on the
#                                             tracking path. Breaks PARTS A and B (no refusal; the
#                                             replica-role update is reverted by the swap).
#   hypertable_cutover_no_horizon_trusted  -- a delta with no recorded horizon read as nothing to check.
#                                             Breaks PART B only.
#   hypertable_cutover_refusals_reordered  -- the refusal moved after the count-and-fingerprint check
#                                             (review pass 5 seed S9): still refused, but as a fingerprint
#                                             mismatch naming no key. Breaks the refusal-message
#                                             assertions of PARTS A and B.
#
# Usage: hypertable_replica_capture.sh <container> <db> [pgpm_hypertable/install.sql]
#   e.g. hypertable_replica_capture.sh pgpm_test-timescale pgpm_perf106
# Runs on the TIMESCALE track's container, which is why these mutations sit in MUTATION_TRACK=timescale.
#
# psql, not pg_prove: the supabase/postgres image has no pg_prove, so TAP is parsed out of psql -tAq here
# exactly as run_timescale does, including the ERROR: check -- a mutant that dies with a raw error
# instead of a failed assertion must not read as a pass.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
TEST_FILE=/repo/tests/timescale/db/25_from_hypertable_replica_role_capture_test.sql
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
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "no untracked write is reverted by the swap" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "no untracked write is reverted by the swap" "$ran ran, $bad failed"; fail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
