#!/usr/bin/env bash
# Run tests/archive/db/27_parquet_timestamp_range_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant, and then read the files
# that test leaves behind with two independent Parquet readers. The shape is
# bench/archive_parquet_timestamp_infinity.sh's, for the finite half of the same boundary (issue #664).
#
# WHY A WRAPPER EXISTS AT ALL. Test 27 is a plain pgTAP file and the archive track already runs it, so
# on correct code the first half of this script adds nothing. What it adds is the standing proof that
# the file DISCRIMINATES. Its tick half ends in a negative ("no tick skipped the archive step") that an
# execution which never reached the far-future row would satisfy as well; the file pins it with a
# witness (the older partition holds a finite 294250 AD value, archive_batch is 1) and an identity
# (which partitions were archived, with how many rows), and pointing the same file at a mutant every CI
# run is what checks that those would fail with the defect back.
#
# The second half is what the file cannot do from inside the database: pyarrow reads each file back
# and must give INT64 max minus 1 for the far-future values, next to INT64 max for the infinity, and
# DuckDB, the reader whose range the ceiling follows, must decode the far-future values as FINITE
# timestamps later than the 2024 ones, and only the infinity as infinity. The venv is the one
# run_archive builds for scripts/verify_parquet*.py; under `./test.sh discriminate` it may not exist
# yet, so it is created here the same way. No reader is a FAIL, not a skip: a reader that did not run
# verified nothing.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   parquet_timestamp_no_ceiling -- archive._pq_epoch_micros loses its clamp at the int64 microsecond
#                                   ceiling, the pre-#664 cast exactly: a finite value past 294247 AD
#                                   raises 'bigint out of range' and its partition is never archived
#
# Usage: archive_parquet_timestamp_range.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same compose network: the
# file's tick half PUTs two Parquet objects. run_archive creates the bucket before any test runs;
# run_discriminate does not, so it is created here too, idempotently and the same way (a SigV4 PUT from
# the curl image; 200 is created, 409 is already there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_TSRANGE_TEST_FILE:-/repo/tests/archive/db/27_parquet_timestamp_range_test.sql}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results"       # gitignored
NET="${PGPM_TEST_NET:-pgpm_test_net}"
mkdir -p "$OUT"
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

# --- half 1: the pgTAP file ---------------------------------------------------------------------
if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit status covers "fewer assertions ran than planned"; the count separates a real
  # failure from a run that never reached the database, which discriminate.sh would otherwise read as
  # "the guard caught the defect".
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "timestamps past 294247 AD are archived, at the INT64 ceiling" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "timestamps past 294247 AD are archived, at the INT64 ceiling" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

# --- half 2: two independent readers, on the files the pgTAP half left in t27.enc ----------------
PY="$ROOT/.venv-verify/bin/python"
if [ ! -x "$PY" ]; then
  python3 -m venv "$ROOT/.venv-verify" >/dev/null 2>&1 \
    && "$ROOT/.venv-verify/bin/pip" install -q -r "$ROOT/scripts/requirements-verify.txt" >/dev/null 2>&1
fi
if ! "$PY" -c 'import pyarrow.parquet, duckdb' >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the independent readers (pyarrow, DuckDB) are available" "no"
  fail=1
else
  for label in whole range; do
    hex="$OUT/pq_tsrange_$label.hex"
    q -d "$DB" -Atq -c "select encode(bytes, 'hex') from t27.enc where label = '$label'" > "$hex" 2>/dev/null
    if [ ! -s "$hex" ]; then
      printf 'FAIL  %-58s %s\n' "$label: the file was produced" "no bytes in t27.enc"
      fail=1; continue
    fi
    if ! "$PY" - "$hex" "$label" "$OUT/pq_tsrange_$label.parquet" <<'PYEOF'
import sys

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq

raw = bytes.fromhex(open(sys.argv[1]).read().strip())
label, path = sys.argv[2], sys.argv[3]
open(path, "wb").write(raw)
ok = True


def check(name, detail, cond):
    global ok
    print(("PASS  " if cond else "FAIL  ") + f"{label + ': ' + name:<58} {detail}")
    ok = ok and cond


M = 2**63 - 1
try:
    t = pq.read_table(path)
    ts = t.column("ts").cast(pa.int64()).to_pylist()
    tstz = t.column("tstz").cast(pa.int64()).to_pylist()
    check("pyarrow: ts is INT64 max - 1, the wall clock, INT64 max - 2", str(ts), ts == [M - 1, 1705320000000000, M - 2])
    check("pyarrow: tstz is the instant, INT64 max - 1, INT64 max", str(tstz), tstz == [1705343400000000, M - 1, M])
except Exception as e:  # a reader refusing the file is the defect, not an error in the guard
    check("pyarrow reads the file", f"refused: {e}", False)
try:
    # The decoded text, not a comparison with a timestamptz literal: that casts the leaf through ICU in
    # the local zone, which overflows at the ceiling whatever this module wrote. The zone is pinned for
    # the same reason, in case a DuckDB release types the tstz leaf as TIMESTAMPTZ.
    con = duckdb.connect()
    con.execute("set TimeZone = 'UTC'")
    got = con.sql(
        f"select isfinite(ts), ts::varchar, isfinite(tstz), tstz::varchar from '{path}' order by id").fetchall()
    ceil = "294247-01-10 04:00:54.775806"
    want = [(True, ceil, True, "2024-01-15 18:30:00"),
            (True, "2024-01-15 12:00:00", True, ceil),
            (True, "294247-01-10 04:00:54.775805", False, "infinity")]
    check("DuckDB: far-future values decode as the finite ceiling", str(got), got == want)
except Exception as e:
    check("DuckDB reads the file", f"refused: {e}", False)
sys.exit(0 if ok else 1)
PYEOF
    then fail=1; fi
  done
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
