#!/usr/bin/env bash
# Run tests/archive/db/20_parquet_scale_above_precision_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant, and then read the files
# that test leaves behind with two independent Parquet readers.
#
# WHY A WRAPPER EXISTS AT ALL. Test 20 is a plain pgTAP file and the archive track already runs it, so
# on correct code the first half of this script adds nothing. What it adds is the standing proof that
# the file DISCRIMINATES: its assertions are identities against bytes derived outside PostgreSQL, paired
# with witnesses that the column really is numeric(2,4) and that 0.01 really is outside it, and
# pointing the same file at a mutant every CI run keeps that from decaying into a commit message.
#
# The second half is what the file cannot do from inside the database: pyarrow and DuckDB, readers that
# share no code with the writer, read each file back and must give 0.0012, -0.0099 and 0.0050 as
# DECIMAL(4,4). That is the user-visible property #596 is about: a file that uploaded and was ledgered
# as archived, declaring a DECIMAL(2,4) leaf that pyarrow refuses for the whole file. The venv is the one run_archive
# builds for scripts/verify_parquet*.py; under `./test.sh discriminate` it may not exist yet, so it is
# created here the same way. No reader is a FAIL, not a skip: a reader that did not run verified nothing.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   parquet_decimal_scale_above_precision -- archive._pq_decimal_shape keeps the column's own
#                                            precision when the scale is above it, so numeric(2,4)
#                                            is declared DECIMAL(2,4) again, the pre-#596 leaf exactly
#
# Usage: archive_parquet_scale_above_precision.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove). No MinIO: the file encodes, it uploads nothing.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
# Overridable so a worktree's copy of this guard can be pointed at its own copy of the test file.
TEST_FILE="${PGPM_SCALEPREC_TEST_FILE:-/repo/tests/archive/db/20_parquet_scale_above_precision_test.sql}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results"       # gitignored
mkdir -p "$OUT"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "numeric(2,4) is written as DECIMAL(4,4), values intact" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "numeric(2,4) is written as DECIMAL(4,4), values intact" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

# --- half 2: two independent readers, on the files the pgTAP half left in t20.enc ----------------
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
    hex="$OUT/pq_scaleprec_$label.hex"
    q -d "$DB" -Atq -c "select encode(bytes, 'hex') from t20.enc where label = '$label'" > "$hex" 2>/dev/null
    if [ ! -s "$hex" ]; then
      printf 'FAIL  %-58s %s\n' "$label: the file was produced" "no bytes in t20.enc"
      fail=1; continue
    fi
    if ! "$PY" - "$hex" "$label" "$OUT/pq_scaleprec_$label.parquet" <<'PYEOF'
import decimal
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


expected = [decimal.Decimal("0.0012"), decimal.Decimal("-0.0099"), decimal.Decimal("0.0050")]
try:
    t = pq.read_table(path)
    check("pyarrow reads w as DECIMAL(4,4)", str(t.schema.field("w").type),
          t.schema.field("w").type == pa.decimal128(4, 4))
    got = t.column("w").to_pylist()
    check("pyarrow reads 0.0012, -0.0099, 0.0050", str(got), got == expected)
except Exception as e:  # a reader refusing the file is the defect, not an error in the guard
    check("pyarrow reads the file", f"refused: {e}", False)
try:
    got = [r[0] for r in duckdb.sql(f"select w from '{path}' order by id").fetchall()]
    check("DuckDB reads 0.0012, -0.0099, 0.0050", str(got), got == expected)
except Exception as e:
    check("DuckDB reads the file", f"refused: {e}", False)
sys.exit(0 if ok else 1)
PYEOF
    then fail=1; fi
  done
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
