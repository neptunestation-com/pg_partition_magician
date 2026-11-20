#!/usr/bin/env bash
# Run three pgTAP files against an ARBITRARY copy of pgpm_core/install.sql, so bench/discriminate.sh can point them
# at a mutant. Each is a catalog state transmute read as something else, and refused for the wrong cause:
#   tests/376  a REPLICA IDENTITY USING INDEX whose index was dropped (PostgreSQL's NOTHING) was refused by
#              transmute's step 9d as an index it had not carried, and by untransmute as one with no copy to
#              hand back; both carry NOTHING now (issue #1036).
#   tests/379  the staging CREATE's and the first RENAME's 23505 arms named the first holder of the names they
#              take, an implicit array type committed beforehand that PostgreSQL moves aside included, not the
#              enum in flight the statement collided with (issue #1217).
#   tests/381  a bare unique index an incoming foreign key references read as backing a constraint, since the key's
#              pg_constraint row carries it as conindid, so transmute fell through as keyless and refused with
#              incoming-key remedies that do not work (issue #1333 bullets 4 and 5).
# Each file runs in a database of its own, and each pins its state with LIVENESS lines, so a failure that is
# only a premise reads as a starved fixture, not a catch.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   transmute_dropped_identity_index_refused    -- step 9d refuses the dropped identity index again (376 part A)
#   untransmute_dropped_identity_index_refused  -- untransmute refuses it again (376 part B)
#   staging_create_names_held_unskipped         -- the staging CREATE's 23505 arm without p_skip (379 part A)
#   monolith_rename_names_held_unskipped        -- the first RENAME's 23505 arm without p_skip (379 part B)
#   bare_unique_any_constraint                  -- _transmute_bare_unique asks of the index alone again (381)
#
# Usage: transmute_state_reads.sh <container> <db> [install.sql]
# Runs on the plain core image (pgtap, pg_prove and dblink). TRANSMUTE_STATE_READS_TEST_DIR overrides the
# directory of the test files inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_DIR="${TRANSMUTE_STATE_READS_TEST_DIR:-/repo/tests}"
FILES=(376_dropped_identity_index_carried_as_nothing_test.sql 379_staging_create_names_new_holder_test.sql 381_bare_unique_incoming_fk_test.sql)
LABEL="transmute reads the state it is refusing for what it is"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

for f in "${FILES[@]}"; do
  q -q -c "drop database if exists $DB with (force)" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

  # A mutant that will not even install is NOT a pass: say which happened.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
    fail=1
    break
  fi

  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_DIR/$f" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL (${f%%_*})" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL (${f%%_*})" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -q -c "drop database if exists $DB with (force)" >/dev/null 2>&1
exit "$fail"
