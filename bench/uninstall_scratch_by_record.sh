#!/usr/bin/env bash
# Run tests/282_uninstall_sweeps_scratch_by_record_test.sql against an ARBITRARY copy of pgpm_core/uninstall.sql,
# so bench/discriminate.sh can point it at a mutant (issue #985).
#
# The default matrix already runs that file on every version and channel, reading the real uninstall.sql with
# \ir, so this script adds nothing on correct code beyond being the clean-code half of its mutant's pair. What
# it adds is the standing proof that the file DISCRIMINATES. Its load-bearing assertions are negatives ("the
# renamed copy, delta, function and trigger are gone"), and a negative is equally satisfied by a fixture that
# recorded nothing or an uninstall that never ran. The file pins both with liveness witnesses (each object is
# recorded under its new name and still carries the copy's comment, the trigger logged a write; the pgpm schema
# is gone after), and its survivors (a recorded copy whose table is gone, the operator's table under the copy's
# old name) are positives that a sweep by name, or one that ignores whose rows a copy holds, break.
#
# The mutation it is required to fail against (bench/mutations/mutate.py), of uninstall.sql:
#   uninstall_scratch_record_defers_commented -- the record sweep takes only a recorded object that has lost the
#                                                copy's comment and leaves the rest to the comment sweeps, which
#                                                need the _pgpm_delta / _pgpm_dest name: pre-#985 exactly
#
# Usage: uninstall_scratch_by_record.sh <container> <db> [uninstall.sql]
# The third argument is the UNINSTALL script under test, not an install: pgpm_core/install.sql is what gets
# installed, always. It is a path inside the container, which the file reads with psql's \ir. Runs on the plain
# core image (it needs pgtap and pg_prove, both of which it has).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; UNINSTALL="${3:-/repo/pgpm_core/uninstall.sql}"
INSTALL=/repo/pgpm_core/install.sql
TEST_FILE=/repo/tests/282_uninstall_sweeps_scratch_by_record_test.sql
LABEL="uninstall drops every recorded scratch object by oid"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A module that will not install is NOT a pass, and neither is a mutant path that is not there (\ir would fail,
# the file would die early, and the guard would read as having caught the defect). Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi
if ! docker exec "$C" test -r "$UNINSTALL"; then
  printf 'FAIL  %-58s %s\n' "the uninstall script under test exists" "$UNINSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set uninstall=$UNINSTALL $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit status covers "fewer assertions ran than the plan promised". What it cannot tell apart
  # from a real failure is a run that never reached the database, and discriminate.sh reads a non-zero exit
  # as "the guard caught the defect", so the count is asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
