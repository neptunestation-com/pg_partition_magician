#!/usr/bin/env bash
# Run tests/archive/db/42_archive_recorded_chunk_overwrite_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 42 is a plain pgTAP file and the archive track already runs it, so on
# correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# Its contract (issue #975, pass 9 F5-03 and F5-04) is that an archive_fn strategy writes over the object
# pgpm.archive_ledger records a chunk at only when the call reproduces that chunk: the same [lo, hi), and a
# read that finds the rows the chunk recorded. A call that never reached MinIO, or objects that never held the
# chunk, satisfy "the object still holds the chunk" too, so the file pins each half with witnesses (the
# ledger rows maintain() wrote, the objects read back by rows and by bytes before any direct call, the
# partitions present and then dropped by retire()) and with identities (the objects read back after each
# refused call), and it admits a re-run of a live chunk and a write to an unrecorded key as controls.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site and rule of the fix:
#   archive_ndjson_recorded_chunk_unchecked    -- the NDJSON encoder does not ask
#                                                 archive._refuse_recorded_chunk_overwrite (F5-04 and F5-03:
#                                                 the object is overwritten)
#   archive_parquet_recorded_chunk_unchecked   -- the Parquet encoder does not
#   archive_recorded_chunk_rows_unchecked      -- the recorded chunk's range is compared, its rows are not
#                                                 (F5-03: the retired chunk's own [lo, hi) PUTs an empty object)
#   archive_recorded_chunk_range_unchecked     -- its rows are compared, its range is not (a range reading
#                                                 the same rows, or past the chunk's hi, is written over it)
#
# Usage: archive_recorded_chunk.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same network: the file archives
# NDJSON and Parquet chunks through maintain() and reads the objects back. run_archive creates the bucket
# before any test runs; run_discriminate does not, so it is created here too, idempotently and the same way
# (a SigV4 PUT from the curl image; 200 is created, 409 is already there), after waiting for MinIO to report
# ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_ARCHIVE_RECORDED_CHUNK_TEST_FILE:-/repo/tests/archive/db/42_archive_recorded_chunk_overwrite_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "no strategy writes over a recorded chunk it does not reproduce (#975)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "no strategy writes over a recorded chunk it does not reproduce (#975)" "$ran ran"; fail=1; fi
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
