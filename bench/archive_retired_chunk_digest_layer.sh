#!/usr/bin/env bash
# Run tests/archive/db/50_archive_retired_chunk_kept_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL (issue #1173). Test 50 is a plain pgTAP file and the archive track already runs it,
# so on correct code this script adds nothing. What it adds is the standing proof that the file reaches the check
# its header names. After retire() dropped a chunk's partition and a partition re-created over the range was
# adopted, the file sends a direct archive_to_s3_ndjson call at the retired chunk's key and says the digest check
# (#1069), the second layer, refuses it. Its fixture re-created the range with 40 rows against a 90-row chunk, so
# archive._refuse_recorded_chunk_overwrite's count arm refused first, the assertion pinned the count arm's message,
# and the file passed in full with the digest comparison removed. The re-created partition now holds 90 rows
# 'late<id>' over the chunk's ids 1..90 'old<id>': the count arm admits the read, and only the digest arm can
# refuse it. The file's own witnesses (the object read back before and after, the ledger row retire() marked, the
# partition the tick write-blocked) say the fixture reached that state; a failure of a LIVENESS witness alone is
# reported as that, not as a catch.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_recorded_chunk_digest_compare_dropped -- the refusal's digest arm keeps its null-claim clause and
#                                                    drops the comparison, so a read of as many rows as the chunk
#                                                    recorded, but other ones, is admitted and PUT over the object
# tests/archive/db/48 is the digest's own file (bench/archive_recorded_chunk_rows_identity.sh); this one proves the
# retired-chunk file leans on it too, as its header says.
#
# Usage: archive_retired_chunk_digest_layer.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same network: the file archives an
# NDJSON chunk through maintain() and reads the objects back. run_archive creates the bucket before any test runs;
# run_discriminate does not, so it is created here too, idempotently and the same way (a SigV4 PUT from the curl
# image; 200 is created, 409 is already there), after waiting for MinIO to report ready. PGPM_TEST_NET names the
# network MinIO answers on (default pgpm_test_net, the compose network).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree mounted somewhere other than /repo can point it at its own copy of the file.
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/archive/db/50_archive_retired_chunk_kept_test.sql}"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
LABEL="a retired chunk's object is kept, its digest refusing a direct call (#1173)"
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
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
