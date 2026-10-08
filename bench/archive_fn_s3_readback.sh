#!/usr/bin/env bash
# Prove tests/archive/db/08 (the archive_fn S3 strategies) FAILS against a Parquet transport that uploads no
# rows, by putting that transport in and running the file.
#
# WHY THIS GUARD EXISTS (issue #1093). The file's header promised that the uploaded object is fetched straight
# back from MinIO and checked, not the ledger's bookkeeping trusted, and its NDJSON half did that. Its Parquet
# half asserted only the ledger: rows_archived sums, a key ending in .parquet and a non-null ETag. So with
# archive._encode_upload_parquet uploading the 4-byte magic PAR1 in place of the file and still reporting the
# file's row count, every assertion held. Each Parquet object the file makes (Part B's three ledger chunks, the
# direct calls of Parts C and D) is now fetched back and compared, byte for byte, with the file of its range.
#
# HOW. Each run in a fresh <db> in <container> (the archive track's image: pgsql-http, pgcrypto and pgtap, with
# MinIO reachable as minio:9000), holding tests/archive/fixtures.sql, the core and pgpm_archive:
#   CONTROL   the file passes, every planned assertion ok, against the clean module;
#   DEFECT    the file reports at least one `not ok` (and runs to its end) against this checkout's
#             pgpm_archive/install.sql with archive._encode_upload_parquet's PUT sending the first four bytes
#             of the file (PAR1) instead of the file;
#   LIVENESS  read from the database each run leaves: a8p's monolith is recorded as 5000 rows archived, and the
#             object at its key, fetched back, is more than PAR1 under the clean module and exactly the 4 bytes
#             PAR1 under the defect. A defect that was never planted would make the file's failure meaningless.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_fn_parquet_readback_trusted -- tests/archive/db/08's read-back helper answers from the key alone,
#                                          the pre-#1093 shape: no Parquet object is fetched back
#
# Usage: archive_fn_s3_readback.sh <container> <db> [test file]
# The third argument is the test file to judge in place of tests/archive/db/08 (bench/discriminate.sh hands it
# the mutant, a /repo/... path, which this maps to this checkout). Every install and the file reach the
# container over stdin, so a file outside the mounted tree works too. run_archive creates the bucket before any
# test runs and run_discriminate does not, so it is created here too, idempotently, after MinIO reports ready.
# PGPM_TEST_NET names the network MinIO answers on (default pgpm_test_net, the compose network).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${3:-$ROOT/tests/archive/db/08_archive_fn_s3_test.sql}"
SRC="${SRC/#\/repo\//$ROOT/}"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
fail=0
work=$(mktemp -d)
say() { printf '%s  %-58s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i "$C" psql -U postgres -X "$@"; }
cleanup() { q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

if [ ! -f "$SRC" ]; then say FAIL "the test file to judge exists" "$SRC"; exit 1; fi

# --- MinIO: ready, and the bucket the fixtures point at exists ------------------------------------
ready=""
for _ in $(seq 1 60); do
  if docker run --rm --network "$NET" curlimages/curl -sf http://minio:9000/minio/health/cluster >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ -z "$ready" ]; then say FAIL "MinIO reported ready (/minio/health/cluster)" "not within 60 s"; exit 1; fi
code=$(docker run --rm --network "$NET" curlimages/curl -s -o /dev/null -w '%{http_code}' \
         --aws-sigv4 aws:amz:us-east-1:s3 -u minioadmin:minioadmin \
         -X PUT http://minio:9000/archive-test-bucket) || code="curl exit $?"
if [ "$code" != 200 ] && [ "$code" != 409 ]; then say FAIL "the MinIO bucket exists" "PUT returned $code"; exit 1; fi

# The DEFECT copy of the module: the Parquet strategy's PUT sends PAR1 and nothing else, and the transport still
# reports the file's row count. The pattern must match exactly once (the discipline of mutate.py).
if ! python3 - "$ROOT/pgpm_archive/install.sql" "$work/par1_only.sql" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
find = ("  perform archive._refuse_recorded_chunk_overwrite('archive_to_s3_parquet', p_parent, pcfg.control_kind, v_key, p_lo, p_hi, v_rows);\n"
        "  v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',\n"
        "                                            'application/vnd.apache.parquet', v_payload, v_key_id, v_secret);\n")
n = t.count(find)
if n != 1:
    sys.exit(f"the Parquet strategy's PUT matched {n} time(s), expected 1")
open(dst, "w").write(t.replace(find, find.replace("v_payload, v_key_id", "substring(v_payload from 1 for 4), v_key_id")))
PY
then
  say FAIL "planted the defect: the Parquet PUT sends PAR1 alone" "pgpm_archive/install.sql moved; fix the pattern"
  exit 1
fi

# fresh <archive install.sql>: a new <db> with the extensions, the fixtures, the core and that module.
fresh() {
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "create database $DB" </dev/null >/dev/null 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" </dev/null >/dev/null 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$ROOT/tests/archive/fixtures.sql" >"$work/install.log" 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f - <"$ROOT/pgpm_core/install.sql" >"$work/install.log" 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$1" >"$work/install.log" 2>&1
}

# judge <label> <expect: pass|fail>: run the file in <db> and read its TAP (pg_prove's verdict: the plan, every
# assertion run, psql's exit, no raw error).
judge() {
  local label="$1" expect="$2" out rc planned oks notoks
  out=$(q -d "$DB" -v ON_ERROR_STOP=1 -tA -f - <"$SRC" 2>&1); rc=$?
  planned=$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' <<<"$out" | head -1)
  oks=$(grep -cE '^ok [0-9]+' <<<"$out")
  notoks=$(grep -cE '^not ok [0-9]+' <<<"$out")
  if [ "$rc" != 0 ] || [ -z "$planned" ] || [ $((oks + notoks)) != "$planned" ]; then
    say FAIL "$label: the file ran to its end" "psql exit $rc, plan ${planned:-none}, $oks ok, $notoks not ok"
    grep -E 'ERROR|^not ok' <<<"$out" | head -5 | sed 's/^/      /'
    fail=1; return
  fi
  if [ "$expect" = pass ]; then
    if [ "$notoks" = 0 ]; then say PASS "$label" "$oks/$planned ok"
    else say FAIL "$label" "$notoks not ok of $planned"; grep -E '^not ok' <<<"$out" | sed 's/^/      /'; fail=1; fi
  elif [ "$notoks" -gt 0 ]; then
    say PASS "$label" "$(grep -E '^not ok' <<<"$out" | head -1 | cut -c1-70)"
  else
    say FAIL "$label" "all $planned ok against the defect: the file passes for the wrong reason"; fail=1
  fi
}

# a8p's monolith as the ledger records it and as MinIO holds it: "<rows_archived>|<object bytes>"
MONOLITH="select l.rows_archived || '|' || octet_length(text_to_bytea((archive.s3_signed_request('GET', 'http://minio:9000',
                'archive-test-bucket', 'us-east-1', l.s3_key, '', 'text/plain', '', 'minioadmin', 'minioadmin')).content))
            from pgpm.archive_ledger l where l.parent_table = 'public.a8p'::regclass and l.lo = '0'"
monolith() { q -d "$DB" -tAq -c "$MONOLITH" </dev/null 2>&1 | tail -1; }

# CONTROL
if fresh "$ROOT/pgpm_archive/install.sql"; then
  judge "CONTROL: tests/archive/db/08 passes on the clean module" pass
  got=$(monolith)
  if [[ "$got" =~ ^5000\|[0-9]+$ ]] && [ "${got#*|}" -gt 4 ]; then
    say PASS "LIVENESS: clean, a8p's 5000-row monolith is a whole file" "rows|bytes $got"
  else
    say FAIL "LIVENESS: clean, a8p's 5000-row monolith is a whole file" "rows|bytes ${got:-nothing}"; fail=1
  fi
else
  say FAIL "CONTROL: the extensions, fixtures, core and module loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
fi

# DEFECT
if fresh "$work/par1_only.sql"; then
  judge "DEFECT: tests/archive/db/08 fails on a PAR1-only upload" fail
  got=$(monolith)
  if [ "$got" = "5000|4" ]; then
    say PASS "LIVENESS: defect, 5000 rows recorded, object is 4 bytes" "rows|bytes $got"
  else
    say FAIL "LIVENESS: defect, 5000 rows recorded, object is 4 bytes" "rows|bytes ${got:-nothing}"; fail=1
  fi
else
  say FAIL "DEFECT: the extensions, fixtures, core and module loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
fi

if [ "$fail" = 0 ]; then say PASS "tests/archive/db/08 fails against its defect" "$(basename "$SRC")"
else say FAIL "tests/archive/db/08 fails against its defect" "$(basename "$SRC")"; fi
exit "$fail"
