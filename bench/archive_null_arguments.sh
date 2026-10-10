#!/usr/bin/env bash
# Run tests/archive/db/41_archive_null_arguments_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 41 is a plain pgTAP file and the archive track already runs it, so on
# correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# Its contract (issue #969 bullet 9, the shared-preflight lever #966 extended to the archive module) is that
# every public routine of pgpm_archive refuses a null argument with no meaning up front, naming it, and that
# an archive_fn strategy refuses an empty or inverted range before anything is read or sent, so no direct
# call can PUT an empty object over the key an archived chunk was written to. A sweep that enumerated
# nothing, or calls that never reached MinIO, satisfy "nothing was overwritten" too, so the file pins each
# part with witnesses (the routines it enumerated, the oid boundary taking the module's routines and none
# of the core's, the fence the sweep runs behind, the objects [1, 10) was archived to read back by rows and
# by bytes before the refused calls) and with identities (the objects read back after them).
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site of the fix:
#   archive_null_refusal_dropped_<routine>   -- one per public routine of schema archive (configure,
#                                               unconfigure, s3_url_encode, s3_signed_request,
#                                               s3_signed_request_bytea, to_s3, to_s3_parquet): its
#                                               _refuse_null_arguments call neutralised (part A)
#   null_refusal_dropped_archive_to_s3_ndjson, null_refusal_dropped_archive_to_s3_parquet
#                                            -- the same for the two archive_fn strategies in schema pgpm
#                                               (part A, and part B: the object is overwritten)
#   archive_ndjson_empty_range_unrefused     -- the NDJSON strategy does not ask archive._refuse_empty_range
#   archive_parquet_empty_range_unrefused    -- the Parquet strategy does not
#   archive_empty_range_compared_as_text     -- the bounds compared as text, where '9' > '10' (part B's
#                                               control refuses [9, 10) of an id grid)
#
# Usage: archive_null_arguments.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same network: the file PUTs
# NDJSON and Parquet objects through the strategies. run_archive creates the bucket before any test runs;
# run_discriminate does not, so it is created here too, idempotently and the same way (a SigV4 PUT from the
# curl image; 200 is created, 409 is already there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_ARCHIVE_NULL_ARGUMENTS_TEST_FILE:-/repo/tests/archive/db/41_archive_null_arguments_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "pgpm_archive refuses null arguments and empty ranges (#969)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "pgpm_archive refuses null arguments and empty ranges (#969)" "$ran ran"; fail=1; fi
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
