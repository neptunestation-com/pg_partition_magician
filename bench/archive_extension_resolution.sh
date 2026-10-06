#!/usr/bin/env bash
# Run tests/archive/db/44_archive_extension_resolution_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 44 is a plain pgTAP file and the archive track already runs it, so on
# correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# Its contract (issue #984) is that pgpm_archive reaches pgcrypto and the http extension through their own
# schemas, never through the caller's search_path: no shadow ahead of them on that path is ever handed the
# S3 secret key or run inside a signer, and a maintain() tick under an application search_path that does
# not name the extensions' schema archives like any other. "No shadow ran" is satisfied by shadows that
# were never on the path at all, so the file pins each with witnesses (every shadow resolves under the
# victim's path, the signers' requests were accepted and the objects read back hold their payloads, the
# ticks write-blocked what was due, the http types are invisible under `app`), and this re-checks that
# those witnesses would not hide a defect put back.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   archive_signer_hmac_through_search_path -- the pre-#984 shape: both signers pin no search_path and
#                                              HMAC is pgcrypto's hmac() called unqualified, so a shadow
#                                              hmac ahead of pgcrypto receives 'AWS4' || the secret key
#   archive_signer_search_path_unpinned      -- the signers' pin alone taken out, the extension calls still
#                                              qualified: a convert_to() ahead of an explicitly listed
#                                              pg_catalog receives 'AWS4' || the secret key
#   archive_upload_names_http_types          -- the NDJSON strategy's upload declares its response as
#                                              http_response again, so a tick under `set search_path = app`
#                                              logs skip_archive and archives nothing of that table
#
# Usage: archive_extension_resolution.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same network: the file signs real
# requests and reads the objects back. run_archive creates the bucket before any test runs; run_discriminate
# does not, so it is created here too, idempotently and the same way (a SigV4 PUT from the curl image; 200 is
# created, 409 is already there), after waiting for MinIO to report ready. The file creates the cluster-wide
# role t44_low and drops it before it ends; a run that died before that leaves it, so it is dropped here
# first when nothing owns it any more.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
TEST_FILE="${PGPM_EXTRES_TEST_FILE:-/repo/tests/archive/db/44_archive_extension_resolution_test.sql}"
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
q -q -c "drop role if exists t44_low" >/dev/null 2>&1
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "pgcrypto and http are reached in their own schemas" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "pgcrypto and http are reached in their own schemas" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "drop role if exists t44_low" >/dev/null 2>&1
exit "$fail"
