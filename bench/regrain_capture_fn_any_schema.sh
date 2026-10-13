#!/usr/bin/env bash
# regrain_capture_fn_any_schema.sh <container> <db> [install.sql or uninstall.sql under test]
#
# Run tests/338_regrain_capture_fn_any_schema_test.sql against an ARBITRARY copy of pgpm_core/install.sql or of
# pgpm_core/uninstall.sql, so that bench/discriminate.sh can show the file catches the defect each of its
# mutations puts back (issue #1271):
# pgpm._regrain_capture_names looked the recorded regrain capture function up by its oid only inside the
# DELTA's current schema, so after ALTER TABLE <delta> SET SCHEMA (or ALTER FUNCTION <fn> SET SCHEMA) it
# resolved to null, and untransmute and uninstall.sql dropped the delta and left the SECURITY DEFINER function
# behind. The file is the acceptance test; this wrapper exists so the mutations have a guard the discriminate
# track can run against the mutant, in the shape of bench/retain_recall_moved_parent.sh.
#
# The file's load-bearing assertions are negatives (the recorded function is gone after each exit), each paired
# with a witness that the function was recorded and where it sat, and with a namesake of the operator's in the
# delta's schema that must survive, so a drop by name in the wrong schema is not a pass either. The uninstall
# half reads the uninstall script with \ir, against the install under test. Part F runs that script against a
# resolver with the row type and the contract it had before fn_nsp (the script is run against installs older
# than itself), inside a transaction it rolls back before parts D and E.
#
# FOUR mutations it is required to fail against (bench/mutations/mutate.py). Two of install.sql:
#   regrain_capture_fn_in_delta_schema              -- the lookup confined to the delta's schema again, the
#                                                      pre-fix shape. Parts A, B, D and E.
#   untransmute_capture_fn_dropped_in_delta_schema  -- the function resolved anywhere but dropped by name in the
#                                                      delta's schema: the recorded one survives and the
#                                                      operator's namesake beside the delta goes. Parts A and B.
# and two of uninstall.sql:
#   uninstall_capture_fn_dropped_in_delta_schema    -- the same drop site in the other exit. Parts D and E.
#   uninstall_capture_fn_nsp_read_bare              -- fn_nsp read as a bare column, which an older resolver
#                                                      does not return, so the script stops with 42703. Part F.
#
# The third argument is the file under test: an install.sql, or (for a mutant of pgpm_core/uninstall.sql,
# recognised by the mutation's MUTATION_SRC, as bench/recorded_identity.sh recognises its own) the uninstall
# script the file reads with \ir. Whichever it is not is the real one. Runs on the plain core image (pgtap and
# pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; UNDER_TEST="${3:-/repo/pgpm_core/install.sql}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/338_regrain_capture_fn_any_schema_test.sql}"
INSTALL=/repo/pgpm_core/install.sql
UNINSTALL=/repo/pgpm_core/uninstall.sql
LABEL="untransmute and uninstall drop a moved capture function"
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

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi
# Likewise an uninstall path that is not there: \ir would fail, the file would die early, and the guard would
# read as having caught the defect.
if ! docker exec "$C" test -r "$UNINSTALL"; then
  printf 'FAIL  %-58s %s\n' "the uninstall script under test exists" "$UNINSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB --set uninstall=$UNINSTALL $TEST_FILE" 2>&1)
  rc=$?
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
