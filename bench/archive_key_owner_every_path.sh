#!/usr/bin/env bash
# Run tests/archive/db/39_archive_key_owner_every_path_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 39 is a plain pgTAP file and the archive track already runs it, so on
# correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# Its contract (issue #872, bullet 5) is the lever's invariant: every object key the archive module writes
# names one relation, on every path that writes one. Each path (archive.to_s3 plain and compressed,
# archive.to_s3_parquet, and the NDJSON and Parquet archive_fn transports) exports a relation, the relation
# is dropped and forgotten, a namesake exports the same partition or chunk, and the first relation's object
# must still be at its key with its own rows or bytes. A run in which the namesake never exported, or
# exported to a key nobody had written, satisfies "the old object is intact" too, so the file pins every
# export with witnesses (each key absent before its PUT, each namesake's object at its own exact key) and
# with identities (rows as id:payload, gzip and Parquet objects byte for byte), and pointing it at a mutant
# every CI run checks that those would fail.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site of the lever:
#   archive_child_key_unclaimed          -- archive._child_object_key assembles its own key again, with no
#                                           claim: the defect #872 bullet 5 reported, for both exports
#   archive_object_key_unclaimed         -- archive._object_key assembles its own key again, with no claim:
#                                           the pre-#822 chunk key, for both archive_fn transports
#   archive_to_s3_key_inline             -- archive.to_s3 builds its plain NDJSON key inline
#   archive_to_s3_gz_key_inline          -- archive.to_s3 builds its compressed key inline
#   archive_to_s3_parquet_key_inline     -- archive.to_s3_parquet builds its key inline
#   archive_ndjson_strategy_key_inline   -- the NDJSON archive_fn transport builds its chunk key inline
#   archive_parquet_strategy_key_inline  -- the Parquet archive_fn transport builds its chunk key inline
# (archive_object_key_reusable_name, which takes the oid out of archive._owned_key itself, stays with
# bench/archive_key_reused_name.sh, the #822 guard.) scripts/check_archive_object_keys.py refuses every one
# of these mutants statically too; this guard is the behavioural half.
#
# Usage: archive_key_owner_every_path.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same network: the file PUTs
# NDJSON, gzip and Parquet objects. run_archive creates the bucket before any test runs; run_discriminate
# does not, so it is created here too, idempotently and the same way (a SigV4 PUT from the curl image; 200
# is created, 409 is already there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_KEY_OWNER_EVERY_PATH_TEST_FILE:-/repo/tests/archive/db/39_archive_key_owner_every_path_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "every path keys an object by one relation (#872)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "every path keys an object by one relation (#872)" "$ran ran"; fail=1; fi
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
