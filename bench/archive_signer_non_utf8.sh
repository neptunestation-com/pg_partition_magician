#!/usr/bin/env bash
# Run tests/archive/db/29_signer_non_utf8_database_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 29 is a plain pgTAP file and the archive track already runs it, so
# on correct code this script adds nothing. What it adds is the standing proof that the file
# DISCRIMINATES. Its claim, "no tick deferred the chunk", is a negative that a tick which never reached
# a non-ASCII chunk satisfies too; the file pairs it with witnesses (the sibling database really is
# LATIN1, row 1 really is a different byte string in the two encodings, the step really ran the NDJSON
# strategy uncompressed) and with identities (the ledger's row count and key, the object's rows by id
# and text), and pointing the same file at a mutant every CI run is what checks they would fail.
#
# The file builds its LATIN1 sibling itself and installs the module into it from files: it reads the
# archive install from the database setting pgpm_test.archive_install when one is set, which is how this
# script hands it the install under test. The sibling is `<db>_l1`; it is dropped here as well as by the
# file, so a run that died part way leaves nothing behind.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   signer_text_sends_server_encoding -- archive.s3_signed_request hashes the payload's UTF-8 bytes and
#                                        sends its server-encoding bytes, the pre-#728 send: in a LATIN1
#                                        database every non-ASCII body is refused, and the NDJSON strategy
#                                        wedges its table
#
# Usage: archive_signer_non_utf8.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove + dblink) AND MinIO on the same compose network,
# and the repository at /repo in the container (the file reads the core install and the fixtures there).
# run_archive creates the bucket before any test runs; run_discriminate does not, so it is created here
# too, idempotently and the same way (a SigV4 PUT from the curl image; 200 is created, 409 is already
# there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
TEST_FILE="${PGPM_SIGNER_TEST_FILE:-/repo/tests/archive/db/29_signer_non_utf8_database_test.sql}"
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
q -q -c "drop database if exists ${DB}_l1 with (force)" >/dev/null 2>&1
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
# the install the file loads into its LATIN1 sibling
if ! q -q -c "alter database $DB set pgpm_test.archive_install = '$ARCHIVE_INSTALL'" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_test.archive_install set on the database" "no"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell apart from a real failure is a run that never reached the database at all, which
  # discriminate.sh would read as "the guard caught the defect". Hence the count, printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a LATIN1 database archives non-ASCII NDJSON (#728)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a LATIN1 database archives non-ASCII NDJSON (#728)" "$ran ran"; fail=1; fi
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

q -q -c "drop database if exists ${DB}_l1 with (force)" >/dev/null 2>&1
q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
