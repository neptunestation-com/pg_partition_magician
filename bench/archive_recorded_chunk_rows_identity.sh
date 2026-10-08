#!/usr/bin/env bash
# Run tests/archive/db/48_archive_recorded_chunk_rows_identity_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 48 is a plain pgTAP file and the archive track already runs it, so on
# correct code this script adds nothing. What it adds is the standing proof that the file DISCRIMINATES.
# Its contract (issue #1069, pass 10 F5-03) is that an archive_fn strategy writes over the object
# pgpm.archive_ledger records a chunk at only when its read finds the rows the chunk recorded, compared by a
# digest of the rows recorded on the key's whole-key claim, not by their number: after retire(), a
# partition re-created over the range with as many rows as the chunk held, but other ones, is refused. A call
# that never reached MinIO, or objects that never held the chunk, satisfy "the object still holds the chunk"
# too, so the file pins it with witnesses (the ledger rows maintain() wrote, the objects read back before any
# direct call, the partitions dropped by retire(), the re-created ranges read back row by row) and with
# identities (the objects read back after each refused call), and it admits a re-run of a live chunk from
# another time zone and a re-run over exactly the chunk's rows after retire() as controls.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per rule and site of the fix:
#   archive_recorded_chunk_identity_unchecked  -- the digest is recorded and never compared (the
#                                                 re-created rows, and a claim with none, are written over)
#   archive_recorded_chunk_identity_unrecorded -- it is compared and never recorded (every re-run of a chunk
#                                                 is refused, the documented one included)
#   archive_row_digest_session_zone            -- the digest renders a timestamptz in the caller's zone
#                                                 (the live re-run from another zone is refused)
#   archive_row_digest_search_path             -- the digest renders a regclass under the caller's search_path
#                                                 (the live re-run under search_path t48 is refused)
#   archive_pq_row_digest_alias_shadowed       -- the Parquet digest passes the bare alias s, which a column
#                                                 named s shadows (t48.ps is never archived or retired)
#   archive_ndjson_row_digest_alias_shadowed   -- the NDJSON digest passes the bare alias t, the same way
#                                                 (t48.nt is never archived)
# The race between a direct call and a tick archiving the same chunk is bench/archive_recorded_chunk_tick_race.sh's.
#
# Usage: archive_recorded_chunk_rows_identity.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same network: the file archives
# NDJSON and Parquet chunks through maintain() and reads the objects back. run_archive creates the bucket
# before any test runs; run_discriminate does not, so it is created here too, idempotently and the same way
# (a SigV4 PUT from the curl image; 200 is created, 409 is already there), after waiting for MinIO to report
# ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_ARCHIVE_RECORDED_CHUNK_ROWS_TEST_FILE:-/repo/tests/archive/db/48_archive_recorded_chunk_rows_identity_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "no strategy writes other rows over a recorded chunk (#1069)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "no strategy writes other rows over a recorded chunk (#1069)" "$ran ran"; fail=1; fi
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
