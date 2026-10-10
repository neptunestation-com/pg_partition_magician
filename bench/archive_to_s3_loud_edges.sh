#!/usr/bin/env bash
# Run tests/archive/db/28_to_s3_loud_edges_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 28 is a plain pgTAP file and the archive track already runs it, so
# on correct code this script adds nothing. What it adds is the standing proof that the file
# DISCRIMINATES. Its central claim is a negative, "no multipart upload is left in flight after an
# export broken inside its initiate POST", and an export that never initiated an upload satisfies it
# too. The file pairs it with witnesses (the store created the upload, listed it in flight when the
# export broke, no part was stored, so archive.to_s3 never saw the id), but nothing re-checks that the
# claim would fail if the sweep were taken out. Pointing the file at a mutant does, on every CI run.
# The same file also pins archive.configure's two bounds (a part_bytes under S3's 5 MiB minimum, a
# fetch_rows under 1) and archive.to_s3's refusal of a fetch_rows under 1, so each has a mutant too.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   to_s3_initiate_orphan_unaborted  -- archive.to_s3's two handlers abort only a recorded UploadId,
#                                       the pre-#636 shape: a cancel or an error inside the initiate
#                                       POST, after the store created the upload, leaves it in flight
#   configure_part_bytes_under_s3_min -- archive.configure stores a positive part_bytes under 5 MiB,
#                                       which fails every export of more than one part at complete
#                                       with EntityTooSmall, after uploading every part
#   configure_fetch_rows_unbounded   -- archive.configure stores any p_fetch_rows and archive.to_s3
#                                       reads it: 0 trips the conservation check, a negative fails on LIMIT
#   abort_sweep_no_exact_key_filter  -- archive._s3_abort_uploads_at loses its exact-key filter, so a
#                                       prefix listing (S3's) has it send an abort naming the upload of
#                                       another object at a longer key (#711: the file's stand-in now
#                                       answers the listing the way S3 does, since MinIO lists one key)
#
# Usage: archive_to_s3_loud_edges.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same compose network: the
# file's initiate exports are real multipart uploads, and it lists in-flight uploads from MinIO.
# run_archive creates the bucket before any test runs; run_discriminate does not, so it is created here
# too, idempotently and the same way (a SigV4 PUT from the curl image; 200 is created, 409 is already
# there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
TEST_FILE="${PGPM_LOUD_EDGES_TEST_FILE:-/repo/tests/archive/db/28_to_s3_loud_edges_test.sql}"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

# --- MinIO: ready, and the bucket the fixtures point at exists ------------------------------------
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
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell us apart from a real failure is a run that never reached the database at all, and
  # here that matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the
  # defect", so a harness broken enough to fail against everything would be reported as proving the
  # mutation. Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "archive.to_s3 edges refused or cleaned up (#636)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "archive.to_s3 edges refused or cleaned up (#636)" "$ran ran"; fail=1; fi
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
