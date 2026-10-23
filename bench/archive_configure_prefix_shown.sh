#!/usr/bin/env bash
# Run tests/archive/db/55_configure_prefix_refusal_shown_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL (issue #1368). Test 55 is a plain pgTAP file and the archive track already runs it,
# so on correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# Its contract is pgpm_archive/README.md's: no refusal archive.configure raises quotes a value that holds an '@',
# whichever check raises it, and a refused value with no '@' is quoted as given. The p_prefix refusal (a '.' or
# '..' segment, #1260) printed its value raw, so 'user:password@host/../' put the password in the client's error
# and the server log; it now asks archive._configure_hides, the decision the endpoint and bucket refusals take
# through archive._configure_shown. The file's own witnesses (each answer is the p_prefix refusal, the stored row
# is unchanged, a value with no '@' is quoted) say the refusal under test fired; a failure of a LIVENESS witness
# alone is reported as that, not as a catch.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_prefix_refusal_shows_userinfo -- archive.configure's p_prefix refusal never asks
#                                            archive._configure_hides, so it prints a value holding an '@'
#
# Usage: archive_configure_prefix_shown.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove). The file sends no request, so MinIO is not needed.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree mounted somewhere other than /repo can point it at its own copy of the file.
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/archive/db/55_configure_prefix_refusal_shown_test.sql}"
LABEL="no p_prefix refusal prints a value holding an '@' (#1368)"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

# --- the database: fixtures, core, and the archive module under test ------------------------------
# Every setup step runs under ON_ERROR_STOP with its exit read, so the file can never be judged against a
# database that was not built.
q -q -c "drop database if exists $DB" >/dev/null 2>&1
if ! q -v ON_ERROR_STOP=1 -q -c "create database $DB" >/dev/null 2>&1 \
   || ! q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the database and its extensions were created" "no"
  fail=1
fi

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the archive fixtures installed" "no"
  fail=1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "no"
  fail=1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ARCHIVE_INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the archive module under test installed" "$ARCHIVE_INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit status covers "fewer assertions ran than planned"; the count separates a real
  # failure from a run that never reached the database, which discriminate.sh would otherwise read as
  # "the guard caught the defect".
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
  # A failure is only evidence against the code when the setup it depends on held. Name any
  # LIVENESS witness that failed, so a mutant run that fails for the fixture's sake reads as that.
  if echo "$out" | grep -qE '^not ok [0-9]+ - .*LIVENESS'; then
    printf 'FAIL  %-58s %s\n' "every LIVENESS witness held" "no (see above)"
    fail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
