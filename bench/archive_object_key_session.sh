#!/usr/bin/env bash
# Run tests/archive/db/26_archive_key_schema_zone_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 26 is a plain pgTAP file and the archive track already runs it, so
# on correct code this script adds nothing. What it adds is the standing proof that the file
# DISCRIMINATES (issue #551). Its claims are exact keys and object identities ("t26a's ledger row names
# <prefix>t26a.evt_0.ndjson, which holds ids 1..20"; "chunk A archived from Asia/Karachi is keyed by
# its lo in UTC"), each paired with a witness that the session really did render the parent unqualified
# or the lo in a non-UTC zone, and a negative ("nothing was written at the shared legacy key") that an
# upload that never happened would satisfy too. Pointing the file at the two mutants every CI run
# proves those assertions go red when either session rendering comes back.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   archive_object_key_search_path_parent -- archive._object_key names the parent p_parent::text again,
#                                            so two `evt` tables in two schemas, each ticked under its
#                                            own search_path, share <prefix>evt_0.ndjson and the second
#                                            PUT overwrites the first: the pre-#551 parent exactly
#   archive_object_key_session_zone       -- archive._object_stem takes the digits of the lo text as the
#                                            session rendered it again, so 05:00:00+05 and 05:00:00-05,
#                                            two chunks ten hours apart, share one stem: the pre-#551
#                                            time stem exactly
#
# Usage: archive_object_key_session.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same compose network: the
# file PUTs through both transports and fetches the objects back. run_archive creates the bucket before
# any test runs; run_discriminate does not, so the bucket is created here too, idempotently and the same
# way (a SigV4 PUT from the curl image; 200 is created, 409 is already there), after waiting for MinIO
# to report ready. PGPM_OBJECT_KEY_SESSION_TEST_FILE overrides the test file's path inside the
# container, for running from a worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
TEST_FILE="${PGPM_OBJECT_KEY_SESSION_TEST_FILE:-/repo/tests/archive/db/26_archive_key_schema_zone_test.sql}"
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

# --- the pgTAP file, which ticks from two search_paths and archives from three zones ----------------
if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -|^#  +(have|want):' | sed 's/^/    /' | head -40
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it
  # cannot tell us apart from a real failure is a run that never reached the database at all, and
  # here that matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the
  # defect", so a harness broken enough to fail against everything would be reported as proving the
  # mutation. Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "an object key names its parent and lo the same in every session" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "an object key names its parent and lo the same in every session" "$ran ran"; fail=1; fi
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
