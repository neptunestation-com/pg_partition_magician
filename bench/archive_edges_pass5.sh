#!/usr/bin/env bash
# Run tests/archive/db/30_archive_edges_pass5_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant, and then read the two
# Parquet files that test leaves behind with two independent readers.
#
# WHY A WRAPPER EXISTS AT ALL. Test 30 is a plain pgTAP file and the archive track already runs it, so
# on correct code the first half of this script adds nothing. What it adds is the standing proof that
# the file DISCRIMINATES, for the three edges of #711 it pins: the synchronous exports' keys (asserted
# as exact keys holding each table's own rows, with "nothing at the bare key" witnessed absent first),
# the timestamptz leaf's LogicalType (by its bytes in both encoders' footers), and the orphan sweep's
# pagination (three uploads at one key, a store witnessed to truncate at one per page, none left).
#
# The second half is what the file cannot do from inside the database: the annotation exists so that
# a reader shows a timestamptz as an instant, and DuckDB, which read the ConvertedType alone as a naive
# TIMESTAMP, must now type the column TIMESTAMP WITH TIME ZONE and give back both instants; pyarrow must
# give back the same two instants, UTC-adjusted. The venv is the one run_archive builds for
# scripts/verify_parquet*.py; under `./test.sh discriminate` it may not exist yet, so it is created here
# the same way. No reader is a FAIL, not a skip: a reader that did not run verified nothing.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   to_s3_sync_key_bare_child    -- archive.to_s3 and archive.to_s3_parquet key <prefix><child><ext>,
#                                   so two same-named parents in two schemas share one object
#   parquet_tstz_no_logical_type -- a timestamptz leaf carries the ConvertedType alone, which DuckDB
#                                   reads as a naive TIMESTAMP
#   abort_sweep_one_page         -- archive._s3_abort_uploads_at reads the first page of the listing
#                                   only, so an orphan past it stays in flight
#
# Usage: archive_edges_pass5.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove) AND MinIO on the same compose network: the
# file exports to MinIO and starts multipart uploads there. run_archive creates the bucket before any
# test runs; run_discriminate does not, so it is created here too, idempotently and the same way (a
# SigV4 PUT from the curl image; 200 is created, 409 is already there), after waiting for MinIO.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_EDGES5_TEST_FILE:-/repo/tests/archive/db/30_archive_edges_pass5_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "sync keys, tstz annotation, every listing page (#711)" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "sync keys, tstz annotation, every listing page (#711)" "$ran ran"; fail=1; fi
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

# --- half 2: two independent readers, on the files the pgTAP half left in t30.pq ----------------
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
    hex="$OUT/pq_tstz_$label.hex"
    q -d "$DB" -Atq -c "select encode(bytes, 'hex') from t30.pq where label = '$label'" > "$hex" 2>/dev/null
    if [ ! -s "$hex" ]; then
      printf 'FAIL  %-58s %s\n' "$label: the file was produced" "no bytes in t30.pq"
      fail=1; continue
    fi
    if ! "$PY" - "$hex" "$label" "$OUT/pq_tstz_$label.parquet" <<'PYEOF'
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


WANT = [1705343400000000, 1721068200000000]   # 2024-01-15 and 2024-07-15, 18:30 UTC
try:
    t = pq.read_table(path).sort_by("id")
    typ = t.schema.field("tstz").type
    got = t.column("tstz").cast(pa.int64()).to_pylist()
    check("pyarrow: tstz is a UTC-adjusted instant", str(typ), pa.types.is_timestamp(typ) and typ.tz is not None)
    check("pyarrow: the two instants", str(got), got == WANT)
except Exception as e:  # a reader refusing the file is the defect, not an error in the guard
    check("pyarrow reads the file", f"refused: {e}", False)
try:
    typ = duckdb.sql(f"select typeof(tstz) from '{path}' limit 1").fetchone()[0]
    check("DuckDB: tstz is TIMESTAMP WITH TIME ZONE", typ, typ == "TIMESTAMP WITH TIME ZONE")
    got = [r[0] for r in duckdb.sql(f"select epoch_us(tstz) from '{path}' order by id").fetchall()]
    check("DuckDB: the two instants", str(got), got == WANT)
except Exception as e:
    check("DuckDB reads the file", f"refused: {e}", False)
sys.exit(0 if ok else 1)
PYEOF
    then fail=1; fi
  done
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
