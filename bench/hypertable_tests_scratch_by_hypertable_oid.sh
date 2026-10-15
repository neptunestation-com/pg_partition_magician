#!/usr/bin/env bash
# Prove that each timescale test file's "no scratch record is left" check reads not ok against a cutover that
# leaves the hypertable's pgpm.scratch records behind, by putting that cutover in and running the file.
#
# WHY THIS GUARD EXISTS (issue #1283, F10-02 and F10-03). pgpm.scratch keys every record of a from_hypertable
# copy (the copy, the delta, the capture function) by the HYPERTABLE's oid, and from_hypertable_cutover deletes
# them by that oid in the swap, which then drops the hypertable and renames the copy into its place. Five files
# asked for leftover records by casting the table's name to regclass AFTER the cutover, when the name already
# resolves to the migrated table, whose oid no record carries: tests/timescale/db/65 ('and no scratch record is
# left'), 66 and 58 (each a LIVENESS witness that its migrations finished clean), 60 and 69. Against a cutover
# whose `delete from pgpm.scratch where parent_oid = p_hypertable::oid` is gone every one of them stayed ok,
# with 6, 3, 2, 7 and 6 records of the dropped hypertables left behind. Each now takes its hypertables' oids
# before anything is migrated and asks for the records by them, naming what is left as <table>:<kind>.
#
# WHAT IS READ, AND WHY NOT THE PREMISE RULE. The subject is one named check per file, not whether the file as a
# whole catches the defect (tests/timescale/db/49 does that for the swap's delete, bench/scratch_relations.sh
# against hypertable_swap_keeps_scratch_record). Two of the five checks are LIVENESS witnesses of their files,
# which bench/discriminate.sh's starved() rightly refuses as a catch, so the verdict here is the named line's own:
# it must read `not ok` against the planted cutover and `ok` against the clean one. A witness that cannot fail
# witnesses nothing, so it is held to failing exactly as a defect check is.
#
# HOW. Per file, in fresh databases named <db> in <container> (the timescale track's fleet image: TimescaleDB,
# pgtap, the core, the module and tests/timescale/fixtures.sql, over TCP as every timescale wrapper connects):
#   CONTROL   against the clean module, the file runs to its end with every planned assertion ok;
#   DEFECT    against the module with the swap's scratch delete removed, the file runs to its end and its
#             scratch check, found by its exact description, reads `not ok`;
#   LIVENESS  the defect was really planted and the clean module really forgets: after the DEFECT run the
#             database holds pgpm.scratch records whose parent no longer exists (the dropped hypertables'),
#             after the CONTROL run it holds none; and the check ran in both (found by its description).
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each the check asking for the
# records by the oid the table's name resolves to after the cutover (the pre-fix key) under its current
# description:
#   ts65_scratch_left_by_new_table_oid -- tests/timescale/db/65
#   ts66_scratch_left_by_new_table_oid -- tests/timescale/db/66
#   ts58_scratch_left_by_new_table_oid -- tests/timescale/db/58
#   ts60_scratch_left_by_new_table_oid -- tests/timescale/db/60
#   ts69_scratch_left_by_new_table_oid -- tests/timescale/db/69
#
# Usage: hypertable_tests_scratch_by_hypertable_oid.sh <container> <db> [test file]
# With no third argument it judges all five files of this checkout. With one it judges THAT file in place of the
# one it stands for, recognised by its file name or, for a mutant bench/discriminate.sh built (<mutation>.sql),
# by the mutation's MUTATION_SRC; a /repo/... path is mapped to this checkout. Every install and file reaches the
# container over stdin. Runs on the TIMESCALE track, which is why the mutations sit in MUTATION_TRACK=timescale;
# run_timescale also runs it once against the clean files.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ONLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
say() { printf '%s  %-66s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres -X "$@"; }
v() { q -d "$DB" -tAq -c "$1" </dev/null 2>&1; }
work=$(mktemp -d)
cleanup() { q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

# <key>|<path from the repository root>|<the scratch check's exact description>
FILES="ts65|tests/timescale/db/65_from_hypertable_cutover_moved_delta_by_record_test.sql|and no scratch record is left under either hypertable's oid, taken before the swap
ts66|tests/timescale/db/66_from_hypertable_column_unit_rules_test.sql|LIVENESS: and no scratch record is left for any of the three, under the hypertables' oids taken at the start
ts58|tests/timescale/db/58_from_hypertable_argument_rules_test.sql|LIVENESS: and no scratch record is left for either, under the hypertables' oids taken at the start
ts60|tests/timescale/db/60_from_hypertable_copy_rerun_by_record_test.sql|and the cutovers left no scratch record behind under the hypertables' oids taken at the start
ts69|tests/timescale/db/69_from_hypertable_mixed_step_and_unit_remedy_test.sql|and no scratch record is left for any, under the hypertables' oids taken at the start"

SEL=" ts65 ts66 ts58 ts60 ts69 "
OVERRIDE=""
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
  SEL=""
  while IFS='|' read -r key path _; do
    if [ "$base" = "$(basename "$path")" ] || [ "$src" = "$path" ]; then SEL=" $key "; OVERRIDE="$ONLY"; fi
  done <<<"$FILES"
  if [ -z "$SEL" ]; then
    say FAIL "GUARD: the file to judge is one of the files this guard knows" "$ONLY -> '${src}'"; exit 1
  fi
fi

# The defect: this checkout's module with the swap's scratch delete removed, the rest as it is. A pattern that no
# longer matches exactly once is a FAILURE, never a silently unmutated copy (the discipline of mutate.py).
SWAP_DELETE="  delete from pgpm.scratch where parent_oid = p_hypertable::oid;
"
if ! python3 - "$ROOT/pgpm_hypertable/install.sql" "$work/swap_keeps_records.sql" "$SWAP_DELETE" <<'PY'
import sys
src, dst, find = sys.argv[1:4]
t = open(src).read()
n = t.count(find)
if n != 1:
    sys.exit(f"pattern matched {n} time(s), expected 1: {find.strip()!r}")
open(dst, "w").write(t.replace(find, ""))
PY
then
  say FAIL "fixture: planted the defect: the swap keeps the hypertable's records" "pgpm_hypertable/install.sql moved; fix the pattern"
  exit 1
fi

# load <module install.sql>: a fresh <db> holding TimescaleDB, pgtap, the core, that module and the fixtures.
load() {
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "create database $DB" </dev/null >"$work/install.log" 2>&1 &&
    q -d postgres -q -c "alter database $DB set client_min_messages = warning" </dev/null >>"$work/install.log" 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" </dev/null >>"$work/install.log" 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f - <"$ROOT/pgpm_core/install.sql" >>"$work/install.log" 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$1" >>"$work/install.log" 2>&1 &&
    q -d "$DB" -v ON_ERROR_STOP=1 -q -f - <"$ROOT/tests/timescale/fixtures.sql" >>"$work/install.log" 2>&1
}

# The records whose parent no longer exists, by kind: what a swap that kept them leaves of a dropped hypertable.
ORPHANS="select coalesce(string_agg(s.kind, ',' order by s.kind), 'none') from pgpm.scratch s
          where not exists (select 1 from pg_class c where c.oid = s.parent_oid)"

# run <label> <test file> <out>: the file's TAP in <out>; FAIL (as a premise) when it did not run to its end.
run() {
  local out rc planned oks notoks
  out=$(q -d "$DB" -v ON_ERROR_STOP=1 -tA -f - <"$2" 2>&1); rc=$?
  printf '%s\n' "$out" >"$3"
  planned=$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' <<<"$out" | head -1)
  oks=$(grep -cE '^ok [0-9]+' <<<"$out")
  notoks=$(grep -cE '^not ok [0-9]+' <<<"$out")
  if [ "$rc" != 0 ] || [ -z "$planned" ] || [ $((oks + notoks)) != "$planned" ]; then
    say FAIL "fixture: $1: the file ran to its end" "psql exit $rc, plan ${planned:-none}, $oks ok, $notoks not ok"
    grep -E 'ERROR' <<<"$out" | head -3 | sed 's/^/      /'
    fail=1; return 1
  fi
}

# line <TAP file> <description>: the verdict of the assertion so described ('ok', 'not ok' or 'missing').
line() {
  local hit
  hit=$(grep -E '^(not )?ok [0-9]+ - ' "$1" | sed -E 's/^((not )?ok) [0-9]+ - /\1|/' | awk -F'|' -v d="$2" '$2 == d { print $1; exit }')
  printf '%s' "${hit:-missing}"
}

while IFS='|' read -r key path desc; do
  case "$SEL" in *" $key "*) ;; *) continue ;; esac
  file="$ROOT/$path"; [ -n "$OVERRIDE" ] && file="$OVERRIDE"
  name="tests/timescale/db/${key#ts}"

  # CONTROL: the clean module, every assertion ok, and the clean swap forgot every record of the dropped tables.
  if load "$ROOT/pgpm_hypertable/install.sql"; then
    if run "CONTROL: $name" "$file" "$work/control.tap"; then
      bad=$(grep -cE '^not ok [0-9]+' "$work/control.tap")
      if [ "$bad" = 0 ]; then say PASS "CONTROL: $name passes against the clean module" "every assertion ok"
      else
        say FAIL "CONTROL: $name passes against the clean module" "$bad not ok"
        grep -E '^not ok' "$work/control.tap" | head -5 | sed 's/^/      /'; fail=1
      fi
      got=$(line "$work/control.tap" "$desc")
      if [ "$got" = missing ]; then say FAIL "GUARD: $name's scratch check ran against the clean module" "no line described: $desc"; fail=1
      else say PASS "LIVENESS: $name's scratch check ran against the clean module" "$got"; fi
      got=$(v "$ORPHANS")
      if [ "$got" = none ]; then say PASS "LIVENESS: the clean swap left no record of a dropped table" "$got"
      else say FAIL "LIVENESS: the clean swap left no record of a dropped table" "got: $got"; fail=1; fi
    fi
  else
    say FAIL "fixture: CONTROL: TimescaleDB, the core, the module and the fixtures loaded" "$(grep -m1 -E 'ERROR|FATAL' "$work/install.log")"; fail=1
  fi

  # DEFECT: the swap keeps the records; the named check must read not ok.
  if load "$work/swap_keeps_records.sql"; then
    if run "DEFECT: $name" "$file" "$work/defect.tap"; then
      got=$(v "$ORPHANS")
      if [ -n "$got" ] && [ "$got" != none ] && [[ "$got" != *ERROR* ]]; then
        say PASS "LIVENESS: the planted swap left the dropped tables' records" "$got"
      else
        say FAIL "LIVENESS: the planted swap left the dropped tables' records" "got: ${got:-nothing}"; fail=1
      fi
      got=$(line "$work/defect.tap" "$desc")
      case "$got" in
        "not ok") say PASS "DEFECT: $name's scratch check sees the records the swap kept" "not ok" ;;
        ok)       say FAIL "DEFECT: $name's scratch check sees the records the swap kept" "ok: it asks for records no table it names carries"; fail=1 ;;
        *)        say FAIL "GUARD: $name's scratch check ran against the planted swap" "no line described: $desc"; fail=1 ;;
      esac
    fi
  else
    say FAIL "fixture: DEFECT: TimescaleDB, the core, the planted module and the fixtures loaded" "$(grep -m1 -E 'ERROR|FATAL' "$work/install.log")"; fail=1
  fi
done <<<"$FILES"

if [ "$fail" = 0 ]; then say PASS "each file's scratch check asks for the hypertables' records" "${SEL# }"
else say FAIL "each file's scratch check asks for the hypertables' records" "${SEL# }"; fi
exit "$fail"
