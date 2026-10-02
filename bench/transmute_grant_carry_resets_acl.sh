#!/usr/bin/env bash
# transmute_grant_carry_resets_acl.sh <container> <db> [install.sql]
#
# Run tests/235_transmute_grant_carry_resets_acl_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutations put back (issue #838):
# transmute's parent is born with the transmuting role's ALTER DEFAULT PRIVILEGES, and a grant carry that
# only GRANTs the table's privileges onto it left a privilege REVOKEd on the table held on the parent. The
# carry is pgpm._acl_carry_ddl, shared with pgpm_hypertable's swap, whose first statement calls
# pgpm._acl_reset. The file is the acceptance test; this wrapper exists so the mutations have a guard the
# discriminate track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# THREE mutations are required to fail against it (bench/mutations/mutate.py):
#   acl_carry_additive         -- _acl_carry_ddl emits no reset, the pre-fix additive carry. Parts A, B, C.
#   acl_reset_no_owner_default -- the reset forgets the owner's ALL when the source's ACL is the NULL
#                                 default, so the parent's owner holds nothing at all. Part B.
#   acl_reset_spares_owner     -- the reset revokes only from the roles the ACL names, untransmute's shape,
#                                 which finds nobody on a parent born with a NULL ACL, so the first replayed
#                                 GRANT gives the owner back a privilege it had revoked. Part C.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/235_transmute_grant_carry_resets_acl_test.sql}"
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
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "transmute's parent holds exactly the table's grants" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "transmute's parent holds exactly the table's grants" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
