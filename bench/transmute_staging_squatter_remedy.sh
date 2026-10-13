#!/usr/bin/env bash
# transmute_staging_squatter_remedy.sh <container> <db> [install.sql]
#
# Run tests/340_transmute_staging_squatter_remedy_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1273): the
# staging-name refusal told the operator to type `drop table <schema>.<table>_pgpm_new` whatever kind of
# relation held the name, and against a sequence, view, materialized view, composite type or index that
# statement fails 42809, so the remedy did not repair the state the refusal described. The file is the
# acceptance test (each holder kind refused, its named remedy typed verbatim, the name freed and the same
# transmute call then converting; the holders no DROP can free on their own, a constraint's index, an identity
# column's sequence, an attached partition index and an extension's table and composite type; the holders
# PostgreSQL refuses to drop while something depends on them, a serial column's sequence, a view or
# materialized view another view reads, a composite type a column uses, a table or partitioned table a foreign
# key references and a unique index a foreign key uses, each with the rename typed in its place; a leftover
# partitioned table and a sequence a column merely owns as the controls); this wrapper exists so the mutations
# have a guard the discriminate track can run against each mutant, in the shape of
# bench/retain_recall_moved_parent.sh.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   staging_squatter_remedy_drop_table -- _transmute_refuse_staging_squatter routes every holder that is not
#                                         part of another object to the table refusal again, so each one is
#                                         told `drop table`, the pre-fix remedy. Parts A to E, I, J and O.
#   staging_squatter_dependents_not_for_tables -- a dependent is asked for of every holder but a table or a
#                                         partitioned table, so one a foreign key references is told
#                                         `drop table` again, which PostgreSQL refuses. Parts S and T.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/340_transmute_staging_squatter_remedy_test.sql}"
LABEL="the staging-name refusal names a remedy that frees the name"
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
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
