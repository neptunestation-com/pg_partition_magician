#!/usr/bin/env bash
# Run tests/184_regrain_child_oid_sites_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant (issue #707).
#
# The file is plain pgTAP and the default matrix already runs it, so on correct code this adds nothing.
# What it adds is the standing proof that the file DISCRIMINATES. Most of its assertions are negatives
# ("the unrelated table was not attached", "keeps both of its own triggers", "no relation was created",
# "the squatted cell is not built"), each equally satisfied by a run in which the site under test was
# never reached. Every section pins its setup with liveness witnesses (the squatter carries the _ck so an
# ATTACH would go through, the renamed source really carries the regrain's triggers, the sub-range really
# renders the held name, the type really holds a cell's name, and each refused call goes through once the
# obstacle is gone), and pointing it at a mutant checks, every CI run, that the assertions then FAIL.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site of #707:
#   regrain_swap_attaches_named_relation  -- the swap attaches each copy by its recorded name (A)
#   regrain_cancel_triggers_by_name       -- regrain_cancel drops the regrain triggers by name (B)
#   regrain_copy_row_other_bounds         -- the create branch records a held name on conflict do nothing (C)
#   obtain_name_relations_only            -- obtain asks to_regclass alone whether a cell's name is free (D)
#   transmute_orphan_guard_relations_only -- the orphan-child guard looks in pg_class alone (E)
#
# Usage: regrain_child_oid_sites.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). RCO_TEST_FILE
# overrides the test file's path inside the container, for running from a worktree that is mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${RCO_TEST_FILE:-/repo/tests/184_regrain_child_oid_sites_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised" -- a file
  # that dies early reports a bad plan and exits non-zero. What it cannot tell us apart from a real
  # failure is a run that never reached the database at all, and in THIS script that distinction
  # matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the defect",
  # so a harness broken enough to fail against everything would be reported as proving the mutation.
  # Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "regrain and obtain act on the relations pgpm.part recorded" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "regrain and obtain act on the relations pgpm.part recorded" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
