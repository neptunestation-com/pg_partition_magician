#!/usr/bin/env bash
# Run tests/archive/db/31_parquet_decimal_nan_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant, and then read the two
# Parquet files that test leaves behind with two independent readers.
#
# WHY A WRAPPER EXISTS AT ALL. Test 31 is a plain pgTAP file and the archive track already runs it, so
# on correct code the first half of this script adds nothing. What it adds is the standing proof that
# the file DISCRIMINATES. Its tick half ends in a negative ("no tick deferred the chunk") that a tick
# which never reached the NaN would satisfy as well; the file pins it with witnesses (the DECIMAL
# primitive itself refuses NaN, archive_batch is 1) and identities (each file byte for byte the file of
# the same rows with NaN as null, the ledger's row count, the object at its key), and pointing the same
# file at a mutant every CI run checks that those would fail with the defect back.
#
# The second half is what the file cannot do from inside the database: pyarrow and DuckDB must read
# each file and give back null where a NaN was, a real null as null, and every other DECIMAL exactly,
# in the rows that hold them, from a NOT NULL column whose leaf the NaN made OPTIONAL as well as from a
# nullable one. The venv is the one run_archive builds for scripts/verify_parquet*.py; under
# `./test.sh discriminate` it may not exist yet, so it is created here the same way. No reader is a
# FAIL, not a skip: a reader that did not run verified nothing.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   parquet_decimal_nan_raises -- the numeric branch encodes every non-null value, NaN included, and
#                                 archive._pq_plain_decimal raises 'cannot convert NaN to integer':
#                                 the chunk is deferred on every tick, never covered or retired
#
# Usage: archive_parquet_decimal_nan.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same compose network: the
# file's tick half PUTs a Parquet object. run_archive creates the bucket before any test runs;
# run_discriminate does not, so it is created here too, idempotently and the same way (a SigV4 PUT from
# the curl image; 200 is created, 409 is already there), after waiting for MinIO to report ready.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_DECIMAL_NAN_TEST_FILE:-/repo/tests/archive/db/31_parquet_decimal_nan_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "numeric(p,s) NaN is archived, as null (#635)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "numeric(p,s) NaN is archived, as null (#635)" "$ran ran"; fail=1; fi
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

# --- half 2: two independent readers, on the files the pgTAP half left in t31.enc ---------------
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
    hex="$OUT/pq_nan_$label.hex"
    q -d "$DB" -Atq -c "select encode(bytes, 'hex') from t31.enc where label = '$label'" > "$hex" 2>/dev/null
    if [ ! -s "$hex" ]; then
      printf 'FAIL  %-58s %s\n' "$label: the file was produced" "no bytes in t31.enc"
      fail=1; continue
    fi
    if ! "$PY" - "$hex" "$label" "$OUT/pq_nan_$label.parquet" <<'PYEOF'
import sys
from decimal import Decimal as D

import duckdb
import pyarrow.parquet as pq

raw = bytes.fromhex(open(sys.argv[1]).read().strip())
label, path = sys.argv[2], sys.argv[3]
open(path, "wb").write(raw)
ok = True


def check(name, detail, cond):
    global ok
    print(("PASS  " if cond else "FAIL  ") + f"{label + ': ' + name:<58} {detail}")
    ok = ok and cond


AMT = [D("1.50"), None, None, D("-12.25")]
REQ = [D("2.250"), None, D("-0.750"), None]
FIX = [D("10.5"), D("-3.0"), D("0.1"), D("999.9")]
try:
    t = pq.read_table(path).sort_by("id")
    got = [t.column(c).to_pylist() for c in ("amt", "req", "fix")]
    check("pyarrow: amt, req, fix by row, NaN as null", str(got), got == [AMT, REQ, FIX])
except Exception as e:  # a reader refusing the file is the defect, not an error in the guard
    check("pyarrow reads the file", f"refused: {e}", False)
try:
    rows = duckdb.sql(f"select amt, req, fix from '{path}' order by id").fetchall()
    got = [[r[i] for r in rows] for i in range(3)]
    check("DuckDB: amt, req, fix by row, NaN as null", str(got), got == [AMT, REQ, FIX])
except Exception as e:
    check("DuckDB reads the file", f"refused: {e}", False)
sys.exit(0 if ok else 1)
PYEOF
    then fail=1; fi
  done
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
