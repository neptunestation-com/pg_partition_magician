#!/usr/bin/env bash
# Guard the LZ77 match-finder's memory cost against re-growing with input size (issue #366).
#
# THE BAR: archive._pq_lz77_tokens's candidate lookup must cost O(1) memory regardless of payload
# size (a fixed-size hash table), not O(input size) (the old per-position temp table + btree
# index, which measured ~40x the input size in peak RSS on a production-shaped fixture, and
# degraded further across repeated calls in one backend session -- exactly what
# config.archive_batch > 1 does). This drives three sequential archive._pq_to_parquet_range calls
# in ONE backend session (chunk1, chunk2, a repeat of chunk1 -- issue #366's own methodology) and
# asserts peak RSS stays bounded, and that the repeat costs no more than the original.
#
# The unit of observation is SERVER-SIDE (docker exec cat /proc/<backend pid>/status), not a psql
# round-trip per sample. That distinction matters when the window being measured is narrow (see
# bench/maintain_lock.sh's note on ~100ms docker exec cost vs a ~400ms scan) -- it does not bind
# here, because at this fixture size a chunk's encode+compress step runs for single-digit seconds,
# comfortably wider than the ~100-200ms a docker exec sample costs.
#
# Usage: archive_lz77_memory.sh <container> <db> [archive install.sql]
# The archive install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy
# instead (with the old temp-table pattern put back), to prove this guard actually fails when the
# defect is present. pgpm_core/install.sql is always the real one: #366 is scoped to the archive
# module's LZ77 matcher, not core.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
ROWS=${ROWS:-6000}            # rows per chunk; calibrated so the old O(input) table+index clears
                                # MAX_PEAK_KB and the new fixed-cost hash table stays comfortably under it
PAYLOAD_BYTES=${PAYLOAD_BYTES:-5120}   # matches the issue's own production-shaped fixture
MAX_PEAK_KB=${MAX_PEAK_KB:-480000}     # ~480 MiB: comfortably above the fix's flat cost, well
                                        # below where the old O(input) table/index lands at this size
fail=0

check() { # <label> <actual> <predicate-description-already-evaluated: 0|1>
  if [ "$3" = "1" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s %s\n' "$1" "$2"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -c "create extension if not exists http; create extension if not exists pgcrypto;" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ARCHIVE_INSTALL" >/dev/null

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
q "create table public.lz77_bench (id bigint primary key, payload text)" >/dev/null
q "insert into public.lz77_bench
     select g, rpad('row ' || g || ': ', $PAYLOAD_BYTES, 'The quick brown fox jumps over the lazy dog. ')
     from generate_series(1, $((ROWS * 2))) g" >/dev/null
q "vacuum analyze public.lz77_bench" >/dev/null

LO1=1; HI1=$((ROWS + 1)); LO2=$HI1; HI2=$((2 * ROWS + 1))
# The probe session runs WITHOUT ON_ERROR_STOP on purpose, so its log records every chunk's outcome;
# the verdict therefore never reads a marker as "the chunk worked" (a marker prints after a raised
# call exactly as after a returned one, #912). Each call's OWN result row, tagged `chunkN_file=`,
# carries the file's length, its leading and trailing magic and the md5 of its bytes (#992), and any
# ERROR in the log fails the guard. The start/done markers only bracket each call for the sampler below. The `offset 0` keeps the
# subquery from being flattened, so the encode runs once per chunk however often its result is read.
chunk() { # <n> <lo> <hi>: the probe statement for chunk n
  printf "select 'chunk%s_file=' || length(f) || ':' || encode(substring(f from 1 for 4), 'escape') || encode(substring(f from length(f) - 3), 'escape') || ':' || md5(f) from (select archive._pq_to_parquet_range('public.lz77_bench'::regclass,'id','%s','%s',true) as f offset 0) s" "$1" "$2" "$3"
}
LOG=$(mktemp)
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "set client_min_messages = warning" \
  -c "select pg_backend_pid()" \
  -c "select pg_sleep(0.3)" \
  -c "select 'marker_chunk1_start'" \
  -c "$(chunk 1 "$LO1" "$HI1")" \
  -c "select 'marker_chunk1_done'" \
  -c "select 'marker_chunk2_start'" \
  -c "$(chunk 2 "$LO2" "$HI2")" \
  -c "select 'marker_chunk2_done'" \
  -c "select 'marker_chunk3_start'" \
  -c "$(chunk 3 "$LO1" "$HI1")" \
  -c "select 'marker_chunk3_done'" \
  > "$LOG" 2>&1 &
BG=$!

PID=""
for _ in $(seq 1 200); do
  PID=$(grep -Eo '^[0-9]+$' "$LOG" 2>/dev/null | head -n1)
  [ -n "$PID" ] && break
  sleep 0.1
done

# peak[0]/[1]/[2] = chunk1/chunk2/chunk3's own window. A sample belongs to chunk k only when it is
# bracketed by that chunk's markers: k start markers in the log BEFORE the sample is taken and k-1
# done markers AFTER it, so it provably fell inside chunk k's call. Anything else (the pg_sleep before
# chunk1, the gap between two chunks, a sample that straddled a boundary) is not counted at all.
peak0=0; peak1=0; peak2=0
n0=0; n1=0; n2=0
if [ -n "$PID" ]; then
  while kill -0 "$BG" 2>/dev/null; do
    # grep -c exits 1 (not 0) when the count is zero, even though it still prints "0" -- so this
    # must not use `|| echo 0`, which would append a SECOND "0" on that exit status and corrupt the
    # arithmetic below, silently dropping every chunk1 sample.
    started=$(grep -c '^marker_chunk[123]_start$' "$LOG" 2>/dev/null)
    rss=$(docker exec "$C" sh -c "grep VmRSS /proc/$PID/status 2>/dev/null | awk '{print \$2}'" 2>/dev/null)
    ended=$(grep -c '^marker_chunk[123]_done$' "$LOG" 2>/dev/null)
    started=${started:-0}; ended=${ended:-0}
    if [ -n "${rss:-}" ] && [ "$started" -ge 1 ] && [ "$ended" = "$((started - 1))" ]; then
      case "$started" in
        1) n0=$((n0+1)); [ "$rss" -gt "$peak0" ] && peak0=$rss ;;
        2) n1=$((n1+1)); [ "$rss" -gt "$peak1" ] && peak1=$rss ;;
        3) n2=$((n2+1)); [ "$rss" -gt "$peak2" ] && peak2=$rss ;;
      esac
    fi
    sleep 0.15
  done
fi
wait "$BG"

echo "--- backend $PID: peak RSS per chunk (KB) ---"
printf 'chunk1=%s (n=%s)  chunk2=%s (n=%s)  chunk3(repeat of chunk1)=%s (n=%s)\n' \
  "$peak0" "$n0" "$peak1" "$n1" "$peak2" "$n2"
cat "$LOG"

# chunkN_file=<length>:PAR1PAR1:<md5> is a Parquet file the call returned; read each chunk's own row.
file_row() { grep -E "^chunk$1_file=[0-9]+:PAR1PAR1:[0-9a-f]{32}$" "$LOG" | head -n1; }
file_len() { file_row "$1" | sed -E 's/^[^=]*=([0-9]+):.*$/\1/'; }
file_md5() { file_row "$1" | sed -E 's/^.*:([0-9a-f]{32})$/\1/'; }
len1=$(file_len 1); len2=$(file_len 2); len3=$(file_len 3)
md5_1=$(file_md5 1); md5_3=$(file_md5 3)
n_err=$(grep -c 'ERROR:' "$LOG")

# Liveness witnesses first: a probe that sampled nothing would otherwise let every bound below pass
# vacuously. They print as LIVENESS: lines, the prefix bench/discriminate.sh reads to refuse a mutant run
# that failed only these as a starved fixture (#713, #1095).
check "LIVENESS: the probe found the backend pid" "$PID"   "$([ -n "$PID" ] && echo 1 || echo 0)"
check "LIVENESS: chunk1 was sampled while it ran" "n=$n0"  "$([ "$n0" -gt 0 ] && echo 1 || echo 0)"
check "LIVENESS: chunk2 was sampled while it ran" "n=$n1"  "$([ "$n1" -gt 0 ] && echo 1 || echo 0)"
check "LIVENESS: chunk3 was sampled while it ran" "n=$n2"  "$([ "$n2" -gt 0 ] && echo 1 || echo 0)"
# The calls' own results. A call that failed would let the bounds pass vacuously too, but these are NOT
# premise witnesses: a call that raised after building the whole file (archive_lz77_range_raises, #912)
# and a repeat that returned a different file (archive_lz77_repeat_differs, #992) are defects they exist
# to catch, and each fails only these, so they stay defect checks (no LIVENESS: prefix).
check "chunk1 returned a Parquet file"   "len=${len1:-none}" "$([ "${len1:-0}" -gt 8 ] && echo 1 || echo 0)"
check "chunk2 returned a Parquet file"   "len=${len2:-none}" "$([ "${len2:-0}" -gt 8 ] && echo 1 || echo 0)"
check "chunk3 returned a Parquet file"   "len=${len3:-none}" "$([ "${len3:-0}" -gt 8 ] && echo 1 || echo 0)"
# chunk3 re-encodes chunk1's rows, so it is the same file: a repeat that came back different is not
# a repeat of the work the ratio below compares. Judged by CONTENT, the md5 of each file's bytes: a
# different file of the same length is not chunk1's file (#992).
check "chunk3 (repeat) returned chunk1's file again" \
      "chunk1=${len1:-none}:${md5_1:-none} chunk3=${len3:-none}:${md5_3:-none}" \
      "$([ -n "${md5_1:-}" ] && [ "${md5_1:-}" = "${md5_3:-}" ] && [ "${len1:-}" = "${len3:-}" ] && echo 1 || echo 0)"
check "the probe session raised no ERROR" "$n_err" "$([ "$n_err" = 0 ] && echo 1 || echo 0)"

# The bar itself: flat, bounded memory, not O(input size).
check "chunk1 peak RSS stays bounded (<= ${MAX_PEAK_KB}KB)" "${peak0}KB" "$([ "$peak0" -le "$MAX_PEAK_KB" ] && echo 1 || echo 0)"
check "chunk2 peak RSS stays bounded (<= ${MAX_PEAK_KB}KB)" "${peak1}KB" "$([ "$peak1" -le "$MAX_PEAK_KB" ] && echo 1 || echo 0)"
check "chunk3 peak RSS stays bounded (<= ${MAX_PEAK_KB}KB)" "${peak2}KB" "$([ "$peak2" -le "$MAX_PEAK_KB" ] && echo 1 || echo 0)"

# No cross-chunk compounding: repeating IDENTICAL data in the same session must not cost
# noticeably more than the original -- the old implementation measured ~5x here.
ratio_ok=0
if [ "$peak0" -gt 0 ] && [ "$peak2" -le "$((peak0 * 3 / 2))" ]; then ratio_ok=1; fi
check "chunk3 (repeat) does not compound over chunk1 (<=1.5x)" "chunk1=${peak0}KB chunk3=${peak2}KB" "$ratio_ok"

exit "$fail"
