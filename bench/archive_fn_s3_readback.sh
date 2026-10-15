#!/usr/bin/env bash
# Prove that the archive test files which read their objects back from MinIO (tests/archive/db/08, 16 and 44)
# each FAIL against a transport that uploads the wrong bytes under the chunk's key, by putting that transport in
# and running the file.
#
# WHY THIS GUARD EXISTS (issues #1093 and #1284). Each file's header promises that the objects it wrote are read
# back and checked, not the ledger's bookkeeping trusted, and each checked something weaker than identity:
#   tests/archive/db/08  (#1093) its Parquet half asserted only the ledger: rows_archived sums, a key ending in
#                        .parquet and a non-null ETag, so with archive._encode_upload_parquet uploading the
#                        4-byte magic PAR1 in place of the file and still reporting the file's row count, every
#                        assertion held. (#1284) Its NDJSON half counted the lines of two objects (5000, 50) and
#                        never read Part A's two 5-row chunks, so a transport writing "id":1 on every line kept
#                        every count. Every object it makes is now compared with the rows of its range: the
#                        Parquet ones byte for byte with the file of the range, the NDJSON ones row for row.
#   tests/archive/db/16  (#1284) Part B judged the Parquet object at the [-10000, 0) key by size (larger than the
#                        10-row object), so a strategy that encoded only the top 5% of the chunk's range, 500 of
#                        its 1000 rows, passed. Each of its two Parquet objects is now compared byte for byte with
#                        the file of its ledger row's range.
#   tests/archive/db/44  (#1284) checked its two Parquet tick objects by the PAR1 prefix, so the PAR1-only upload
#                        above passed. Each is now compared byte for byte with the file of its ledger row's range.
#
# HOW. Each run in a fresh <db> in <container> (the archive track's image: pgsql-http, pgcrypto and pgtap, with
# MinIO reachable as minio:9000), holding tests/archive/fixtures.sql, the core and pgpm_archive:
#   CONTROL   each file passes, every planned assertion ok, against the clean module;
#   DEFECT    the file reports at least one `not ok` that is not a premise (and runs to its end) against this
#             checkout's pgpm_archive/install.sql with its defect planted:
#               PAR1      archive._encode_upload_parquet's PUT sends the first four bytes of the file (PAR1)
#                         instead of the file, still reporting the file's rows (tests/archive/db/08 and 44);
#               ID ONE    archive._encode_upload_ndjson_single writes "id":1 on every line in place of the row's
#                         own id, line count, rows_archived and digest unchanged (tests/archive/db/08);
#               TOP SLICE archive._encode_upload_parquet encodes only the top 5% of the chunk's [lo, hi), so the
#                         object at the chunk's key holds 500 of [-10000, 0)'s 1000 rows (tests/archive/db/16).
#             A file whose only failures are LIVENESS:, GUARD: or fixture: premises did not catch the defect
#             (#1176): that is bench/discriminate.sh's starved() rule, read out of that script by the
#             defect-verdict block below. A file that reached no assertion failed on its fixture, so that line is
#             printed as a `fixture:` premise (#1177);
#   LIVENESS  read from the database each run leaves, so a defect that was never planted cannot make a file's
#             failure meaningless: a8p's 5000-row monolith object is more than PAR1 clean and exactly the 4 bytes
#             PAR1 under PAR1; a8's monolith object names ids 1..5000 clean and one id under ID ONE; negkp's
#             [-10000, 0) is ledgered as 1000 rows with the object at its key the chunk's file clean, and as 500
#             rows with another object under TOP SLICE; p44's two objects are more than 4 bytes each clean and 4
#             bytes each under PAR1, against 1200 and 5 rows ledgered either way.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each a file's pre-fix shape:
#   archive_fn_parquet_readback_trusted -- tests/archive/db/08's Parquet read-back helper answers from the key
#                                          alone, the pre-#1093 shape: no Parquet object is fetched back
#   archive_fn_ndjson_readback_by_count -- tests/archive/db/08's NDJSON read-back helper compares line counts,
#                                          the pre-#1284 shape: no line is read for the row it names
#   archive_key_parquet_readback_by_presence -- tests/archive/db/16's Parquet read-back helper asks only that an
#                                          object is there, not that it is the chunk's file
#   archive_extres_parquet_by_prefix    -- tests/archive/db/44's tick objects back to the PAR1 prefix check
#
# Usage: archive_fn_s3_readback.sh <container> <db> [test file]
# With no third argument it judges all three files. With one it judges THAT file in place of the one it stands
# for, recognised by its file name or, for a mutant bench/discriminate.sh built (<mutation>.sql), by the
# mutation's MUTATION_SRC; a /repo/... path is mapped to this checkout. Every install and the file reach the
# container over stdin, so a file outside the mounted tree works too. run_archive creates the bucket before any
# test runs and run_discriminate does not, so it is created here too, idempotently, after MinIO reports ready.
# PGPM_TEST_NET names the network MinIO answers on (default pgpm_test_net, the compose network). Needs python3
# on the host.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ONLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
fail=0
work=$(mktemp -d)
say() { printf '%s  %-58s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i "$C" psql -U postgres -X "$@"; }
cleanup() { q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

T08="tests/archive/db/08_archive_fn_s3_test.sql"
T16="tests/archive/db/16_archive_object_key_identity_test.sql"
T44="tests/archive/db/44_archive_extension_resolution_test.sql"
F08="$ROOT/$T08"; F16="$ROOT/$T16"; F44="$ROOT/$T44"
SEL=" 08 16 44 "
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then say FAIL "GUARD: the test file to judge exists" "$ONLY"; exit 1; fi
  base=$(basename "$ONLY")
  src=$(python3 - "$ROOT/bench/mutations" "${base%.*}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import mutate
print(mutate.MUTATION_SRC.get(sys.argv[2], ""))
PY
)
  case "$base:$src" in
    "$(basename "$T08")":*|*:"$T08") SEL=" 08 "; F08="$ONLY" ;;
    "$(basename "$T16")":*|*:"$T16") SEL=" 16 "; F16="$ONLY" ;;
    "$(basename "$T44")":*|*:"$T44") SEL=" 44 "; F44="$ONLY" ;;
    *) say FAIL "GUARD: the file to judge is one of the files this guard knows" "$ONLY -> '${src}'"; exit 1 ;;
  esac
fi
sel() { [[ "$SEL" == *" $1 "* ]]; }

# The premise rule is bench/discriminate.sh's starved(), read out of it rather than restated (#1176).
starved_fn=$(sed -n '/^starved() {/,/^}/p' "$ROOT/bench/discriminate.sh")
if [ -z "$starved_fn" ]; then say FAIL "GUARD: starved() was read out of bench/discriminate.sh" "not found"; exit 1; fi
eval "$starved_fn"
# >>> defect verdict: the same in every inverted wrapper; bench/wrapper_premise_rule.sh evaluates it.
# caught <the judged file's TAP output>: exit 0 when the file failed an assertion that is not a premise.
caught() { grep -qE '^not ok [0-9]+' "$1" && ! starved "$1"; }
# <<< defect verdict

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

# plant <name> <find> <replace>: this checkout's pgpm_archive/install.sql with <find> replaced, written to
# $work/<name>.sql. The pattern must match exactly once (the discipline of mutate.py): a pattern that no longer
# does is a FAILURE, never a silently unmutated copy.
plant() {
  python3 - "$ROOT/pgpm_archive/install.sql" "$work/$1.sql" "$2" "$3" <<'PY'
import sys
src, dst, find, repl = sys.argv[1:5]
t = open(src).read()
n = t.count(find)
if n != 1:
    sys.exit(f"pattern matched {n} time(s), expected 1: {find.splitlines()[0]!r}")
open(dst, "w").write(t.replace(find, repl))
PY
}

# PAR1: the Parquet strategy's PUT sends PAR1 and nothing else, and the transport still reports the file's row
# count. The refusal line (its #1069 digest argument included) pins the strategy's PUT apart from
# archive.to_s3_parquet's identical one.
PAR1_PUT="  perform archive._refuse_recorded_chunk_overwrite('archive_to_s3_parquet', p_parent, pcfg.control_kind, v_key, p_lo, p_hi, v_rows, v_rows_digest);
  v_resp := archive.s3_signed_request_bytea('PUT', cfg.endpoint, cfg.bucket, cfg.region, v_key, '',
                                            'application/vnd.apache.parquet', v_payload, v_key_id, v_secret);
"
planted=" "
if plant par1_only "$PAR1_PUT" "${PAR1_PUT/v_payload, v_key_id/substring(v_payload from 1 for 4), v_key_id}"; then
  planted+="par1_only "
else
  say FAIL "fixture: planted the defect: the Parquet PUT sends PAR1 alone" "pgpm_archive/install.sql moved; fix the pattern"; fail=1
fi
# ID ONE: the NDJSON strategy's line, every row's id rewritten to 1 (the encoder's body is a quoted literal).
NDJSON_LINE="string_agg(row_to_json(t.*)::text, e''\\n'' order by t.%I)"
if sel 08 && plant ndjson_id_one "$NDJSON_LINE" \
     "string_agg(regexp_replace(row_to_json(t.*)::text, ''\"id\":[0-9]+'', ''\"id\":1''), e''\\n'' order by t.%I)"; then
  planted+="ndjson_id_one "
elif sel 08; then
  say FAIL "fixture: planted the defect: every NDJSON line names id 1" "pgpm_archive/install.sql moved; fix the pattern"; fail=1
fi
# TOP SLICE: the Parquet strategy encodes [lo + 95% of the range, hi) and ledgers what it encoded.
PQ_RANGE="from archive._pq_to_parquet_range_counted(p_parent, pcfg.control_column, v_lo_lit, v_hi_lit, p_compress) c;"
if sel 16 && plant parquet_top_slice "$PQ_RANGE" \
     "from archive._pq_to_parquet_range_counted(p_parent, pcfg.control_column, (v_lo_lit::numeric + (v_hi_lit::numeric - v_lo_lit::numeric) * 0.95)::bigint::text, v_hi_lit, p_compress) c;"; then
  planted+="parquet_top_slice "
elif sel 16; then
  say FAIL "fixture: planted the defect: the Parquet strategy encodes the top 5%" "pgpm_archive/install.sql moved; fix the pattern"; fail=1
fi
is_planted() { [[ "$planted" == *" $1 "* ]]; }

# fresh <archive install.sql>: a new <db> with the extensions, the fixtures, the core and that module.
# tests/archive/db/44 creates the cluster-wide role t44_low and drops it before it ends; a run that died before
# that leaves it, so it is dropped here first when nothing owns it any more.
fresh() {
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "drop role if exists t44_low" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "create database $DB" </dev/null >/dev/null 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" </dev/null >/dev/null 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$ROOT/tests/archive/fixtures.sql" >"$work/install.log" 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f - <"$ROOT/pgpm_core/install.sql" >"$work/install.log" 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$1" >"$work/install.log" 2>&1
}

# judge <label> <expect: pass|fail> <test file>: run the file in <db> and read its TAP (pg_prove's verdict: the
# plan, every assertion run, psql's exit, no raw error).
judge() {
  local label="$1" expect="$2" src="$3" out rc planned oks notoks unreached=""
  out=$(q -d "$DB" -v ON_ERROR_STOP=1 -tA -f - <"$src" 2>&1); rc=$?
  planned=$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' <<<"$out" | head -1)
  oks=$(grep -cE '^ok [0-9]+' <<<"$out")
  notoks=$(grep -cE '^not ok [0-9]+' <<<"$out")
  if [ "$rc" != 0 ] || [ -z "$planned" ] || [ $((oks + notoks)) != "$planned" ]; then
    # A file that reached no assertion failed on its fixture: a premise, not a catch (#1177).
    [ $((oks + notoks)) -gt 0 ] || unreached="fixture: "
    say FAIL "$unreached$label: the file ran to its end" "psql exit $rc, plan ${planned:-none}, $oks ok, $notoks not ok"
    grep -E 'ERROR|^not ok' <<<"$out" | head -5 | sed 's/^/      /'
    fail=1; return
  fi
  if [ "$expect" = pass ]; then
    if [ "$notoks" = 0 ]; then say PASS "$label" "$oks/$planned ok"
    else say FAIL "$label" "$notoks not ok of $planned"; grep -E '^not ok' <<<"$out" | sed 's/^/      /'; fail=1; fi
  else
    printf '%s\n' "$out" >"$work/judged.tap"
    if caught "$work/judged.tap"; then
      say PASS "$label" "$(grep -E '^not ok' <<<"$out" | grep -vE '^not ok [0-9]+ - (LIVENESS|GUARD|fixture):' | head -1 | cut -c1-70)"
    elif [ "$notoks" -gt 0 ]; then
      say FAIL "$label" "$notoks not ok of $planned, every one a premise: the file passes for the wrong reason"
      grep -E '^not ok' <<<"$out" | sed 's/^/      /'; fail=1
    else
      say FAIL "$label" "all $planned ok against the defect: the file passes for the wrong reason"; fail=1
    fi
  fi
}

# expect <label> <want: a value, or ~<extended regex>> <sql>: a LIVENESS read from the database the run left.
expect() {
  local got
  got=$(q -d "$DB" -tAq -c "$3" </dev/null 2>&1 | tail -1)
  if { [ "${2:0:1}" = "~" ] && [[ "$got" =~ ${2:1} ]]; } || [ "$got" = "$2" ]; then say PASS "LIVENESS: $1" "$got"
  else say FAIL "LIVENESS: $1" "want ${2#\~}, got ${got:-nothing}"; fail=1; fi
}

# <parent>'s ledger rows, each "<lo>:<rows_archived>:<bytes of the object at its key>", in lo order
GET_BYTES="octet_length(text_to_bytea((archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket',
             'us-east-1', l.s3_key, '', 'text/plain', '', 'minioadmin', 'minioadmin')).content))"
ledger_bytes() {
  printf '%s' "select string_agg(l.lo || ':' || l.rows_archived || ':' || $GET_BYTES, ',' order by l.lo::numeric)
                 from pgpm.archive_ledger l where l.parent_table = '$1'::regclass"
}
# a8's monolith object: "<distinct ids>/<lines>" of the NDJSON lines it holds
A8_IDS="select count(distinct x::jsonb ->> 'id') || '/' || count(*) from pgpm.archive_ledger l,
          regexp_split_to_table((archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1',
            l.s3_key, '', 'text/plain', '', 'minioadmin', 'minioadmin')).content, e'\\n') x
         where l.parent_table = 'public.a8'::regclass and l.lo = '0' and x <> ''"
# negkp's [-10000, 0): "<rows_archived>|<the object at its key is the Parquet file of ids -1000..-1>"
NEGKP="select l.rows_archived || '|' || (text_to_bytea((archive.s3_signed_request('GET', 'http://minio:9000',
           'archive-test-bucket', 'us-east-1', l.s3_key, '', 'text/plain', '', 'minioadmin', 'minioadmin')).content)
           = archive._pq_to_parquet_range('public.negkp', 'id', '-10000', '0', false))
         from pgpm.archive_ledger l where l.parent_table = 'public.negkp'::regclass and l.lo = '-10000'"

# ---- tests/archive/db/08: every object it makes, Parquet and NDJSON -----------------------------------------
if sel 08; then
  if fresh "$ROOT/pgpm_archive/install.sql"; then
    judge "CONTROL: $T08 passes on the clean module" pass "$F08"
    expect "clean, a8p's 5000-row monolith is a whole file" "~^0:5000:([5-9]|[0-9]{2,}),6000:5:" "$(ledger_bytes public.a8p)"
    expect "clean, a8's monolith object names ids 1..5000" "5000/5000" "$A8_IDS"
  else
    say FAIL "fixture: CONTROL: the extensions, fixtures, core and module loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
  fi
  if is_planted par1_only; then
    if fresh "$work/par1_only.sql"; then
      judge "DEFECT: $T08 fails on a PAR1-only upload" fail "$F08"
      expect "PAR1, 5000 rows recorded, the object is 4 bytes" "~^0:5000:4," "$(ledger_bytes public.a8p)"
    else
      say FAIL "fixture: DEFECT: the extensions, fixtures, core and module loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  fi
  if is_planted ndjson_id_one; then
    if fresh "$work/ndjson_id_one.sql"; then
      judge "DEFECT: $T08 fails when every NDJSON line names id 1" fail "$F08"
      expect "ID ONE, a8's monolith object names one id in 5000 lines" "1/5000" "$A8_IDS"
    else
      say FAIL "fixture: DEFECT: the extensions, fixtures, core and module loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  fi
fi

# ---- tests/archive/db/16: Part B's two Parquet objects ------------------------------------------------------
if sel 16; then
  if fresh "$ROOT/pgpm_archive/install.sql"; then
    judge "CONTROL: $T16 passes on the clean module" pass "$F16"
    expect "clean, negkp's [-10000, 0) is 1000 rows, its object the chunk's file" "1000|true" "$NEGKP"
  else
    say FAIL "fixture: CONTROL: the extensions, fixtures, core and module loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
  fi
  if is_planted parquet_top_slice; then
    if fresh "$work/parquet_top_slice.sql"; then
      judge "DEFECT: $T16 fails when the Parquet object holds the top 5%" fail "$F16"
      expect "TOP SLICE, [-10000, 0) is 500 rows, another object" "500|false" "$NEGKP"
    else
      say FAIL "fixture: DEFECT: the extensions, fixtures, core and module loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  fi
fi

# ---- tests/archive/db/44: the two Parquet objects its ticks write under search_path app ---------------------
if sel 44; then
  if fresh "$ROOT/pgpm_archive/install.sql"; then
    judge "CONTROL: $T44 passes on the clean module" pass "$F44"
    expect "clean, p44's 1200 and 5 rows are whole files" "~^0:1200:([5-9]|[0-9]{2,}),2000:5:([5-9]|[0-9]{2,})$" "$(ledger_bytes public.p44)"
  else
    say FAIL "fixture: CONTROL: the extensions, fixtures, core and module loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
  fi
  if is_planted par1_only; then
    if fresh "$work/par1_only.sql"; then
      judge "DEFECT: $T44 fails on a PAR1-only upload" fail "$F44"
      expect "PAR1, p44's 1200 and 5 rows recorded, 4 bytes each" "0:1200:4,2000:5:4" "$(ledger_bytes public.p44)"
    else
      say FAIL "fixture: DEFECT: the extensions, fixtures, core and module loaded" "$(grep -m1 ERROR "$work/install.log")"; fail=1
    fi
  fi
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "drop role if exists t44_low" </dev/null >/dev/null 2>&1
fi

if [ "$fail" = 0 ]; then say PASS "every judged archive test file fails against its defect" "${SEL# }"
else say FAIL "every judged archive test file fails against its defect" "${SEL# }"; fi
exit "$fail"
