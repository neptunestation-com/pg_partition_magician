#!/usr/bin/env bash
# Run tests/archive/db/51_to_s3_multi_heap_relation_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 51 is a plain pgTAP file and the archive track already runs it, so on
# correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# Its contract (issue #1168) is that archive.to_s3 of a relation with more than one heap (a partitioned
# table or an inheritance parent, which the synchronous export accepts in the parent's schema) completes
# with nothing writing to it, and its object holds every row once. An export that never put a page
# boundary between two rows of the same control value at the same ctid in two heaps satisfies that too,
# so the file pins the premise with witnesses (a page is one row; each relation holds its twins at (0,1)
# in two heaps) and states each object by its rows' identities, and pointing it at the mutants every CI
# run checks that those assertions fail when the cursor leaves the heap out again. The same holds for a
# relation whose control column holds NULL (parts C and D): such a row is paged in a run of its own after
# every other row, and the file bounds every export with a statement_timeout, so the mutant whose export
# never ends fails an assertion by name instead of hanging the run. And the relation's column of the
# control column's name may have another type than the parent's (parts E and F): the cursor is cast back as
# the relation's own type, with its typmod (parts H to J), and a relation with no such column is refused by
# name (part G). The column must be a scalar with a btree ordering: a composite, an array and a type with no
# ordering are refused by name (parts K to M), a domain pages as its base type (part N), an enum pages (part O).
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   to_s3_cursor_heap_unkeyed    -- the next-page predicate compares (control, ctid) with the cursor,
#                                   without the heap, so the second twin is skipped and the conservation
#                                   check refuses the quiescent export (parts A and B)
#   to_s3_cursor_null_blind      -- the cursor as it was, NULL-blind: a NULL control value is never paged
#                                   with small pages (part C, refused), and a page ending on one restarts
#                                   the read forever (part D, cancelled)
#   to_s3_cursor_null_restart    -- the first run admits a NULL control value, so part D never ends
#   to_s3_cursor_null_run_unread -- no NULL run follows the first, so parts C and D are refused
#   to_s3_cursor_parent_type     -- the cursor is cast back as the PARENT's control column type, so a
#                                   timestamptz relation under a date or timestamp parent re-reads the
#                                   row each page ended on and never ends (parts E and F, cancelled),
#                                   and a relation with no such column is not refused by name (part G)
#   to_s3_cursor_type_typmod_dropped -- the cast type is spelled without its typmod, so char(3) and bit(3)
#                                   cast as char(1) and bit(1) cut the cursor and never end (parts H, J)
#   to_s3_cursor_type_unrefused  -- a column of a type the page query cannot page is not refused: a
#                                   composite (part K) pages, an array (part L) never ends, and json
#                                   (part M) fails on an unnamed operator error
#   to_s3_cursor_domain_checked  -- the cursor is cast as the domain, not its base type, so a NOT VALID
#                                   CHECK raises on the rows it does not admit (part N)
#
# Usage: archive_to_s3_multi_heap.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same network: the file PUTs
# two NDJSON objects. run_archive creates the bucket before any test runs; run_discriminate does not, so
# it is created here too, idempotently and the same way (a SigV4 PUT from the curl image; 200 is
# created, 409 is already there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_MULTI_HEAP_TEST_FILE:-/repo/tests/archive/db/51_to_s3_multi_heap_relation_test.sql}"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

# --- MinIO: ready, and the bucket the file points at exists ---------------------------------------
ready=""
for _ in $(seq 1 60); do
  if docker run --rm --network "$NET" curlimages/curl -sf http://minio:9000/minio/health/cluster >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ -z "$ready" ]; then
  printf 'FAIL  %-58s %s\n' "MinIO reported ready (/minio/health/cluster)" "not within 60 s"
  exit 1
fi
code=$(docker run --rm --network "$NET" curlimages/curl -s -o /dev/null -w '%{http_code}' \
         --aws-sigv4 aws:amz:us-east-1:s3 -u minioadmin:minioadmin \
         -X PUT http://minio:9000/archive-test-bucket) || code="curl exit $?"
if [ "$code" != 200 ] && [ "$code" != 409 ]; then
  printf 'FAIL  %-58s %s\n' "the MinIO bucket exists" "PUT returned $code"
  exit 1
fi

# --- the database: fixtures, core, and the archive module under test ------------------------------
q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null 2>&1

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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "to_s3 pages every row, multi-heap or NULL control (#1168)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "to_s3 pages every row, multi-heap or NULL control (#1168)" "$ran ran"; fail=1; fi
  # A failure is only evidence against the code when the setup it depends on held. Name any
  # LIVENESS witness that failed, so a mutant run that fails for the fixture's sake reads as that.
  if echo "$out" | grep -qE '^not ok [0-9]+ - .*LIVENESS'; then
    printf 'FAIL  %-58s %s\n' "every LIVENESS witness held" "no (see above)"
    fail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
