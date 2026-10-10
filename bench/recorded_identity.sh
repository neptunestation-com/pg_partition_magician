#!/usr/bin/env bash
# recorded_identity.sh <container> <db> [install.sql or uninstall.sql under test]
#
# Guard the recorded-identity lever (issue #872): every relation pgpm recorded (a partition, a regrain copy,
# the table an incoming key references) is reached through its recorded identity, the oid, never as <the
# parent's CURRENT schema>.<name> or by a name recorded before ALTER TABLE ... SET SCHEMA or RENAME moved it.
#
# It runs two pgTAP files against the module under test, and each must pass whole:
#   tests/239_moved_parent_recorded_identity_test.sql  the conformance suite: one table moved before every
#       lifecycle stage (a suspended key's restore, a regrain with a copy part-filled, archive and retain,
#       untransmute, uninstall), each stage with a namesake planted where the old resolution would land
#   tests/240_dropped_fk_by_identity_test.sql  the incoming key replayed against its referenced table by
#       oid after a move, a rename, a regrain swap and untransmute, and uninstall's "re-added by hand"
#       exemption matched by the key's identity (referencing table AND confrelid), not its name
# Their LIVENESS lines prove each fixture reached the state the assertion is about: the namesake exists
# where the old resolution lands, the key is suspended, the copy is part-filled.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site of the class:
#   regrain_copy_rel_parent_schema             _regrain_copy_rel looks a copy up in the parent's schema
#                                              (the swap gate, the attach and the reconcile all ask it)
#   regrain_copy_branch_parent_schema          the copy branch finds and makes copies in the parent's schema
#   regrain_coverage_reset_parent_schema       the swap's archive_coverage_reset names the source there
#   restore_fk_replays_recorded_definition     restore_incoming_fks replays the recorded text verbatim
#   untransmute_fk_replays_recorded_definition untransmute replays it verbatim
#   uninstall_fk_exempt_by_name                uninstall.sql exempts a record for any key of that NAME
#
# The third argument is the file under test: an install.sql, or (for a mutant of pgpm_core/uninstall.sql,
# recognised by the mutation's MUTATION_SRC, as bench/wrapper_tap_verdicts.sh recognises its mutants) the
# uninstall script the files read with \ir. Whichever it is not is the real one. Runs on the plain core
# image (pgtap and pg_prove). RECORDED_IDENTITY_TESTS overrides the test files' paths inside the container.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; UNDER_TEST="${3:-/repo/pgpm_core/install.sql}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="${RECORDED_IDENTITY_TESTS:-/repo/tests/239_moved_parent_recorded_identity_test.sql /repo/tests/240_dropped_fk_by_identity_test.sql}"
INSTALL=/repo/pgpm_core/install.sql
UNINSTALL=/repo/pgpm_core/uninstall.sql
fail=0

base=$(basename "$UNDER_TEST")
src=$(python3 - "$ROOT/bench/mutations" "${base%.*}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import mutate
print(mutate.MUTATION_SRC.get(sys.argv[2], ""))
PY
)
if [ "$src" = "pgpm_core/uninstall.sql" ] || [ "$base" = "uninstall.sql" ]; then
  UNINSTALL="$UNDER_TEST"
else
  INSTALL="$UNDER_TEST"
fi

q() { docker exec "$C" psql -U postgres "$@"; }

for t in $TESTS; do
  label="$(basename "$t" .sql)"
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1
  # A mutant that will not even install, or an uninstall path that is not there, is NOT a pass: the file
  # would die early for a reason that has nothing to do with what it asserts. Say which happened.
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-62s %s\n' "the module under test installed" "$INSTALL"
    fail=1; continue
  fi
  if ! docker exec "$C" test -r "$UNINSTALL"; then
    printf 'FAIL  %-62s %s\n' "the uninstall script under test exists" "$UNINSTALL"
    fail=1; continue
  fi
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set uninstall=$UNINSTALL $t" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit covers a plan shortfall; a run that never reached the database must not read as a
  # catch, so the count is asserted separately and printed either way
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-62s %s\n' "$label: every stage acts on the recorded relations" "$ran ran"
  else printf 'FAIL  %-62s %s\n' "$label: every stage acts on the recorded relations" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-62s %s\n' "LIVENESS: $label: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
done

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
