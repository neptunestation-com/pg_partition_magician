#!/usr/bin/env bash
# acl_grantor_owner_partitions.sh <container> <db> [install.sql]
#
# Run the three files of the ACL class fixed together (issues #903 and #875) against an ARBITRARY copy of
# pgpm_core/install.sql, so that bench/discriminate.sh can show each catches the defect its mutations put
# back. Each file is the acceptance test of one contract; this wrapper exists so the mutations have a guard
# the discriminate track can run against the mutant, in the shape of bench/transmute_grant_carry_resets_acl.sh.
#   tests/254 -- every grant the conversions carry keeps its grantor (#903): _acl_carry_ddl replays a grant
#                another role made through its grant option as that role, or refuses.
#   tests/255 -- untransmute hands back exactly the parent's privileges, the owner's included (#875 bullet 2).
#   tests/256 -- a partition pgpm mints grants nothing to anyone but its owner (#875 bullet 1).
#
# FOUR mutations are required to fail against it (bench/mutations/mutate.py):
#   acl_carry_drops_grantor            -- every grant replayed by the converting role. tests/254.
#   untransmute_acl_reset_spares_owner -- untransmute's own reset back, sparing the owner. tests/255.
#   partition_acl_unreset              -- _create_partition leaves the default privileges. tests/256.
#   regrain_fine_child_acl_unreset     -- a regrain's fine child keeps them. tests/256.
#
# Each file runs in its own fresh database, as the suite runs it, and every file must report a plan it
# completed: a file that never reached its assertions (an install that failed, a fixture that errored) is a
# FAILURE here, never a pass. Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_DIR overrides
# the tests directory inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_DIR="${TAP_GUARD_TEST_DIR:-/repo/tests}"
FILES=(254_acl_carry_keeps_grantor_test.sql 255_untransmute_reset_takes_owner_test.sql 256_partition_acl_owner_only_test.sql)
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

for f in "${FILES[@]}"; do
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$f" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$f" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions of $f were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
