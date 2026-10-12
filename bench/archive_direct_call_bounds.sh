#!/usr/bin/env bash
# Run tests/archive/db/54_archive_direct_call_bounds_session_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 54 is a plain pgTAP file and the archive track already runs it, so on
# correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# Its contract (issue #814, the archive bullet) is that a direct archive_fn strategy call names its object
# after the instant (or the id) the call READ, read once on the grid's clock: from a 'SQL, DMY' session the
# text '02/01/2024' is 2 January to the read, so the object is keyed 2 January, never 1 February, which is how
# the stem's own pinned parse read it; an offset-less bound is read in the grid's partition_tz, never the
# caller's TimeZone, so a date grid's '2024-01-02' is keyed by the cell's start, 00:00Z, from New York and from
# UTC alike (V-01 of the fix's verification); and an id bound spelled '0100' is keyed _100. Each claim is an
# EXACT key and the object's rows by identity, paired with witnesses that the session really reads the text as
# another instant than the grid does, and a negative ("nothing at the other key") that an upload that never
# happened would satisfy too; pointing the file at the mutants every CI run checks that those assertions fail
# when an encoder hands the stem the caller's spelling, or reads the bound in the caller's zone, again.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   archive_ndjson_bounds_caller_spelling  -- archive._encode_upload_ndjson_single keys its object by the lo
#                                             as the caller spelled it, so the stem's pinned parse names
#                                             another instant than the read (parts A, C and D)
#   archive_parquet_bounds_caller_spelling -- the same in archive._encode_upload_parquet (part B)
#   archive_ndjson_bounds_session_zone     -- archive._encode_upload_ndjson_single reads the lo in the
#                                             caller's TimeZone, so one cell gets one key per session zone
#                                             (parts C and E)
#   archive_parquet_bounds_session_zone    -- the same in archive._encode_upload_parquet (part F)
#
# Usage: archive_direct_call_bounds.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same network: the file PUTs
# NDJSON and Parquet objects and reads them back. run_archive creates the bucket before any test runs;
# run_discriminate does not, so it is created here too, idempotently and the same way (a SigV4 PUT from the
# curl image; 200 is created, 409 is already there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_DIRECT_CALL_BOUNDS_TEST_FILE:-/repo/tests/archive/db/54_archive_direct_call_bounds_session_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a direct strategy call keys the chunk it read (#814)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a direct strategy call keys the chunk it read (#814)" "$ran ran"; fail=1; fi
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
