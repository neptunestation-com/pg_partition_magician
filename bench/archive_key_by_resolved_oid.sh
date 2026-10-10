#!/usr/bin/env bash
# Run tests/archive/db/49_archive_key_by_resolved_oid_test.sql, and scripts/check_archive_child_by_oid.py, against
# an ARBITRARY copy of pgpm_archive/install.sql, so bench/discriminate.sh can point them at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Test 49 is a plain pgTAP file the archive track already runs, and the checker runs in
# the lint job, so on correct code this script adds nothing. What it adds is the standing proof that both
# DISCRIMINATE on the real module. The contract (issue #1064) is that after archive._resolve_child returns, a
# synchronous export's object key and its claim take the relation it resolved by OID: a second session that moves
# the parent to another schema (ALTER TABLE ... SET SCHEMA, which the hold on the child does not block) between
# the hold and the key does not have the export keyed and claimed as the namesake standing in the destination
# schema, so the namesake's own later export cannot PUT over the first one's object. The second session is
# dblink, driven from inside the export by a row_security_active(regclass) shim the test puts ahead of pg_catalog
# on the search_path, so the window is entered without timing. A run in which the parent never moved satisfies
# "the object is at the relation's own key" too, so the file records what that session did (from that session)
# and pins it with LIVENESS witnesses, and states each object by identity: its rows, or its bytes.
#
# The checker is the static half of the same lever: outside archive._resolve_child no relname is compared, a child
# name goes only to the resolver or into a message, and to_regclass() reads only a literal. It runs here on the
# module under test, after the file, as a second verdict of its own.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_owned_key_resolves_by_name  -- archive._owned_key looks the relation up again by name in the parent's
#                                          current schema, for the key base and the claim (test 49 parts A and
#                                          B, and the checker's rule 1)
#
# Usage: archive_key_by_resolved_oid.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove + dblink) AND MinIO on the same network: the file PUTs
# objects through archive.to_s3 and archive.to_s3_parquet. run_archive creates the bucket before any test runs;
# run_discriminate does not, so it is created here too, idempotently and the same way (a SigV4 PUT from the curl
# image; 200 is created, 409 is already there), after waiting for MinIO to report ready. The checker runs on the
# host, and reads a /repo/ path (the container's view of the repository) from this checkout.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_KEY_BY_RESOLVED_OID_TEST_FILE:-/repo/tests/archive/db/49_archive_key_by_resolved_oid_test.sql}"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
case "$ARCHIVE_INSTALL" in
  /repo/*) SRC="$ROOT/${ARCHIVE_INSTALL#/repo/}" ;;
  *) SRC="$ARCHIVE_INSTALL" ;;
esac
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "an export keys and claims the relation resolved, by oid (#1064)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "an export keys and claims the relation resolved, by oid (#1064)" "$ran ran"; fail=1; fi
  # A failure is only evidence against the code when the setup it depends on held. Name any
  # LIVENESS witness that failed, so a mutant run that fails for the fixture's sake reads as that.
  if echo "$out" | grep -qE '^not ok [0-9]+ - .*LIVENESS'; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: every witness in the file held" "no (see above)"
    fail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi
q -q -c "drop database if exists $DB" >/dev/null 2>&1

# --- the static half: the checker on the same module ----------------------------------------------
if [ ! -s "$SRC" ]; then
  printf 'FAIL  %-58s %s\n' "the archive module under test is readable on the host" "$SRC"
  exit 1
fi
chk=$(python3 "$ROOT/scripts/check_archive_child_by_oid.py" "$SRC" 2>&1); crc=$?
if [ "$crc" = 0 ]; then
  printf 'PASS  %-58s %s\n' "no child is looked up by name after the resolver (#1064)" "scripts/check_archive_child_by_oid.py"
else
  printf 'FAIL  %-58s %s\n' "no child is looked up by name after the resolver (#1064)" "the checker refused it:"
  sed 's/^/      /' <<<"$chk" | head -20
  fail=1
fi
exit "$fail"
