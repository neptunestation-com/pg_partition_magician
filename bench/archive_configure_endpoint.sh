#!/usr/bin/env bash
# Run tests/archive/db/53_configure_endpoint_canonical_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL (issue #1269). Test 53 is a plain pgTAP file and the archive track already runs it,
# so on correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# Its contract is that an S3-compatible endpoint's trailing slashes are not part of it: archive.configure stores
# the endpoint without them, both signers drop them from the endpoint they are handed, and an export through an
# endpoint spelled 'http://minio:9000/' lands at the key instead of failing every PUT with HTTP 400 at
# '//<bucket>/<key>'. And configure refuses by name an endpoint the signers cannot use (no http(s) scheme, no
# host, a query string or a fragment; credentials before the host; an empty, '.' or '..' path segment) and a
# bucket that is not a bare bucket name ('/my-bucket' addressed '//my-bucket/<key>'). The file's own witnesses (the same export through the endpoint spelled
# without the slash lands both rows, each key cleared and witnessed absent first) say the store was reachable;
# a failure of a LIVENESS witness alone is reported as that, not as a catch.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   archive_endpoint_trailing_slash_kept -- archive._s3_endpoint_canonical hands the endpoint back as given, so
#                                           configure stores the slash and both signers address //<bucket>/<key>
#   archive_endpoint_unrefused           -- configure takes an endpoint with no scheme, no host, a query string
#                                           or a fragment, found out only at the first PUT
#   archive_endpoint_userinfo_unrefused  -- configure takes an endpoint with user@ before the host, signed as
#                                           part of the Host, so every request is refused 403 (part F)
#   archive_endpoint_dot_segment_unrefused -- configure takes a path prefix with an empty, '.' or '..' segment,
#                                           resolved away while the signature covers it (part F)
#   archive_bucket_unrefused             -- configure takes '/archive-test-bucket', which addresses
#                                           '//archive-test-bucket/<key>' and gets HTTP 400 (part G)
#
# Usage: archive_configure_endpoint.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same network: the file PUTs and
# reads back an NDJSON object. run_archive creates the bucket before any test runs; run_discriminate does not,
# so it is created here too, idempotently and the same way (a SigV4 PUT from the curl image; 200 is created,
# 409 is already there), after waiting for MinIO to report ready. PGPM_TEST_NET names the network MinIO answers
# on (default pgpm_test_net, the compose network).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree mounted somewhere other than /repo can point it at its own copy of the file.
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/archive/db/53_configure_endpoint_canonical_test.sql}"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
LABEL="an endpoint's trailing slash addresses the key; a bad one is refused (#1269)"
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
