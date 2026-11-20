#!/usr/bin/env bash
# Measurement 2 of docs/formal/phase3-design.md ("Measured before it is relied on"): what pgpm_formal.check() costs
# at the end of real test files, next to the file's own run time.
#
#   tests/formal/measure_cost.sh <container> [tests/NN_name_test.sql ...]
#   default files: every tests/*_test.sql that sets a retention horizon (p_retain or set_retain), less the two
#   pg_cron files (31, 78) and the four test.sh runs alone (333, 345, 349, 350)
#
# Each file runs in its own clone of a template holding pgtap, pgpm's core, the demo fixtures and the oracle (the
# template test.sh builds, plus tests/formal/oracle.sql), as prove_one runs it. After pg_prove, in the same clone:
#   1. check() as the files are today, with no baseline: the structural invariants only
#   2. baseline() of every parent pgpm manages at the end, then check() again: the visibility scan over the whole
#      end state, the most a migrated file's check() reads (its baseline is never larger than what it wrote)
# Each check() is timed server side (clock_timestamp around the call, in one function). One TSV row per file goes
# to stdout:
#   file  result  file_ms  check_ms  violations  baseline_rows  check_base_ms  violations_base  invariants  plain_ms
# and a summary (median and max check() time, and as a share of the file's) to stderr. Every file is also run in a
# template WITHOUT the oracle (plain_ms), which prices the event triggers' share of the file's own run, and a file
# that fails says whether it fails there too.
set -euo pipefail

c="${1:?usage: measure_cost.sh <container> [tests/file_test.sql ...]}"
shift
cd "$(dirname "$0")/../.."
# shellcheck source=tests/formal/lib.sh
source tests/formal/lib.sh

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  while IFS= read -r f; do files+=("$f"); done < <(
    grep -lE "p_retain|set_retain" tests/*_test.sql \
      | grep -vE '/(31|78|333|345|349|350)_' | sort -V)
fi

build_template pgpm_fx_tmpl 1
build_template pgpm_fx_plain 0

ms() { date +%s%N | cut -c1-13; }

timed_check_sql="
create or replace function pg_temp.timed_check(out ms numeric, out n bigint, out invs text) language plpgsql as \$\$
declare t0 timestamptz := clock_timestamp();
begin
  select count(*), string_agg(distinct invariant, ',') into n, invs from pgpm_formal.check();
  ms := round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
end \$\$;"

prove() {  # <template> <db> <file> -> prints PASS or FAIL
  local t="$1" db="$2" f="$3"
  q -c "drop database if exists $db" >/dev/null
  q -c "create database $db template $t" >/dev/null
  if docker exec "$c" pg_prove -U postgres -d "$db" "/repo/$f" >/dev/null 2>&1; then echo PASS; else echo FAIL; fi
}

out=$(mktemp)
trap 'rm -f "$out"' EXIT
printf 'file\tresult\tfile_ms\tcheck_ms\tviolations\tbaseline_rows\tcheck_base_ms\tviolations_base\tinvariants\tplain_ms\n'
for f in "${files[@]}"; do
  db=pgpm_fx_cost
  t0=$(ms)
  res=$(prove pgpm_fx_tmpl "$db" "$f")
  file_ms=$(( $(ms) - t0 ))
  t0=$(ms)
  plain=$(prove pgpm_fx_plain pgpm_fx_cost_plain "$f")
  plain_ms=$(( $(ms) - t0 ))
  q -c "drop database if exists pgpm_fx_cost_plain" >/dev/null
  if [ "$res" = FAIL ]; then res="FAIL(without oracle: $plain)"; fi
  one=$(DB="$db" q -F $'\t' -c "$timed_check_sql" -c "select ms, n, coalesce(invs, '') from pg_temp.timed_check()" | tail -1) \
    || one=$'error\terror\terror'
  # a file may leave pgpm uninstalled (tests/239): then there is nothing to baseline
  rows=$(DB="$db" q -c "select coalesce(sum(pgpm_formal.baseline(parent_table)), 0) from pgpm.config c
                          where exists (select 1 from pg_class k where k.oid = c.parent_table)" 2>/dev/null | tail -1) || rows=0
  two=$(DB="$db" q -F $'\t' -c "$timed_check_sql" -c "select ms, n, coalesce(invs, '') from pg_temp.timed_check()" | tail -1) \
    || two=$'error\terror\terror'
  IFS=$'\t' read -r c1 n1 i1 <<<"$one"
  IFS=$'\t' read -r c2 n2 i2 <<<"$two"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(basename "$f")" "$res" "$file_ms" "$c1" "$n1" "$rows" "$c2" "$n2" "${i1}|${i2}" "$plain_ms" \
    | tee -a "$out"
  q -c "drop database if exists $db" >/dev/null
done

med() { sort -g | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }
mx()  { sort -g | tail -1; }
n=$(wc -l <"$out")
ftot=$(awk -F'\t' '{ s += $3 } END { print s }' "$out")
{
  echo "files: $n; their run time: $ftot ms in all, median $(cut -f3 "$out" | med) ms"
  echo "check(), no baseline: median $(cut -f4 "$out" | med) ms, max $(cut -f4 "$out" | mx) ms," \
       "$(awk -F'\t' -v t="$ftot" '{ s += $4 } END { printf "%.2f", 100 * s / t }' "$out")% of the files' time"
  echo "check(), whole end state baselined: median $(cut -f7 "$out" | med) ms, max $(cut -f7 "$out" | mx) ms," \
       "$(awk -F'\t' -v t="$ftot" '{ s += $7 } END { printf "%.2f", 100 * s / t }' "$out")% of the files' time;" \
       "per file median $(awk -F'\t' '{ printf "%.2f\n", 100 * $7 / $3 }' "$out" | med)%," \
       "max $(awk -F'\t' '{ printf "%.2f\n", 100 * $7 / $3 }' "$out" | mx)%"
  echo "the event triggers: the files ran in $ftot ms with the oracle installed and" \
       "$(awk -F'\t' '{ s += $10 } END { print s }' "$out") ms without it;" \
       "per file (with - without) / without: median $(awk -F'\t' '{ printf "%.2f\n", 100 * ($3 - $10) / $10 }' "$out" | med)%"
  echo "baseline rows: median $(cut -f6 "$out" | med), max $(cut -f6 "$out" | mx)"
  echo "files with a violation: $(awk -F'\t' '$5 > 0 || $8 > 0' "$out" | wc -l); files that failed: $(grep -c FAIL "$out" || true)"
} >&2
q -c "drop database if exists pgpm_fx_tmpl" >/dev/null
q -c "drop database if exists pgpm_fx_plain" >/dev/null
