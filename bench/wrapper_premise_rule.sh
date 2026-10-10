#!/usr/bin/env bash
# Prove that every reader of a pgTAP file's failure as evidence applies ONE premise rule, bench/discriminate.sh's
# starved(): a run whose every failure is a premise (LIVENESS:, GUARD:, fixture:), or whose file reached no
# assertion at all, is not a catch.
#
# WHY THIS GUARD EXISTS (issues #1176 and #1177). discriminate.sh refuses a guard whose only failures against its
# mutant are premises (#713), and reads each failure by the head of its description (#1095). Two readers of the
# same output did not apply that rule:
#   #1176  the inverted wrappers, whose DEFECT verdict is "the judged file FAILS against a planted defect"
#          (hypertable_catchup_identity.sh, archive_fn_s3_readback.sh, tests_fail_on_defect.sh), counted any
#          `not ok` of the file, so a file whose only failure under the defect was a LIVENESS: witness was
#          certified as catching it. An inverted wrapper is the discriminate.sh of a test file, the file in the
#          role of the guard and the planted defect in the role of the mutant, so the rule is the same rule.
#   #1177  a pgTAP wrapper whose file raised before its first assertion printed `FAIL  <label>  0 ran` (its
#          restated verdict) and `FAIL  the assertions were reached at all`, both unprefixed, and starved()'s
#          fallback (no `not ok` line to read) counted both as defect checks, so a mutant whose fixture raises
#          certified its guard, the very case the reached count exists to keep from reading as a catch. The
#          timescale wrappers' shared verdict block did the same with its raw-error and shortfall lines.
#
# HOW. starved() is read out of bench/discriminate.sh (not restated here), and every check runs the wrappers'
# own code, as written, against output of a known shape, in <container> (pgtap and pg_prove; the plain core
# image has both):
#   RULE      the fixtures have their shapes: `dies_early` raises inside its transaction before its first
#             assertion, so none runs (pg_prove: 0 tests; psql -tAq: every later statement aborted), and
#             `failed` fails its one assertion, which is no premise.
#   PG_PROVE  bench/obtain_lock_budget.sh, the shape ~200 wrappers share, run on each fixture: on dies_early it
#             fails and starved() refuses its log; on failed it fails and starved() does NOT (the LIVENESS of the
#             check: a rule that refuses everything would pass it). And every bench/*.sh line that prints the
#             reached-at-all failure prints it as a LIVENESS: premise, so the ~200 copies the run cannot reach
#             read the same way.
#   TIMESCALE every bench/*.sh carrying the shared `# >>> pgTAP verdict` block (bench/wrapper_tap_verdicts.sh
#             holds each to exactly one), the block evaluated as written on each fixture: on dies_early its
#             output is refused by starved(), on failed it is not.
#   INVERTED  each inverted wrapper's `# >>> defect verdict` block (the one place its DEFECT verdict reads the
#             file's failures) evaluated on four TAP shapes: a failed defect check, and one beside a failed
#             premise, are caught; a run that failed only premises, and a run that failed nothing, are not.
#             End to end, tests_fail_on_defect.sh judges a copy of tests/90 whose one defect check (the
#             length refusal) is relabelled LIVENESS:, and must FAIL its DEFECT run rather than certify it.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   starved_counts_restated_verdict       -- discriminate.sh's fallback reads a wrapper's restated verdict
#                                            (`N ran`) as a check of its own again, pre-#1177
#   reached_line_unprefixed               -- obtain_lock_budget.sh's reached-at-all line without its prefix
#   timescale_verdict_unreached_as_check  -- hypertable_index_names.sh's block prints its raw-error and shortfall
#                                            lines unprefixed when no assertion ran
#   inverted_verdict_counts_premises      -- hypertable_catchup_identity.sh's DEFECT verdict counts any `not ok`,
#                                            pre-#1176 (F7-09)
#   archive_readback_verdict_counts_premises -- the same in archive_fn_s3_readback.sh's judge() (F7-08)
#   tests_fail_on_defect_counts_premises  -- the same in tests_fail_on_defect.sh's judge()
#
# Usage: wrapper_premise_rule.sh <container> <db> [script under test]
# With a third argument it judges THAT script in place of the one it stands for, recognised by its file name or,
# for a mutant bench/discriminate.sh built (<mutation>.sql), by the mutation's MUTATION_SRC; a /repo/... path is
# mapped to this checkout. Files reach the container over stdin, so no mount is needed. <db> names the scratch
# databases (<db>, <db>_olb, <db>_tfd).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ONLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok()  { printf 'PASS  %-66s %s\n' "$1" "$2"; }
bad() { printf 'FAIL  %-66s %s\n' "$1" "$2"; fail=1; }
qp() { docker exec -i "$C" psql -U postgres -X "$@"; }
CD="/tmp/wrapper_premise_rule_$DB"
work=$(mktemp -d)
cleanup() {
  for d in "$DB" "${DB}_olb" "${DB}_tfd"; do qp -d postgres -q -c "drop database if exists $d" </dev/null >/dev/null 2>&1; done
  docker exec "$C" rm -rf "$CD" </dev/null >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

INVERTED="bench/hypertable_catchup_identity.sh bench/archive_fn_s3_readback.sh bench/tests_fail_on_defect.sh"
TIMESCALE=""
for f in "$ROOT"/bench/*.sh; do
  grep -q '^ *# >>> pgTAP verdict' "$f" && TIMESCALE+="bench/$(basename "$f") "
done

# ---- the script under test ----------------------------------------------------------------------------------
ONLY_FOR=""
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then bad "GUARD: the script to judge exists" "$ONLY"; exit 1; fi
  base=$(basename "$ONLY")
  src=$(python3 - "$ROOT/bench/mutations" "${base%.*}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import mutate
print(mutate.MUTATION_SRC.get(sys.argv[2], ""))
PY
)
  for p in bench/discriminate.sh bench/obtain_lock_budget.sh $INVERTED $TIMESCALE; do
    if [ "$base" = "$(basename "$p")" ] || [ "$src" = "$p" ]; then ONLY_FOR="$p"; fi
  done
  if [ -z "$ONLY_FOR" ]; then bad "GUARD: the script to judge is one this guard knows" "$ONLY -> '${src}'"; exit 1; fi
fi
script_of() { if [ "$1" = "$ONLY_FOR" ]; then echo "$ONLY"; else echo "$ROOT/$1"; fi; }
# runnable <bench/x.sh>: a path to RUN the script from. A wrapper finds the checkout from its own path, so the
# script under test runs from a scratch root that holds it under its own name and links the rest of the tree.
runnable() {
  if [ "$1" != "$ONLY_FOR" ]; then echo "$ROOT/$1"; return; fi
  local r="$work/root" e
  if [ ! -d "$r" ]; then
    mkdir -p "$r/bench"
    for e in "$ROOT"/*; do [ "$(basename "$e")" = bench ] || ln -s "$e" "$r/$(basename "$e")"; done
    for e in "$ROOT"/bench/*; do ln -s "$e" "$r/bench/$(basename "$e")"; done
    rm -f "$r/$1"; cp "$ONLY" "$r/$1"
  fi
  echo "$r/$1"
}

# ---- the rule: discriminate.sh's own starved() ----------------------------------------------------------------
starved_fn=$(sed -n '/^starved() {/,/^}/p' "$(script_of bench/discriminate.sh)")
if [ -z "$starved_fn" ]; then bad "GUARD: starved() was read out of bench/discriminate.sh" "not found"; exit 1; fi
eval "$starved_fn"

# ---- the fixtures ----------------------------------------------------------------------------------------------
# dies_early: the shape of a mutant whose fixture step raises. Inside its transaction, so a runner without
# ON_ERROR_STOP (the timescale blocks' psql -tAq) runs nothing after the error either.
cat > "$work/dies_early.sql" <<'SQL'
create extension if not exists pgtap;
begin;
select plan(3);
select 1 / 0;
select ok(true, 'never reached');
select ok(true, 'never reached either');
select ok(true, 'nor this');
select * from finish();
rollback;
SQL
cat > "$work/failed.sql" <<'SQL'
create extension if not exists pgtap;
begin;
select plan(1);
select ok(false, 'the property under test holds');
select * from finish();
rollback;
SQL
docker exec "$C" mkdir -p "$CD" </dev/null
for f in dies_early failed; do docker exec -i "$C" sh -c "cat > $CD/$f.sql" <"$work/$f.sql"; done
docker exec -i "$C" sh -c "cat > $CD/install.sql" <"$ROOT/pgpm_core/install.sql"
qp -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
qp -d postgres -q -c "create database $DB" </dev/null >/dev/null 2>&1
qp -d "$DB" -q -c "create extension if not exists pgtap" </dev/null >/dev/null 2>&1

# ---- RULE: the fixtures have their shapes -----------------------------------------------------------------------
for f in dies_early failed; do
  qp -d "$DB" -tAq -f "$CD/$f.sql" </dev/null >"$work/$f.psql" 2>&1
  docker exec "$C" pg_prove -U postgres -d "$DB" "$CD/$f.sql" </dev/null >"$work/$f.prove" 2>&1
  echo $? >"$work/$f.prove.rc"
done
if grep -q 'division by zero' "$work/dies_early.psql" && ! grep -qE '^(not )?ok [0-9]+' "$work/dies_early.psql" \
   && grep -q 'current transaction is aborted' "$work/dies_early.psql" && [ "$(cat "$work/dies_early.prove.rc")" != 0 ]; then
  ok "LIVENESS: dies_early raises before any assertion, under psql and pg_prove" "0 ran, pg_prove exit $(cat "$work/dies_early.prove.rc")"
else
  bad "LIVENESS: dies_early raises before any assertion, under psql and pg_prove" "$(tr '\n' ' ' <"$work/dies_early.psql" | cut -c1-80)"
fi
if grep -qE '^not ok 1 - the property under test holds$' "$work/failed.psql" && [ "$(cat "$work/failed.prove.rc")" != 0 ]; then
  ok "LIVENESS: failed fails its one assertion, a defect check" "not ok 1"
else
  bad "LIVENESS: failed fails its one assertion, a defect check" "$(tr '\n' ' ' <"$work/failed.psql" | cut -c1-80)"
fi

# ---- PG_PROVE: obtain_lock_budget.sh, run as discriminate.sh runs a guard --------------------------------------
W=$(runnable bench/obtain_lock_budget.sh)
for f in dies_early failed; do
  LOCK_BUDGET_TEST_FILE="$CD/$f.sql" bash "$W" "$C" "${DB}_olb" "$CD/install.sql" >"$work/olb_$f.log" 2>&1 </dev/null
  echo $? >"$work/olb_$f.rc"
done
if [ "$(cat "$work/olb_dies_early.rc")" != 0 ] && grep -qE '^FAIL .*[[:space:]]0 ran$' "$work/olb_dies_early.log" \
   && ! grep -q 'module under test installed' "$work/olb_dies_early.log"; then
  ok "LIVENESS: obtain_lock_budget.sh installed, ran dies_early, reached nothing" "exit $(cat "$work/olb_dies_early.rc")"
else
  bad "LIVENESS: obtain_lock_budget.sh installed, ran dies_early, reached nothing" "exit $(cat "$work/olb_dies_early.rc")"
  sed 's/^/      /' "$work/olb_dies_early.log" | head -8
fi
if [ "$(cat "$work/olb_failed.rc")" != 0 ] && grep -q 'not ok 1 - the property under test holds' "$work/olb_failed.log" \
   && ! starved "$work/olb_failed.log"; then
  ok "LIVENESS: a failed defect check under obtain_lock_budget.sh still counts" "not refused"
else
  bad "LIVENESS: a failed defect check under obtain_lock_budget.sh still counts" "exit $(cat "$work/olb_failed.rc")"
  sed 's/^/      /' "$work/olb_failed.log" | head -8
fi
if starved "$work/olb_dies_early.log"; then
  ok "a pg_prove wrapper whose file reached no assertion is refused" "starved"
else
  bad "a pg_prove wrapper whose file reached no assertion is refused" "read as a catch"
  grep '^FAIL' "$work/olb_dies_early.log" | sed 's/^/      /'
fi

# Every line printing the reached-at-all failure, comments aside, prints it as a LIVENESS: premise.
reached=0; unprefixed=""
for f in "$ROOT"/bench/*.sh; do
  rel="bench/$(basename "$f")"
  [ "$rel" = bench/wrapper_premise_rule.sh ] && continue
  s=$(script_of "$rel")
  while IFS= read -r line; do
    reached=$((reached + 1))
    [[ "$line" =~ \"LIVENESS:\ [^\"]*were\ reached\ at\ all\" ]] || unprefixed+=" $rel"
  done < <(grep -E 'were reached at all"' "$s" | grep -vE '^[[:space:]]*#')
done
if [ "$reached" -ge 150 ]; then ok "LIVENESS: the reached-at-all lines were found" "$reached"
else bad "LIVENESS: the reached-at-all lines were found" "$reached, expected at least 150"; fi
if [ -z "$unprefixed" ]; then ok "every reached-at-all failure prints with its premise prefix" "$reached of $reached"
else
  bad "every reached-at-all failure prints with its premise prefix" "$(wc -w <<<"$unprefixed" | tr -d ' ') not, in:"
  tr ' ' '\n' <<<"$unprefixed" | grep . | sort -u | head -10 | sed 's/^/      /'
fi

# ---- TIMESCALE: each shared verdict block, as written ----------------------------------------------------------
# q is the wrapper's own psql helper, pointed at this container; the block's call runs the fixture.
q() { docker exec "$C" psql -U postgres -X "$@" </dev/null; }
nts=0; tsbad=""; tslive=""
for rel in $TIMESCALE; do
  s=$(script_of "$rel")
  block=$(awk '/^ *# >>> pgTAP verdict/ {f=1} f {print} /^ *# <<< pgTAP verdict/ {exit}' "$s")
  for f in dies_early failed; do
    # shellcheck disable=SC2034  # TEST_FILE, LABEL and UNINSTALL are read by the evaluated block
    (TEST_FILE="$CD/$f.sql"; LABEL="the wrapped file passes"; UNINSTALL=/dev/null; fail=0
     eval "$block"; exit "$fail") >"$work/ts.$f.log" 2>&1
    echo $? >"$work/ts.$f.rc"
  done
  nts=$((nts + 1))
  if [ "$(cat "$work/ts.failed.rc")" = 0 ] || starved "$work/ts.failed.log" || [ "$(cat "$work/ts.dies_early.rc")" = 0 ]; then
    tslive+=" $rel"
  fi
  starved "$work/ts.dies_early.log" || tsbad+=" $rel"
done
if [ "$nts" -ge 30 ] && [ -z "$tslive" ]; then
  ok "LIVENESS: each timescale block fails both fixtures, failed as a catch" "$nts blocks"
else
  bad "LIVENESS: each timescale block fails both fixtures, failed as a catch" "$nts blocks; not:$tslive"
fi
if [ -z "$tsbad" ]; then ok "a timescale block whose file reached no assertion is refused" "$nts of $nts"
else bad "a timescale block whose file reached no assertion is refused" "read as a catch:$tsbad"; fi

# ---- INVERTED: each DEFECT verdict, as written, and one end to end -------------------------------------------
printf '%s\n' 'ok 1 - LIVENESS: the fixture reached the state the defect needs' 'not ok 2 - the property under test holds' >"$work/tap.defect"
printf '%s\n' 'not ok 1 - LIVENESS: the fixture reached the state the defect needs' 'not ok 2 - the property under test holds' >"$work/tap.mixed"
printf '%s\n' 'not ok 1 - LIVENESS: the fixture reached the state the defect needs' 'not ok 2 - fixture: the second table was built' >"$work/tap.premise"
printf '%s\n' 'ok 1 - LIVENESS: the fixture reached the state the defect needs' 'ok 2 - the property under test holds' >"$work/tap.clean"
for rel in $INVERTED; do
  s=$(script_of "$rel"); n=$(basename "$rel" .sh)
  nb=$(grep -c '^ *# >>> defect verdict' "$s"); ne=$(grep -c '^ *# <<< defect verdict' "$s")
  if [ "$nb" != 1 ] || [ "$ne" != 1 ]; then bad "GUARD: $n carries exactly one defect-verdict block" "$nb begin, $ne end"; continue; fi
  block=$(awk '/^ *# >>> defect verdict/ {f=1} f {print} /^ *# <<< defect verdict/ {exit}' "$s")
  got=""
  for t in defect mixed premise clean; do
    if (eval "$block"; caught "$work/tap.$t") >/dev/null 2>&1; then got+="$t=caught "; else got+="$t=no "; fi
  done
  if [[ "$got" == "defect=caught mixed=caught "* ]]; then ok "LIVENESS: $n's DEFECT verdict catches a failed defect check" "${got% }"
  else bad "LIVENESS: $n's DEFECT verdict catches a failed defect check" "${got% }"; fi
  if [[ "$got" == *"premise=no clean=no " ]]; then ok "$n's DEFECT verdict refuses a run that failed only premises" "${got% }"
  else bad "$n's DEFECT verdict refuses a run that failed only premises" "${got% }"; fi
done

# tests_fail_on_defect.sh on a copy of tests/90 whose length refusal (its one defect check) is labelled a premise.
mkdir -p "$work/t90"
T90="$work/t90/90_text_time_alphabet_codec_test.sql"
sed "s/^  'radix_decode refuses when the alphabet length does not match the declared radix'$/  'LIVENESS: radix_decode refuses when the alphabet length does not match the declared radix'/" \
  "$ROOT/tests/90_text_time_alphabet_codec_test.sql" >"$T90"
if [ "$(diff "$ROOT/tests/90_text_time_alphabet_codec_test.sql" "$T90" | grep -c '^>')" = 1 ] && grep -q "^  'LIVENESS: radix_decode refuses" "$T90"; then
  ok "fixture: the copy of tests/90 differs only in its refusal's prefix" "1 line"
else
  bad "fixture: the copy of tests/90 differs only in its refusal's prefix" "tests/90 moved; fix the relabel"
fi
bash "$(runnable bench/tests_fail_on_defect.sh)" "$C" "${DB}_tfd" "$T90" >"$work/tfd.log" 2>&1 </dev/null; trc=$?
if grep -q '^PASS  CONTROL: tests/90' "$work/tfd.log" && grep -q "^PASS  LIVENESS: with no length check '3' decodes under it" "$work/tfd.log"; then
  ok "LIVENESS: tests_fail_on_defect.sh passed the copy clean and planted the defect" "control and defect"
else
  bad "LIVENESS: tests_fail_on_defect.sh passed the copy clean and planted the defect" "exit $trc"
  sed 's/^/      /' "$work/tfd.log" | head -12
fi
if [ "$trc" != 0 ] && grep -q '^FAIL  DEFECT: tests/90' "$work/tfd.log"; then
  ok "tests_fail_on_defect.sh refuses a file that failed only premises" "exit $trc"
else
  bad "tests_fail_on_defect.sh refuses a file that failed only premises" "exit $trc, no FAIL on its DEFECT run: it certified the copy"
  grep -E '^(PASS|FAIL)  DEFECT' "$work/tfd.log" | sed 's/^/      /'
fi

exit "$fail"
